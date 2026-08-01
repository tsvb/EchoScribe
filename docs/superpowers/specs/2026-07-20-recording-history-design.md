# Recording History & Engine-Agnostic Analysis — Design

**Date:** 2026-07-20 (amended same day: analysis-engine abstraction + Apple on-device engine)
**Scope:** macOS native app (`macos-native/`)
**Status:** Implemented — merged to main 2026-07-20 (amendment included)

## Problem

1. Every recording writes to the same fixed path (`~/Documents/EchoScribe_Record.m4a`),
   so each new recording destroys the previous one. Analysis results exist only in
   memory and are lost on quit. No way to start a new meeting or revisit past ones.
2. The entire app is gated on a Gemini API key (the mic button refuses to record
   without one), and analysis requires uploading meeting audio to Google. On Apple
   Intelligence-capable Macs, Apple's on-device stack (SpeechTranscriber +
   FoundationModels) can transcribe and summarize with no key, no cost, and no audio
   leaving the machine. (Verified available on the target machine: FoundationModels
   `available`, SpeechTranscriber en-US asset installed.)

## Goals

- Every recording and its analysis persist across app launches.
- History list: open, rename, re-analyze, play audio, delete past meetings.
- Audio is saved the moment recording stops — before analysis — so an analysis
  failure never loses a recording.
- "New Meeting" returns the workspace to a record-ready state.
- **Recording is never gated on an API key.**
- **Analysis works with no Gemini key** on Apple Intelligence-capable Macs via an
  on-device engine; Gemini remains an optional engine (best quality + speaker names).
- Re-analyze uses the currently selected engine — record free/local now, re-analyze
  with Gemini later if desired.

## Non-goals (YAGNI)

- Migrating the single legacy `~/Documents/EchoScribe_Record.m4a` file.
- Search/filtering, iCloud sync, waveform scrubbing, audio export.
- Speaker diarization on the Apple path (no Apple API exists; Gemini engine covers
  speaker attribution; FluidAudio integration is a possible future spec).
- PrivateCloudComputeLanguageModel (needs macOS 27 + Apple-approved entitlement) —
  noted as a future engine.
- Web app parity (separate task).

## Design

### 1. Data model & storage (new file: `MeetingStore.swift`)

```swift
struct Meeting: Codable, Identifiable {
    let id: UUID
    var title: String
    let createdAt: Date
    let duration: TimeInterval
    var participants: [String]
    var engine: String?                         // "apple" | "gemini" — produced the analysis
    var model: String?                          // e.g. "gemini-3.5-flash" or "apple-on-device"
    var analysis: MeetingAnalysisResponse?      // nil = "not analyzed yet"
    var audioFileName: String                   // "<id>.m4a", relative to store dir
}
```

`MeetingStore: ObservableObject`

- Storage root: `~/Library/Application Support/EchoScribe/` — injectable
  (`init(directory: URL)`) so tests use a temp dir.
- Layout: `meetings.json` (index, newest first) + one `<UUID>.m4a` per meeting.
- API: `@Published private(set) var meetings`, `@Published var lastError: String?`,
  `create(audioAt:title:participants:duration:) -> Meeting?` (moves audio in, saves),
  `updateAnalysis(id:analysis:engine:model:)`, `rename(id:to:)`, `delete(id:)`
  (removes audio too), `audioURL(for:)`.
- Index writes atomic after every mutation. Corrupted index on load → renamed to
  `meetings.json.bak`, start empty, set `lastError`; audio files are never deleted
  except by explicit `delete`.
- `MeetingAnalysisResponse` is already `Codable`; no new encoding work.

### 2. Analysis engines (new file: `AnalysisEngine.swift`)

```swift
protocol AnalysisEngine {
    var id: String { get }                       // "apple" | "gemini"
    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse
}
```

**GeminiEngine** — adapter over the existing `GeminiClient` call (audio upload,
`x-goog-api-key`, current model picker). Constructed with key + model. Provides
speaker-attributed transcripts. Unchanged behavior otherwise.

**AppleAnalysisEngine** (Phase 2) — fully on-device:

1. *Transcribe:* `SpeechTranscriber` (locale from `Locale.current`, gated on
   `supportedLocales`; `AssetInventory` install with progress on first use) via
   `analyzeSequence(from: AVAudioFile)` + `finalizeAndFinish`. Timestamped
   `AttributedString` → `TranscriptSegment`s grouped into ~paragraph turns,
   `speaker: "Speaker"` (no diarization — documented limitation).
2. *Summarize:* FoundationModels `LanguageModelSession` with `@Generable` output
   struct (summary, sentiment, action items, email subject/body). The on-device
   window is 4,096 tokens, so long transcripts use Apple's prescribed map-reduce
   (TN3193): chunk by token budget (via `tokenCount(for:)`/`contextSize`), fresh
   session per chunk producing segment notes, then a reduce session emits the final
   `@Generable` result. Chunking lives in a pure, unit-testable helper.
3. Progress strings ("Transcribing on device…", "Summarizing part 2/5…") flow to the
   existing Processing view.

**Engine selection** — `@AppStorage("analysis_engine")`: `auto` (default) | `apple` |
`gemini`. Resolution for `auto`: Apple engine if `SystemLanguageModel` is available
AND the transcriber supports the locale; else Gemini if a key is set; else fail with
an error card explaining both options (enable Apple Intelligence, or add a key).
Settings gains an Engine picker; the Gemini key/model section is relabeled optional
("required only for the Gemini engine — adds speaker attribution").

### 3. Recording flow

- `AudioRecorderManager.startRecording()` records to a unique temp file
  (`FileManager.temporaryDirectory/<UUID>.m4a`) — kills the overwrite bug.
- `toggleRecording()` no longer checks for an API key. Recording always works.
- `stopAndAnalyze()`:
  1. Stop → temp audio URL + duration.
  2. `store.create(...)` — audio durable immediately, listed as "Not analyzed".
  3. Select the meeting; resolve engine; run `engine.analyze(...)`.
  4. Success → `store.updateAnalysis(...)`. Failure → error card; meeting stays
     saved with Re-analyze available.

### 4. UI

Left panel (below participants): **"Previous Meetings (N)"** header + **New Meeting**
button; scrollable rows (title, `date · duration` caption, analyzed/not status dot,
engine badge, selection highlight). Row: click = open; context menu = Rename (inline
`TextField`) / Re-analyze / Delete.

Right workspace: compact header when a meeting is open — title, date,
**Play/Pause + elapsed** (new `AudioPlaybackManager` over `AVAudioPlayer`),
**Re-analyze**. Existing tabs unchanged. Empty state + error card unchanged.
Processing view step labels come from engine progress strings instead of the
hardcoded Gemini steps.

### 5. State flow — single source of truth

`ContentView` gains `@StateObject store` + `@State selectedMeetingID`. The workspace
renders the selected meeting's stored analysis — never a client's in-memory result.
Live results are written to the store first; "just analyzed" and "opened from
history" share one rendering path. Reminders/email actions read the selected
meeting. New Meeting clears selection + stops playback. Deleting the selected
meeting clears selection. Re-analyze disabled while an analysis is in flight.
Missing audio file: Play/Re-analyze error; stored analysis still viewable.

### 6. Error handling

- Store mutations set `store.lastError`; error card shows the first of
  (analysis error, store error).
- Apple engine: unavailable model / unsupported locale → clear message naming the
  fallback (add Gemini key or enable Apple Intelligence); context-window overflow →
  automatic re-chunk at smaller budget, then error if still failing; guardrail
  refusals surfaced as "on-device model declined — try Re-analyze or the Gemini
  engine".
- Gemini engine errors unchanged (existing `userFacingError` mapping).

### 7. Testing

Existing `EchoScribeTests` bundle:

- `MeetingStoreTests` (temp dir): create→reload roundtrip; audio moved not copied;
  `updateAnalysis` persists; rename/delete persist (delete removes audio);
  corrupted index → `.bak` + empty + `lastError`.
- `TranscriptChunkerTests`: pure chunker respects token budget, covers whole input,
  no empty chunks (token counting behind a protocol so tests use a fake counter).
- Engine resolution tests: auto → apple/gemini/none matrix (availability behind a
  protocol so tests can simulate ineligible machines).
- Optional integration test for the Apple engine gated with
  `XCTSkipUnless(SystemLanguageModel.default.isAvailable)`.
- Existing 7 error tests stay green; full app build passes.

## Phasing (one implementation plan, two checkpoints)

1. **Phase 1 — History + seam:** `MeetingStore`, history UI, playback,
   rename/delete, un-gated recording, `AnalysisEngine` protocol with `GeminiEngine`
   as the only implementation. App is fully usable; keyless users accumulate
   "Not analyzed" meetings they can re-analyze later.
2. **Phase 2 — Apple engine:** `AppleAnalysisEngine` (transcriber + chunked
   FoundationModels), engine picker + auto resolution, engine badges, progress
   strings. Keyless users get full local analysis.

## Decisions log

- Storage: JSON index + files over SwiftData (too heavy) and folder-per-meeting
  (close second).
- Save timing: on recording stop — protects audio from API failures.
- All four management actions in scope.
- Engine abstraction added (user: don't gate on Gemini). Apple on-device is the
  default via `auto`; Gemini optional for quality + speaker attribution.
- Apple-path caveats accepted: unattributed speakers, 4K-window map-reduce, flatter
  summaries than Gemini (verified against Apple docs/TN3193 + developer reports).
