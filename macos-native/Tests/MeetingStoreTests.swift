import XCTest

final class MeetingStoreTests: XCTestCase {
    private var dir: URL!
    // Kept OUTSIDE `dir`: tests assert on the store dir's .m4a contents, so
    // pre-move source files must live somewhere else. Cleaned up in
    // tearDownWithError so a mid-test failure never leaks files into the
    // shared OS temp root.
    private var scratch: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes a fake .m4a into the scratch location and returns its URL.
    private func makeTempAudio() throws -> URL {
        let url = scratch.appendingPathComponent("rec-\(UUID().uuidString).m4a")
        try Data("fake-audio".utf8).write(to: url)
        return url
    }

    func testCreateMovesAudioAndPersistsAcrossReload() throws {
        let store = MeetingStore(directory: dir)
        let temp = try makeTempAudio()

        let meeting = store.create(audioAt: temp, title: "Standup",
                                   participants: ["Alice", "Bob"], duration: 61)
        let created = try XCTUnwrap(meeting)

        // Audio moved, not copied
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: created).path))

        // Fresh store instance reads the same directory
        let reloaded = MeetingStore(directory: dir)
        XCTAssertEqual(reloaded.meetings.count, 1)
        XCTAssertEqual(reloaded.meetings[0].id, created.id)
        XCTAssertEqual(reloaded.meetings[0].title, "Standup")
        XCTAssertEqual(reloaded.meetings[0].participants, ["Alice", "Bob"])
        XCTAssertEqual(reloaded.meetings[0].duration, 61, accuracy: 0.001)
        XCTAssertNil(reloaded.meetings[0].analysis)
    }

    func testCreatePrependsNewestFirst() throws {
        let store = MeetingStore(directory: dir)
        _ = store.create(audioAt: try makeTempAudio(), title: "First", participants: [], duration: 1)
        _ = store.create(audioAt: try makeTempAudio(), title: "Second", participants: [], duration: 2)
        XCTAssertEqual(store.meetings.map(\.title), ["Second", "First"])
    }

    func testCreateWithNonexistentSourceReturnsNil() throws {
        let store = MeetingStore(directory: dir)
        let nonexistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).m4a")

        let result = store.create(audioAt: nonexistentURL, title: "Should Fail",
                                  participants: ["Alice"], duration: 10)

        XCTAssertNil(result, "create() should return nil when source file does not exist")
        XCTAssertTrue(store.lastError?.isEmpty == false, "lastError should be set")
        XCTAssertTrue(store.meetings.isEmpty, "meetings should be empty after failed create")
    }

    func testCreateRollsBackWhenIndexSaveFails() throws {
        let store = MeetingStore(directory: dir)
        let temp = try makeTempAudio()

        // Block saveIndex by making meetings.json a directory instead of a file
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let indexDir = dir.appendingPathComponent("meetings.json")
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        let result = store.create(audioAt: temp, title: "Will Rollback",
                                  participants: ["Bob"], duration: 15)

        XCTAssertNil(result, "create() should return nil when index save fails")
        XCTAssertTrue(store.lastError?.isEmpty == false, "lastError should be set by saveIndex")
        XCTAssertTrue(store.meetings.isEmpty, "meetings should be empty after rollback")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path),
                     "audio file should be moved back to temp location")

        // Verify no .m4a files remain in the store directory
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let audioFiles = contents.filter { $0.pathExtension == "m4a" }
        XCTAssertTrue(audioFiles.isEmpty, "no .m4a files should remain in store after rollback")
    }

    private func sampleAnalysis() -> MeetingAnalysisResponse {
        let json = """
        {"transcript":[{"speaker":"Alice","text":"Ship Friday."}],
         "summary":"We ship Friday.","sentiment":"collaborative",
         "action_items":["Bob: write release notes"],
         "follow_up_email":{"subject":"Recap","body":"Thanks all."}}
        """
        return try! JSONDecoder().decode(MeetingAnalysisResponse.self, from: Data(json.utf8))
    }

    func testUpdateAnalysisPersists() throws {
        let store = MeetingStore(directory: dir)
        let m = try XCTUnwrap(store.create(audioAt: try makeTempAudio(), title: "M",
                                           participants: [], duration: 5))
        store.updateAnalysis(id: m.id, analysis: sampleAnalysis(),
                             engine: "gemini", model: "gemini-3.5-flash")

        let reloaded = MeetingStore(directory: dir)
        XCTAssertEqual(reloaded.meetings[0].analysis?.summary, "We ship Friday.")
        XCTAssertEqual(reloaded.meetings[0].engine, "gemini")
        XCTAssertEqual(reloaded.meetings[0].model, "gemini-3.5-flash")
    }

    func testRenamePersistsAndRejectsEmpty() throws {
        let store = MeetingStore(directory: dir)
        let m = try XCTUnwrap(store.create(audioAt: try makeTempAudio(), title: "Old",
                                           participants: [], duration: 5))
        store.rename(id: m.id, to: "  New Title  ")
        store.rename(id: m.id, to: "   ")   // ignored
        let reloaded = MeetingStore(directory: dir)
        XCTAssertEqual(reloaded.meetings[0].title, "New Title")
    }

    func testDeleteRemovesEntryAndAudio() throws {
        let store = MeetingStore(directory: dir)
        let m = try XCTUnwrap(store.create(audioAt: try makeTempAudio(), title: "M",
                                           participants: [], duration: 5))
        let audio = store.audioURL(for: m)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        store.delete(id: m.id)
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(MeetingStore(directory: dir).meetings.isEmpty)
    }

    func testCorruptedIndexBacksUpAndStartsFresh() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json{{{".utf8).write(to: dir.appendingPathComponent("meetings.json"))
        let store = MeetingStore(directory: dir)
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("meetings.json.bak").path))
    }

    func testDeleteKeepsAudioAndEntryWhenIndexSaveFails() throws {
        let store = MeetingStore(directory: dir)
        let m = try XCTUnwrap(store.create(audioAt: try makeTempAudio(), title: "M",
                                           participants: [], duration: 5))
        let audioURL = store.audioURL(for: m)

        // Verify audio exists after create
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path),
                     "audio file should exist after create")

        // Break saveIndex by making meetings.json a directory instead of a file
        let indexDir = dir.appendingPathComponent("meetings.json")
        try? FileManager.default.removeItem(at: indexDir)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        // Clear lastError from the create operation
        store.lastError = nil

        // Call delete — it should fail to save but keep the entry and audio
        store.delete(id: m.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path),
                     "audio file should still exist when index save fails")
        XCTAssertEqual(store.meetings.count, 1, "meeting entry should still exist in memory")
        XCTAssertTrue(store.lastError?.isEmpty == false, "lastError should be set by failed saveIndex")
    }

    func testRenameRevertsWhenIndexSaveFails() throws {
        let store = MeetingStore(directory: dir)
        let m = try XCTUnwrap(store.create(audioAt: try makeTempAudio(), title: "Original",
                                           participants: [], duration: 5))

        // Break saveIndex by making meetings.json a directory instead of a file
        let indexDir = dir.appendingPathComponent("meetings.json")
        try? FileManager.default.removeItem(at: indexDir)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        // Clear lastError from the create operation
        store.lastError = nil

        // Call rename — it should fail to save but keep the old title
        store.rename(id: m.id, to: "Changed")

        XCTAssertEqual(store.meetings[0].title, "Original",
                      "title should revert when index save fails")
        XCTAssertTrue(store.lastError?.isEmpty == false, "lastError should be set by failed saveIndex")
    }

    func testUpdateAnalysisRevertsWhenIndexSaveFails() throws {
        let store = MeetingStore(directory: dir)
        let m = try XCTUnwrap(store.create(audioAt: try makeTempAudio(), title: "M",
                                           participants: [], duration: 5))

        // Break saveIndex by making meetings.json a directory instead of a file
        let indexDir = dir.appendingPathComponent("meetings.json")
        try? FileManager.default.removeItem(at: indexDir)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        // Clear lastError from the create operation
        store.lastError = nil

        // Call updateAnalysis — it should fail to save but revert the in-memory change
        store.updateAnalysis(id: m.id, analysis: sampleAnalysis(), engine: "gemini",
                             model: "gemini-3.5-flash")

        XCTAssertNil(store.meetings[0].analysis, "analysis should revert when index save fails")
        XCTAssertNil(store.meetings[0].engine, "engine should revert when index save fails")
        XCTAssertTrue(store.lastError?.isEmpty == false, "lastError should be set by failed saveIndex")
    }
}
