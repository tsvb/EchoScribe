import XCTest

final class MeetingStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes a fake .m4a into a scratch location and returns its URL.
    private func makeTempAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
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
}
