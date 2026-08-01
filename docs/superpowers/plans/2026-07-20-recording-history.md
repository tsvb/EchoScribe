# Recording History & Engine-Agnostic Analysis Implementation Plan

**Status:** Complete — implemented and merged to main 2026-07-20. Historical record; do not execute.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist every recording + analysis as a browsable meeting history, and make analysis engine-agnostic: Apple on-device (SpeechTranscriber + FoundationModels) with no API key, or Gemini (optional).

**Architecture:** A `MeetingStore` (JSON index + one `.m4a` per meeting in `~/Library/Application Support/EchoScribe/`) becomes the single source of truth the UI renders from. An `AnalysisEngine` protocol seams the analysis call; `GeminiEngine` wraps the existing `GeminiClient`, `AppleAnalysisEngine` (Phase 2) transcribes on-device and summarizes via chunked FoundationModels sessions (Apple TN3193 map-reduce).

**Tech Stack:** Swift/SwiftUI, XcodeGen, XCTest, AVFoundation (`AVAudioPlayer`), Speech (`SpeechAnalyzer`/`SpeechTranscriber`, macOS 26+), FoundationModels (`LanguageModelSession`, `@Generable`, macOS 26+).

**Spec:** `docs/superpowers/specs/2026-07-20-recording-history-design.md`

## Global Constraints

- All work in `macos-native/`. The `.xcodeproj` is generated: after adding/renaming ANY file or editing `project.yml`, run `cd macos-native && xcodegen generate`.
- Build gate: `xcodebuild -project EchoScribe.xcodeproj -scheme EchoScribe -configuration Debug build CODE_SIGNING_ALLOWED=NO` → must end `** BUILD SUCCEEDED **`.
- Test gate: `xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe` → must end `** TEST SUCCEEDED **`.
- Ignore SourceKit per-file editor diagnostics ("Cannot find X in scope", "No such module XCTest") — files are analyzed in isolation; `xcodebuild` is the source of truth.
- Deployment target is macOS 14.0. Every macOS-26 API (Speech's `SpeechAnalyzer` family, FoundationModels) must sit behind `@available(macOS 26.0, *)` / `#available`.
- Audio files are NEVER deleted except inside `MeetingStore.delete(id:)`.
- Existing 7 `GeminiClientErrorTests` must stay green in every task.
- Commit after every task; end commit messages with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

---

## Phase 1 — History + engine seam

### Task 1: Meeting model + MeetingStore create/load

**Files:**
- Create: `macos-native/MeetingStore.swift`
- Modify: `macos-native/project.yml` (add store to test-target sources)
- Test: `macos-native/Tests/MeetingStoreTests.swift`

**Interfaces:**
- Consumes: `MeetingAnalysisResponse` (Codable, from `GeminiClient.swift`).
- Produces: `struct Meeting: Codable, Identifiable` (fields: `id: UUID`, `title: String`, `createdAt: Date`, `duration: TimeInterval`, `participants: [String]`, `engine: String?`, `model: String?`, `analysis: MeetingAnalysisResponse?`, `audioFileName: String`); `final class MeetingStore: ObservableObject` with `init(directory: URL = MeetingStore.defaultDirectory())`, `@Published private(set) var meetings: [Meeting]`, `@Published var lastError: String?`, `@discardableResult func create(audioAt:title:participants:duration:) -> Meeting?`, `func audioURL(for: Meeting) -> URL`.

- [ ] **Step 1: Write the failing tests**

Create `macos-native/Tests/MeetingStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Add test sources to project.yml and verify tests fail to compile**

In `macos-native/project.yml`, change the test-target sources block from:

```yaml
    sources:
      - path: Tests
      - path: GeminiClient.swift
```

to:

```yaml
    sources:
      - path: Tests
      - path: GeminiClient.swift
      - path: MeetingStore.swift
```

Run: `cd macos-native && xcodegen generate && xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe 2>&1 | tail -5`
Expected: FAIL — `MeetingStore.swift` does not exist yet / `Cannot find 'MeetingStore' in scope`.

- [ ] **Step 3: Implement MeetingStore (create/load/audioURL only)**

Create `macos-native/MeetingStore.swift`:

```swift
import Foundation
import Combine

/// One recorded meeting: durable audio + optional analysis + provenance.
struct Meeting: Codable, Identifiable {
    let id: UUID
    var title: String
    let createdAt: Date
    let duration: TimeInterval
    var participants: [String]
    var engine: String?                     // "apple" | "gemini" — what produced the analysis
    var model: String?                      // e.g. "gemini-3.5-flash" or "apple-on-device"
    var analysis: MeetingAnalysisResponse?  // nil = not analyzed yet
    var audioFileName: String               // "<id>.m4a", relative to the store directory
}

/// Owns ~/Library/Application Support/EchoScribe/: meetings.json (index, newest
/// first) plus one .m4a per meeting. Single source of truth for the history UI.
/// The directory is injectable so tests point it at a temp dir.
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var lastError: String?

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("meetings.json") }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EchoScribe", isDirectory: true)
    }

    init(directory: URL = MeetingStore.defaultDirectory()) {
        self.directory = directory
        load()
    }

    func audioURL(for meeting: Meeting) -> URL {
        directory.appendingPathComponent(meeting.audioFileName)
    }

    /// Moves (not copies) the finished recording into the store and prepends the
    /// meeting. Returns nil (and sets lastError) if the move or save fails.
    @discardableResult
    func create(audioAt tempURL: URL, title: String, participants: [String],
                duration: TimeInterval) -> Meeting? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let id = UUID()
            let fileName = "\(id.uuidString).m4a"
            try FileManager.default.moveItem(at: tempURL,
                                             to: directory.appendingPathComponent(fileName))
            let meeting = Meeting(id: id, title: title, createdAt: Date(), duration: duration,
                                  participants: participants, engine: nil, model: nil,
                                  analysis: nil, audioFileName: fileName)
            meetings.insert(meeting, at: 0)
            saveIndex()
            return meeting
        } catch {
            lastError = "Failed to save recording: \(error.localizedDescription)"
            return nil
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return } // first launch
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            meetings = try decoder.decode([Meeting].self, from: data)
        } catch {
            // Corrupted index: keep the evidence, never touch audio files.
            let backup = directory.appendingPathComponent("meetings.json.bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: indexURL, to: backup)
            meetings = []
            lastError = "Meeting index was unreadable — moved to meetings.json.bak and started fresh. Audio files were kept."
        }
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (try encoder.encode(meetings)).write(to: indexURL, options: .atomic)
        } catch {
            lastError = "Failed to save meeting index: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe 2>&1 | grep -E "Test Case.*(passed|failed)|TEST"`
Expected: 2 new tests + 7 existing tests pass, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macos-native/MeetingStore.swift macos-native/Tests/MeetingStoreTests.swift macos-native/project.yml
git commit -m "Add MeetingStore: persistent meeting index + audio ingestion"
```

---

### Task 2: MeetingStore mutations + corruption recovery

**Files:**
- Modify: `macos-native/MeetingStore.swift`
- Test: `macos-native/Tests/MeetingStoreTests.swift`

**Interfaces:**
- Produces: `func updateAnalysis(id: UUID, analysis: MeetingAnalysisResponse, engine: String, model: String)`, `func rename(id: UUID, to: String)`, `func delete(id: UUID)`.

- [ ] **Step 1: Write the failing tests** (append inside `MeetingStoreTests`)

```swift
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
        let m = try XCTUnwrap(store.create(audioAt: makeTempAudio(), title: "M",
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
        let m = try XCTUnwrap(store.create(audioAt: makeTempAudio(), title: "Old",
                                           participants: [], duration: 5))
        store.rename(id: m.id, to: "  New Title  ")
        store.rename(id: m.id, to: "   ")   // ignored
        let reloaded = MeetingStore(directory: dir)
        XCTAssertEqual(reloaded.meetings[0].title, "New Title")
    }

    func testDeleteRemovesEntryAndAudio() throws {
        let store = MeetingStore(directory: dir)
        let m = try XCTUnwrap(store.create(audioAt: makeTempAudio(), title: "M",
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
```

Note: `makeTempAudio()` already exists from Task 1; if Task 1's helper is marked `private func makeTempAudio() throws`, call sites here need `try` (as shown).

- [ ] **Step 2: Run tests to verify the three mutation tests fail**

Run: `xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe 2>&1 | grep -E "failed|error:" | head -10`
Expected: compile errors — `updateAnalysis`, `rename`, `delete` not defined. (`testCorruptedIndexBacksUpAndStartsFresh` already passes once it compiles — recovery shipped in Task 1.)

- [ ] **Step 3: Implement the three mutations** (add to `MeetingStore`, before `private func load()`)

```swift
    func updateAnalysis(id: UUID, analysis: MeetingAnalysisResponse, engine: String, model: String) {
        guard let idx = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[idx].analysis = analysis
        meetings[idx].engine = engine
        meetings[idx].model = model
        saveIndex()
    }

    func rename(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[idx].title = trimmed
        saveIndex()
    }

    func delete(id: UUID) {
        guard let idx = meetings.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: audioURL(for: meetings[idx]))
        meetings.remove(at: idx)
        saveIndex()
    }
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe 2>&1 | grep -cE "Test Case.*passed"` then `... | grep TEST`
Expected: 13 passed (7 Gemini + 6 store), `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macos-native/MeetingStore.swift macos-native/Tests/MeetingStoreTests.swift
git commit -m "Add MeetingStore mutations: updateAnalysis, rename, delete"
```

---

### Task 3: AnalysisEngine protocol, GeminiEngine, EngineResolver

**Files:**
- Create: `macos-native/AnalysisEngine.swift`
- Modify: `macos-native/project.yml` (add `AnalysisEngine.swift` to test-target sources, same pattern as Task 1 Step 2)
- Test: `macos-native/Tests/EngineResolverTests.swift`

**Interfaces:**
- Consumes: `GeminiClient.requestAnalysis(audioData:mimeType:apiKey:model:title:participants:completion:)`, `GeminiClient.error`.
- Produces:
  - `struct AnalysisError: LocalizedError { let message: String }`
  - `protocol AnalysisEngine { var id: String { get }; var modelName: String { get }; func analyze(audioURL: URL, title: String, participants: [String], progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse }`
  - `final class GeminiEngine: AnalysisEngine` with `init(client: GeminiClient, apiKey: String, model: String)`
  - `enum EnginePreference: String { case auto, apple, gemini }`
  - `struct EngineContext { let appleAvailable: Bool; let hasGeminiKey: Bool }`
  - `enum EngineChoice: Equatable { case apple; case gemini; case none(reason: String) }`
  - `func resolveEngine(preference: EnginePreference, context: EngineContext) -> EngineChoice`

- [ ] **Step 1: Write the failing resolver tests**

Create `macos-native/Tests/EngineResolverTests.swift`:

```swift
import XCTest

final class EngineResolverTests: XCTestCase {
    func testAutoPrefersAppleWhenAvailable() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: true, hasGeminiKey: true))
        XCTAssertEqual(c, .apple)
    }

    func testAutoFallsBackToGeminiWithKey() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false, hasGeminiKey: true))
        XCTAssertEqual(c, .gemini)
    }

    func testAutoWithNothingExplainsBothFixes() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false, hasGeminiKey: false))
        guard case .none(let reason) = c else { return XCTFail("expected .none") }
        XCTAssertTrue(reason.contains("Apple Intelligence"), reason)
        XCTAssertTrue(reason.contains("Gemini"), reason)
    }

    func testExplicitAppleUnavailableFails() {
        let c = resolveEngine(preference: .apple,
                              context: EngineContext(appleAvailable: false, hasGeminiKey: true))
        guard case .none = c else { return XCTFail("expected .none") }
    }

    func testExplicitGeminiWithoutKeyFails() {
        let c = resolveEngine(preference: .gemini,
                              context: EngineContext(appleAvailable: true, hasGeminiKey: false))
        guard case .none = c else { return XCTFail("expected .none") }
    }
}
```

- [ ] **Step 2: Add `AnalysisEngine.swift` to test-target sources in project.yml, regenerate, verify failure**

Run: `xcodegen generate && xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe 2>&1 | grep -E "error:" | head -5`
Expected: `Cannot find 'resolveEngine' in scope` (and the file missing from the app target until created).

- [ ] **Step 3: Implement**

Create `macos-native/AnalysisEngine.swift`:

```swift
import Foundation

struct AnalysisError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Seam between the app and whatever produces a MeetingAnalysisResponse.
/// Implementations: GeminiEngine (cloud, optional key), AppleAnalysisEngine
/// (on-device, macOS 26+, added in Phase 2).
protocol AnalysisEngine {
    var id: String { get }          // "apple" | "gemini" — stored on Meeting.engine
    var modelName: String { get }   // stored on Meeting.model
    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse
}

// MARK: - Engine selection (pure, unit-tested)

enum EnginePreference: String {
    case auto, apple, gemini
}

struct EngineContext {
    let appleAvailable: Bool
    let hasGeminiKey: Bool
}

enum EngineChoice: Equatable {
    case apple
    case gemini
    case none(reason: String)
}

func resolveEngine(preference: EnginePreference, context: EngineContext) -> EngineChoice {
    switch preference {
    case .apple:
        return context.appleAvailable ? .apple : .none(reason:
            "Apple Intelligence isn't available on this Mac. Enable it in System Settings, or switch the analysis engine to Gemini.")
    case .gemini:
        return context.hasGeminiKey ? .gemini : .none(reason:
            "No Gemini API key configured. Add one in Settings, or switch the analysis engine to Apple (on-device).")
    case .auto:
        if context.appleAvailable { return .apple }
        if context.hasGeminiKey { return .gemini }
        return .none(reason:
            "No analysis engine available. Enable Apple Intelligence for on-device analysis, or add a Gemini API key in Settings.")
    }
}

// MARK: - Gemini engine (adapter over the existing client)

final class GeminiEngine: AnalysisEngine {
    let id = "gemini"
    var modelName: String { model }

    private let client: GeminiClient
    private let apiKey: String
    private let model: String

    init(client: GeminiClient, apiKey: String, model: String) {
        self.client = client
        self.apiKey = apiKey
        self.model = model
    }

    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse {
        guard !apiKey.isEmpty else {
            throw AnalysisError(message: "No Gemini API key configured. Add one in Settings.")
        }
        progress("Encoding audio for Gemini…")
        let audioData = try Data(contentsOf: audioURL)   // background: analyze() runs off-main
        progress("Sending multimodal payload to Gemini…")
        return try await withCheckedThrowingContinuation { continuation in
            client.requestAnalysis(audioData: audioData, mimeType: "audio/mp4",
                                   apiKey: apiKey, model: model,
                                   title: title, participants: participants) { result in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    // Completion runs on the main queue after client.error is set.
                    continuation.resume(throwing: AnalysisError(
                        message: self.client.error ?? "Gemini analysis failed."))
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `xcodegen generate && xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe 2>&1 | grep -E "Test Suite|TEST"`
Expected: suites `EngineResolverTests` (5), `MeetingStoreTests` (6), `GeminiClientErrorTests` (7) all pass; `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macos-native/AnalysisEngine.swift macos-native/Tests/EngineResolverTests.swift macos-native/project.yml
git commit -m "Add AnalysisEngine seam: protocol, GeminiEngine adapter, resolver"
```

---

### Task 4: Unique recording files + AudioPlaybackManager

**Files:**
- Modify: `macos-native/AudioRecorderManager.swift:28-31`
- Create: `macos-native/AudioPlaybackManager.swift`

**Interfaces:**
- Produces: recordings land at `FileManager.default.temporaryDirectory/EchoScribe-<UUID>.m4a` (unique per session; `stopRecording` completion still hands back the URL); `final class AudioPlaybackManager: ObservableObject` with `@Published var isPlaying: Bool`, `@Published var currentTime: TimeInterval`, `private(set) var currentURL: URL?`, `func togglePlayback(url: URL)`, `func stop()`.

- [ ] **Step 1: Point the recorder at a unique temp file**

In `AudioRecorderManager.startRecording()`, replace:

```swift
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioURL = documentDirectory.appendingPathComponent("EchoScribe_Record.m4a")
        self.recordedURL = audioURL
```

with:

```swift
        // Unique temp file per session — MeetingStore takes ownership on stop.
        // (The old fixed ~/Documents path silently overwrote every prior recording.)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoScribe-\(UUID().uuidString).m4a")
        self.recordedURL = audioURL
```

- [ ] **Step 2: Create the playback manager**

Create `macos-native/AudioPlaybackManager.swift`:

```swift
import Foundation
import AVFoundation
import Combine

/// Plays back a stored meeting recording. One player at a time; toggling on a
/// different URL switches to it.
final class AudioPlaybackManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var lastError: String?

    private(set) var currentURL: URL?
    private var player: AVAudioPlayer?
    private var timer: AnyCancellable?

    func togglePlayback(url: URL) {
        if currentURL == url, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
            return
        }
        play(url: url)
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.cancel()
        timer = nil
        currentURL = nil
        isPlaying = false
        currentTime = 0
    }

    private func play(url: URL) {
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            player = p
            currentURL = url
            p.play()
            isPlaying = true
            timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.currentTime = self?.player?.currentTime ?? 0 }
        } catch {
            lastError = "Couldn't play recording: \(error.localizedDescription)"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stop()
    }
}
```

- [ ] **Step 3: Build gate**

Run: `xcodegen generate && xcodebuild -project EchoScribe.xcodeproj -scheme EchoScribe -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add macos-native/AudioRecorderManager.swift macos-native/AudioPlaybackManager.swift
git commit -m "Record to unique temp files; add AudioPlaybackManager"
```

---

### Task 5: ContentView — store-backed state, save-on-stop, un-gated recording

**Files:**
- Modify: `macos-native/ContentView.swift`

**Interfaces:**
- Consumes: `MeetingStore`, `AnalysisEngine`/`GeminiEngine`/`resolveEngine`, `AudioPlaybackManager` (Tasks 1–4).
- Produces: `@State selectedMeetingID: UUID?`, `var selectedMeeting: Meeting?`, `func runAnalysis(on: Meeting)`, `func startNewMeeting()`, `@State analysisError: String?`, `var displayedError: String?` — Tasks 6–7 build UI on these exact names.

- [ ] **Step 1: Add state objects and selection state**

In `ContentView`, replace:

```swift
    // Subsystem States
    @StateObject private var recorder = AudioRecorderManager()
    @StateObject private var speechManager = SpeechTranscriptionManager()
    @StateObject private var gemini = GeminiClient()
    @StateObject private var eventKit = EventKitManager()
```

with:

```swift
    // Subsystem States
    @StateObject private var recorder = AudioRecorderManager()
    @StateObject private var speechManager = SpeechTranscriptionManager()
    @StateObject private var gemini = GeminiClient()
    @StateObject private var eventKit = EventKitManager()
    @StateObject private var store = MeetingStore()
    @StateObject private var playback = AudioPlaybackManager()

    // History / selection state. The store is the single source of truth: the
    // workspace always renders the SELECTED meeting's stored analysis.
    @State private var selectedMeetingID: UUID?
    @State private var analysisError: String?

    // Engine preference ("auto" | "apple" | "gemini"). Apple engine lands in
    // Phase 2 — until then availability is hardwired false.
    @AppStorage("analysis_engine") private var enginePreferenceRaw = "auto"
    private var appleEngineAvailable: Bool { false }   // Phase 2 replaces this

    private var selectedMeeting: Meeting? {
        store.meetings.first { $0.id == selectedMeetingID }
    }

    private var displayedError: String? {
        analysisError ?? store.lastError
    }
```

- [ ] **Step 2: Un-gate recording**

In `toggleRecording()`, delete these lines (recording must never require a key):

```swift
        if apiKey.isEmpty {
            showSettings = true
            return
        }
```

- [ ] **Step 3: Replace stopAndAnalyze with save-first + engine-based analysis**

Replace the entire `func stopAndAnalyze() { ... }` with:

```swift
    func stopAndAnalyze() {
        stepState = "Processing"
        progressText = "Saving recording..."
        analysisError = nil

        let duration = recorder.elapsedSeconds
        recorder.stopRecording { url in
            guard let url = url else {
                stepState = "Idle"
                return
            }
            // Audio becomes durable BEFORE any analysis: an engine failure
            // leaves the meeting saved as "Not analyzed".
            guard let meeting = store.create(audioAt: url, title: meetingTitle,
                                             participants: participants,
                                             duration: duration) else {
                stepState = "Idle"
                return
            }
            selectedMeetingID = meeting.id
            runAnalysis(on: meeting)
        }
    }

    func runAnalysis(on meeting: Meeting) {
        analysisError = nil
        let preference = EnginePreference(rawValue: enginePreferenceRaw) ?? .auto
        let context = EngineContext(appleAvailable: appleEngineAvailable,
                                    hasGeminiKey: !apiKey.isEmpty)
        let engine: AnalysisEngine
        switch resolveEngine(preference: preference, context: context) {
        case .gemini:
            engine = GeminiEngine(client: gemini, apiKey: apiKey, model: selectedModel)
        case .apple:
            // Phase 2 instantiates AppleAnalysisEngine here.
            analysisError = "On-device analysis isn't wired up yet."
            stepState = "Idle"
            return
        case .none(let reason):
            analysisError = reason
            stepState = "Idle"
            return
        }

        stepState = "Processing"
        let audioURL = store.audioURL(for: meeting)
        Task {
            do {
                let analysis = try await engine.analyze(
                    audioURL: audioURL, title: meeting.title,
                    participants: meeting.participants
                ) { message in
                    Task { @MainActor in progressText = message }
                }
                await MainActor.run {
                    store.updateAnalysis(id: meeting.id, analysis: analysis,
                                         engine: engine.id, model: engine.modelName)
                    stepState = "Results"
                }
            } catch {
                await MainActor.run {
                    analysisError = error.localizedDescription
                    stepState = "Idle"
                }
            }
        }
    }

    func startNewMeeting() {
        selectedMeetingID = nil
        playback.stop()
        analysisError = nil
        stepState = "Idle"
    }
```

- [ ] **Step 4: Render from the store, not gemini.result**

(a) Replace the results-branch condition:

```swift
                            } else if let analysis = gemini.result {
```

with:

```swift
                            } else if let meeting = selectedMeeting, let analysis = meeting.analysis {
```

(b) The three action helpers currently guard on `gemini.result`. Replace each `guard let analysis = gemini.result else { return }` (in `syncToReminders`, `copyEmailToClipboard`, `openInMailApp`) with:

```swift
        guard let analysis = selectedMeeting?.analysis else { return }
```

(c) In the empty-state error card added earlier, replace `if let apiError = gemini.error {` with `if let apiError = displayedError {` and replace the dismiss button's `gemini.error = nil` with `analysisError = nil; store.lastError = nil`.

- [ ] **Step 5: Build gate + commit**

Run: `xcodebuild -project EchoScribe.xcodeproj -scheme EchoScribe -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`. Then:

```bash
git add macos-native/ContentView.swift
git commit -m "Render workspace from MeetingStore; save-on-stop; un-gate recording"
```

---

### Task 6: History list UI (open / rename / delete / New Meeting)

**Files:**
- Modify: `macos-native/ContentView.swift` (left panel + new subview at file bottom)

**Interfaces:**
- Consumes: `store`, `selectedMeetingID`, `startNewMeeting()`, `runAnalysis(on:)`, `playback` (Task 5).
- Produces: `MeetingRow` view; `meetingHistorySection` computed view.

- [ ] **Step 1: Add the history section to the left panel**

The left-panel VStack ends with the participants section. Find its closing (the participants `.frame(height: 35)` block followed by two closing braces and `.padding(24)` / `.frame(width: 380)`), and insert **as the last element of that VStack**, immediately after the participants section:

```swift
                            Divider().background(Color.white.opacity(0.05))

                            meetingHistorySection
```

- [ ] **Step 2: Add the section + row implementations**

Add inside `ContentView` (near the other computed views/helpers):

```swift
    // Section: Previous meetings
    private var meetingHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Previous Meetings (\(store.meetings.count))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .textCase(.uppercase)
                Spacer()
                Button(action: startNewMeeting) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .foregroundStyle(.white.opacity(0.8))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if store.meetings.isEmpty {
                Text("Recordings you make will appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.meetings) { meeting in
                            MeetingRow(
                                meeting: meeting,
                                isSelected: meeting.id == selectedMeetingID,
                                onOpen: {
                                    selectedMeetingID = meeting.id
                                    analysisError = nil
                                    stepState = meeting.analysis == nil ? "Idle" : "Results"
                                },
                                onRename: { newTitle in store.rename(id: meeting.id, to: newTitle) },
                                onReanalyze: { runAnalysis(on: meeting) },
                                onDelete: {
                                    if selectedMeetingID == meeting.id { startNewMeeting() }
                                    store.delete(id: meeting.id)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
```

- [ ] **Step 3: Add `MeetingRow` at the bottom of ContentView.swift** (top-level, after the existing `AudioLevelVisualizer` struct)

```swift
/// One compact history row: status dot, title (inline-renamable), date · duration,
/// engine badge. Row-local rename state keeps ContentView untouched.
struct MeetingRow: View {
    let meeting: Meeting
    let isSelected: Bool
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onReanalyze: () -> Void
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var draftTitle = ""

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(meeting.analysis == nil ? Color.orange : Color.green)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .onSubmit {
                            isRenaming = false
                            onRename(draftTitle)
                        }
                        .onExitCommand { isRenaming = false }
                } else {
                    Text(meeting.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text("\(Self.dateFormatter.string(from: meeting.createdAt)) · \(Self.formatDuration(meeting.duration))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer(minLength: 4)

            if let engine = meeting.engine {
                Text(engine == "apple" ? "On-device" : "Gemini")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.07))
                    .foregroundStyle(.white.opacity(0.6))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Rename") {
                draftTitle = meeting.title
                isRenaming = true
            }
            Button("Re-analyze") { onReanalyze() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
```

- [ ] **Step 4: Build gate + commit**

Run: `xcodebuild -project EchoScribe.xcodeproj -scheme EchoScribe -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`.

```bash
git add macos-native/ContentView.swift
git commit -m "Add history list: open, inline rename, re-analyze, delete, New Meeting"
```

---

### Task 7: Meeting detail header (play / re-analyze) + not-analyzed state — Phase 1 checkpoint

**Files:**
- Modify: `macos-native/ContentView.swift`

**Interfaces:**
- Consumes: everything from Tasks 5–6.
- Produces: `meetingHeader(_:)`, `notAnalyzedView(_:)` view builders; complete right-panel branch structure.

- [ ] **Step 1: Insert the header into the analyzed branch**

The analyzed branch (Task 5 changed its condition) starts:

```swift
                            } else if let meeting = selectedMeeting, let analysis = meeting.analysis {
                                // Dynamic results view with tabs
                                VStack(spacing: 0) {
                                    // Tab buttons header
```

Insert `meetingHeader(meeting)` as the first child of that `VStack(spacing: 0)`, directly above the `// Tab buttons header` comment line:

```swift
                                VStack(spacing: 0) {
                                    meetingHeader(meeting)
                                    // Tab buttons header
```

- [ ] **Step 2: Add the not-analyzed branch**

Immediately after the analyzed branch's closing `.frame(maxWidth: .infinity, maxHeight: .infinity)` and before `} else {` (the empty state), insert:

```swift
                            } else if let meeting = selectedMeeting {
                                // Saved but not analyzed (engine failed or none configured)
                                VStack(spacing: 0) {
                                    meetingHeader(meeting)
                                    notAnalyzedView(meeting)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
```

- [ ] **Step 3: Implement the two view builders** (inside `ContentView`, next to `meetingHistorySection`)

```swift
    @ViewBuilder
    private func meetingHeader(_ meeting: Meeting) -> some View {
        let audioURL = store.audioURL(for: meeting)
        let audioExists = FileManager.default.fileExists(atPath: audioURL.path)
        let isThisPlaying = playback.isPlaying && playback.currentURL == audioURL

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(MeetingRow.headerDate(meeting.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Button(action: { playback.togglePlayback(url: audioURL) }) {
                HStack(spacing: 6) {
                    Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                    Text(isThisPlaying
                         ? MeetingRow.clock(playback.currentTime)
                         : MeetingRow.clock(meeting.duration))
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .foregroundStyle(.white.opacity(audioExists ? 0.9 : 0.3))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!audioExists)

            Button(action: { runAnalysis(on: meeting) }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Re-analyze")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(accentPurple.opacity(0.15))
                .foregroundStyle(.white.opacity(audioExists ? 0.9 : 0.3))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!audioExists || stepState == "Processing")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.25))
    }

    @ViewBuilder
    private func notAnalyzedView(_ meeting: Meeting) -> some View {
        VStack(spacing: 16) {
            if let apiError = displayedError {
                errorCard(apiError)
            }
            Image(systemName: "doc.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.25))
            Text("Not analyzed yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("The recording is saved. Run analysis to generate the transcript, summary, action items, and follow-up email.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

- [ ] **Step 4: Extract the error card into a reusable builder**

The empty state currently contains the inline error card (`if let apiError = displayedError { VStack(alignment: .leading, ...) ... .padding(.bottom, 12) }`). Cut that whole inner card view out of the empty state, replace it with:

```swift
                                    if let apiError = displayedError {
                                        errorCard(apiError)
                                            .padding(.bottom, 12)
                                    }
```

and paste the card body into a new builder next to `notAnalyzedView`:

```swift
    @ViewBuilder
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text("Analysis Failed")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { analysisError = nil; store.lastError = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            Text(message)
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(.white.opacity(0.75))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Settings") { showSettings = true }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.25), lineWidth: 1))
    }
```

- [ ] **Step 5: Add the two small static formatters to `MeetingRow`**

```swift
    static func headerDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        formatDuration(seconds)
    }
```

(Requires `formatDuration` to be `private static func` already — it is.)

- [ ] **Step 6: Full gate — tests + build**

Run: `xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe 2>&1 | grep -E "Test Suite|TEST"` then the build-gate command.
Expected: 18 tests pass; `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Manual smoke checkpoint (human)**

Launch from Xcode: record 5s → stop → meeting appears in history, analysis runs (or clear error if keyless) → quit + relaunch → meeting still there, opens with analysis → rename, play, delete each work → New Meeting resets the workspace.

- [ ] **Step 8: Commit**

```bash
git add macos-native/ContentView.swift
git commit -m "Add meeting detail header, playback, not-analyzed state (Phase 1 done)"
```

---

## Phase 2 — Apple on-device engine

### Task 8: TranscriptChunker (pure, tested)

**Files:**
- Create: `macos-native/TranscriptChunker.swift`
- Modify: `macos-native/project.yml` (add `TranscriptChunker.swift` to test-target sources)
- Test: `macos-native/Tests/TranscriptChunkerTests.swift`

**Interfaces:**
- Produces: `protocol TokenCounting { func tokenCount(for text: String) -> Int }`, `struct EstimatedTokenCounter: TokenCounting` (chars/3 heuristic), `struct TranscriptChunker { init(counter: TokenCounting, budget: Int); func chunk(_ text: String) -> [String] }`.

- [ ] **Step 1: Write the failing tests**

Create `macos-native/Tests/TranscriptChunkerTests.swift`:

```swift
import XCTest

/// Counts 1 token per character — makes budgets exact in tests.
private struct CharCounter: TokenCounting {
    func tokenCount(for text: String) -> Int { text.count }
}

final class TranscriptChunkerTests: XCTestCase {
    func testShortInputIsSingleChunk() {
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 100)
        XCTAssertEqual(chunker.chunk("hello world"), ["hello world"])
    }

    func testEmptyInputYieldsNoChunks() {
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 100)
        XCTAssertTrue(chunker.chunk("   \n  ").isEmpty)
    }

    func testParagraphsPackGreedilyUnderBudget() {
        let text = "aaaa\nbbbb\ncccc\ndddd"   // 4-char paragraphs
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 9)
        let chunks = chunker.chunk(text)
        // "aaaa\nbbbb" = 9 tokens fits; "cccc\ndddd" = 9 fits.
        XCTAssertEqual(chunks, ["aaaa\nbbbb", "cccc\ndddd"])
    }

    func testEveryChunkRespectsBudgetAndCoversAllText() {
        let words = (0..<200).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let counter = CharCounter()
        let chunker = TranscriptChunker(counter: counter, budget: 50)
        let chunks = chunker.chunk(text)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(counter.tokenCount(for: chunk), 50, chunk)
            XCTAssertFalse(chunk.isEmpty)
        }
        // Every word survives, in order.
        let rejoined = chunks.joined(separator: " ").split(separator: " ").map(String.init)
        let expected = text.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ").map(String.init)
        XCTAssertEqual(rejoined, expected)
    }

    func testOversizedSingleParagraphIsHardSplit() {
        let text = String(repeating: "x", count: 30) // no spaces or newlines
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 10)
        let chunks = chunker.chunk(text)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 10) }
        XCTAssertEqual(chunks.joined(), text)
    }
}
```

- [ ] **Step 2: Regenerate + verify compile failure** (`Cannot find 'TranscriptChunker' in scope`)

- [ ] **Step 3: Implement**

Create `macos-native/TranscriptChunker.swift`:

```swift
import Foundation

protocol TokenCounting {
    func tokenCount(for text: String) -> Int
}

/// Conservative heuristic (~3 chars/token for English). Used instead of the
/// FoundationModels tokenizer so chunking stays pure and unit-testable; the
/// budget below leaves ample headroom in the 4,096-token window (TN3193).
struct EstimatedTokenCounter: TokenCounting {
    func tokenCount(for text: String) -> Int { max(1, text.count / 3) }
}

/// Splits a transcript into chunks that each fit a token budget, preferring
/// paragraph boundaries, then word boundaries, then hard character splits.
struct TranscriptChunker {
    let counter: TokenCounting
    let budget: Int

    func chunk(_ text: String) -> [String] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : current + "\n" + paragraph
            if counter.tokenCount(for: candidate) <= budget {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current); current = "" }
                if counter.tokenCount(for: paragraph) <= budget {
                    current = paragraph
                } else {
                    chunks.append(contentsOf: splitOversized(paragraph))
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Word-boundary packing; falls back to fixed-size character slices for a
    /// single "word" longer than the budget.
    private func splitOversized(_ paragraph: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in paragraph.split(separator: " ").map(String.init) {
            if counter.tokenCount(for: word) > budget {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSlices(word))
                continue
            }
            let candidate = current.isEmpty ? word : current + " " + word
            if counter.tokenCount(for: candidate) <= budget {
                current = candidate
            } else {
                chunks.append(current)
                current = word
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func hardSlices(_ word: String) -> [String] {
        var slices: [String] = []
        var slice = ""
        for ch in word {
            if counter.tokenCount(for: slice + String(ch)) > budget {
                slices.append(slice)
                slice = String(ch)
            } else {
                slice.append(ch)
            }
        }
        if !slice.isEmpty { slices.append(slice) }
        return slices
    }
}
```

- [ ] **Step 4: Run tests** — expected 23 pass, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macos-native/TranscriptChunker.swift macos-native/Tests/TranscriptChunkerTests.swift macos-native/project.yml
git commit -m "Add TranscriptChunker for FoundationModels map-reduce budgeting"
```

---

### Task 9: AppleAnalysisEngine — on-device transcription

**Files:**
- Create: `macos-native/AppleAnalysisEngine.swift`

**Interfaces:**
- Consumes: `AnalysisEngine`, `AnalysisError`, `TranscriptSegment` (memberwise `init(speaker:text:)`).
- Produces: `@available(macOS 26.0, *) final class AppleAnalysisEngine: AnalysisEngine` (`id == "apple"`, `modelName == "apple-on-device"`); internal `static func transcribe(url: URL, progress: @escaping (String) -> Void) async throws -> String`; `static func transcriptSegments(from text: String) -> [TranscriptSegment]`. Task 10 adds `summarize` and the full `analyze`.

- [ ] **Step 1: Create the file with transcription + segmentation**

Create `macos-native/AppleAnalysisEngine.swift`:

```swift
import Foundation
import AVFoundation
import Speech

/// Fully on-device analysis: SpeechTranscriber (macOS 26+) for the transcript,
/// FoundationModels for summary/actions/email (Task 10). No API key; audio
/// never leaves the machine. Limitation (per spec): no speaker diarization —
/// segments are attributed to "Speaker".
@available(macOS 26.0, *)
final class AppleAnalysisEngine: AnalysisEngine {
    let id = "apple"
    let modelName = "apple-on-device"

    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse {
        progress("Transcribing on device…")
        let transcript = try await Self.transcribe(url: audioURL, progress: progress)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalysisError(message: "No speech was detected in the recording.")
        }
        // Task 10 replaces this stub with FoundationModels summarization.
        throw AnalysisError(message: "On-device summarization not implemented yet.")
    }

    // MARK: - Transcription

    static func transcribe(url: URL,
                           progress: @escaping (String) -> Void) async throws -> String {
        let locale = try await pickLocale()
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])

        // One-time locale model download into system storage.
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            progress("Downloading on-device speech model…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            // nil request means assets are already installed — treat as success.
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Consume results while the file is analyzed.
        async let collected: String = transcriber.results.reduce(into: "") { acc, result in
            acc += String(result.text.characters)
            acc += "\n"
        }

        let audioFile = try AVAudioFile(forReading: url)
        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await collected
    }

    /// Current locale if the transcriber supports it, else en_US, else error.
    private static func pickLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let match = supported.first(where: {
            $0.identifier(.bcp47) == current.identifier(.bcp47)
        }) { return match }
        if let english = supported.first(where: { $0.identifier(.bcp47) == "en-US" }) {
            return english
        }
        throw AnalysisError(message:
            "On-device transcription doesn't support this language. Switch the analysis engine to Gemini in Settings.")
    }

    // MARK: - Segmentation (no diarization — group into readable turns)

    static func transcriptSegments(from text: String) -> [TranscriptSegment] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var segments: [TranscriptSegment] = []
        var current = ""
        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : current + " " + paragraph
            if candidate.count <= 500 {
                current = candidate
            } else {
                if !current.isEmpty {
                    segments.append(TranscriptSegment(speaker: "Speaker", text: current))
                }
                current = paragraph
            }
        }
        if !current.isEmpty {
            segments.append(TranscriptSegment(speaker: "Speaker", text: current))
        }
        return segments
    }
}
```

- [ ] **Step 2: Build gate**

Run: `xcodegen generate && xcodebuild -project EchoScribe.xcodeproj -scheme EchoScribe -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`. If `reduce` on `transcriber.results` fails to infer types, replace the `async let collected` block with an explicit loop inside a `Task { ... }` variable of type `Task<String, Error>`:

```swift
        let collector = Task<String, Error> {
            var acc = ""
            for try await result in transcriber.results {
                acc += String(result.text.characters)
                acc += "\n"
            }
            return acc
        }
```

and `return try await collector.value` at the end (start the Task BEFORE `analyzeSequence`).

- [ ] **Step 3: Commit**

```bash
git add macos-native/AppleAnalysisEngine.swift
git commit -m "Add AppleAnalysisEngine transcription via SpeechTranscriber"
```

---

### Task 10: AppleAnalysisEngine — FoundationModels summarization

**Files:**
- Modify: `macos-native/AppleAnalysisEngine.swift`
- Modify: `macos-native/project.yml` (add `AppleAnalysisEngine.swift` to test-target sources)
- Test: `macos-native/Tests/AppleEngineIntegrationTests.swift`

**Interfaces:**
- Produces: `@Generable struct MeetingNotes` (summary, sentiment, actionItems, emailSubject, emailBody); `static func summarize(transcript:title:participants:progress:) async throws -> MeetingNotes`; completed `analyze(...)` returning a full `MeetingAnalysisResponse`.

- [ ] **Step 1: Write the (skippable) integration test**

Create `macos-native/Tests/AppleEngineIntegrationTests.swift`:

```swift
import XCTest
import FoundationModels

final class AppleEngineIntegrationTests: XCTestCase {
    /// Real on-device model — skipped on machines without Apple Intelligence.
    func testSummarizeShortTranscriptProducesNotes() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26+") }
        try XCTSkipUnless(SystemLanguageModel.default.isAvailable,
                          "Apple Intelligence not available on this machine")

        let transcript = """
        We agreed the release ships Friday. Bob will write the release notes.
        Alice will confirm the pricing page copy with marketing by Wednesday.
        """
        let notes = try await AppleAnalysisEngine.summarize(
            transcript: transcript, title: "Release sync",
            participants: ["Alice", "Bob"], progress: { _ in })

        XCTAssertFalse(notes.summary.isEmpty)
        XCTAssertFalse(notes.actionItems.isEmpty)
        XCTAssertFalse(notes.emailSubject.isEmpty)
        XCTAssertFalse(notes.emailBody.isEmpty)
    }
}
```

- [ ] **Step 2: Regenerate + verify failure** (`summarize` not defined). Add `AppleAnalysisEngine.swift` to the test-target sources in `project.yml` first (same pattern as Task 1 Step 2 — the test target list becomes: `Tests`, `GeminiClient.swift`, `MeetingStore.swift`, `AnalysisEngine.swift`, `TranscriptChunker.swift`, `AppleAnalysisEngine.swift`).

- [ ] **Step 3: Implement summarization + complete analyze()**

In `AppleAnalysisEngine.swift`, add `import FoundationModels` under the existing imports. Replace the stub `analyze` body's last line (`throw AnalysisError(...)`) with:

```swift
        progress("Summarizing on device…")
        let notes = try await Self.summarize(transcript: transcript, title: title,
                                             participants: participants, progress: progress)
        return MeetingAnalysisResponse(
            transcript: Self.transcriptSegments(from: transcript),
            summary: notes.summary,
            sentiment: notes.sentiment,
            actionItems: notes.actionItems,
            followUpEmail: FollowUpEmail(subject: notes.emailSubject, body: notes.emailBody)
        )
```

Then add at the bottom of the class (before the segmentation mark):

```swift
    // MARK: - Summarization (FoundationModels, TN3193 map-reduce)

    @Generable
    struct MeetingNotes {
        @Guide(description: "Executive summary of the meeting, 3-6 sentences, leading with the major takeaways")
        var summary: String
        @Guide(description: "Overall meeting mood as one lowercase word, e.g. collaborative, urgent, alignment, brainstorm")
        var sentiment: String
        @Guide(description: "Every action item, each starting with the owner's name when one is identifiable")
        var actionItems: [String]
        @Guide(description: "Compelling subject line for a professional follow-up email")
        var emailSubject: String
        @Guide(description: "Body of a professional follow-up email synthesizing the discussion, gratitude, and next steps")
        var emailBody: String
    }

    static func summarize(transcript: String, title: String, participants: [String],
                          progress: @escaping (String) -> Void) async throws -> MeetingNotes {
        guard SystemLanguageModel.default.isAvailable else {
            throw AnalysisError(message:
                "Apple Intelligence isn't available. Enable it in System Settings, or switch the analysis engine to Gemini.")
        }
        // Spec §6: on context-window overflow, retry once at a smaller budget.
        do {
            return try await summarizePass(transcript: transcript, title: title,
                                           participants: participants, budget: 2500,
                                           progress: progress)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            progress("Transcript too dense — retrying with smaller segments…")
            return try await summarizePass(transcript: transcript, title: title,
                                           participants: participants, budget: 1200,
                                           progress: progress)
        }
    }

    private static func summarizePass(transcript: String, title: String,
                                      participants: [String], budget: Int,
                                      progress: @escaping (String) -> Void) async throws -> MeetingNotes {
        let who = participants.isEmpty ? "unknown" : participants.joined(separator: ", ")
        // 2,500-token chunks leave headroom for instructions + output in the
        // 4,096-token on-device window (TN3193); the overflow retry halves that.
        let chunker = TranscriptChunker(counter: EstimatedTokenCounter(), budget: budget)
        let chunks = chunker.chunk(transcript)

        // Map: per-chunk notes in fresh sessions.
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if chunks.count > 1 {
                progress("Summarizing part \(index + 1)/\(chunks.count) on device…")
            }
            let session = LanguageModelSession(instructions:
                "You summarize one segment of a meeting transcript. Preserve decisions, owners, deadlines, action items, and the mood. Be concise.")
            let response = try await session.respond(to:
                "Meeting: \(title)\nParticipants: \(who)\n\nTranscript segment:\n\(chunk)")
            partials.append(response.content)
        }

        // Reduce: final structured notes.
        progress("Compiling meeting notes on device…")
        let reduceSession = LanguageModelSession(instructions:
            "You write final meeting notes from segment summaries of a single meeting. Attribute action items to participants when possible.")
        let combined = partials.joined(separator: "\n---\n")
        let final = try await reduceSession.respond(
            to: "Meeting: \(title)\nParticipants: \(who)\n\nSegment notes:\n\(combined)",
            generating: MeetingNotes.self)
        return final.content
    }
```

Note: if the guardrails or context window throw, the error propagates to the UI's error card via `runAnalysis`'s catch — `LanguageModelSession.GenerationError` descriptions are user-readable. No retry logic (YAGNI).

- [ ] **Step 4: Run the full suite**

Run: `xcodegen generate && xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe 2>&1 | grep -E "Test Suite|Test Case.*(passed|failed|skipped)|TEST"`
Expected: all prior suites pass; `AppleEngineIntegrationTests` passes on this machine (Apple Intelligence available) — it may take ~10-60s. `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macos-native/AppleAnalysisEngine.swift macos-native/Tests/AppleEngineIntegrationTests.swift macos-native/project.yml
git commit -m "Complete AppleAnalysisEngine: chunked FoundationModels summarization"
```

---

### Task 11: Wire the Apple engine into the UI — Phase 2 checkpoint

**Files:**
- Modify: `macos-native/ContentView.swift`

**Interfaces:**
- Consumes: `AppleAnalysisEngine` (Task 10), `resolveEngine` (Task 3), `enginePreferenceRaw`/`appleEngineAvailable` (Task 5).

- [ ] **Step 1: Real availability + engine instantiation**

Add `import FoundationModels` at the top of `ContentView.swift` (under `import SwiftUI`). Replace:

```swift
    private var appleEngineAvailable: Bool { false }   // Phase 2 replaces this
```

with:

```swift
    private var appleEngineAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }
```

In `runAnalysis(on:)`, replace the `.apple` case stub:

```swift
        case .apple:
            // Phase 2 instantiates AppleAnalysisEngine here.
            analysisError = "On-device analysis isn't wired up yet."
            stepState = "Idle"
            return
```

with:

```swift
        case .apple:
            guard #available(macOS 26.0, *) else {
                analysisError = "On-device analysis requires macOS 26 or newer."
                stepState = "Idle"
                return
            }
            engine = AppleAnalysisEngine()
```

- [ ] **Step 2: Engine picker in Settings**

In the Settings modal, directly ABOVE the "Gemini API Key" `VStack`, insert a sibling section:

```swift
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Analysis Engine")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))

                            Picker("", selection: $enginePreferenceRaw) {
                                Text("Auto — on-device when available").tag("auto")
                                Text("Apple on-device (private, no key)").tag("apple")
                                Text("Gemini cloud (best quality, speaker names)").tag("gemini")
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderDark, lineWidth: 1))
                        }
```

- [ ] **Step 3: Relabel Gemini as optional**

Replace the Settings description text:

```swift
                        Text("Configure your private Gemini API Key to enable raw meeting transcription, dialogue speaker attribution, summaries, and action item compiling.")
```

with:

```swift
                        Text("Analysis can run fully on-device with Apple Intelligence — no key needed. A Gemini API key is optional: the Gemini engine adds speaker attribution and higher-polish summaries.")
```

and the field label `Text("Gemini API Key")` with `Text("Gemini API Key (optional)")`.

- [ ] **Step 4: Update hardcoded Processing steps + empty-state copy**

(a) In the Processing view, replace the four hardcoded `StepItem(...)` lines with a single dynamic list bound to the live progress text:

```swift
                                    VStack(alignment: .leading, spacing: 14) {
                                        StepItem(title: "Compiling raw audio stream...", active: true, done: true, colors: [successColor, accentPurple])
                                        StepItem(title: progressText.isEmpty ? "Analyzing..." : progressText, active: true, done: false, colors: [accentPurple, accentCyan])
                                    }
```

(b) In the empty state, replace the paragraph beginning `Text("Configure your API Key, list the meeting participants,` with:

```swift
                                    Text("List the participants and press the microphone to record. Analysis runs on-device with Apple Intelligence, or through Gemini when configured — transcripts, summaries, action items, and a follow-up email draft.")
```

- [ ] **Step 5: Full gate — tests + build + manual checkpoint**

Run both gates (test + build). Expected: all suites pass, `** BUILD SUCCEEDED **`.
Manual (human): with engine = Auto and no API key, record 10s of speech → on-device analysis completes end-to-end; history row shows "On-device" badge; switch engine to Gemini → Re-analyze the same meeting → badge flips to "Gemini" with speaker-attributed transcript.

- [ ] **Step 6: Commit**

```bash
git add macos-native/ContentView.swift
git commit -m "Wire Apple on-device engine: auto resolution, engine picker (Phase 2 done)"
```
