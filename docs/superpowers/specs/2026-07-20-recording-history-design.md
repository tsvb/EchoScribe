# Recording History & Session Management — Design

**Date:** 2026-07-20
**Scope:** macOS native app (`macos-native/`)
**Status:** Approved

## Problem

Every recording writes to the same fixed path (`~/Documents/EchoScribe_Record.m4a`), so
each new recording destroys the previous one. Analysis results exist only in memory
(`gemini.result`) and are lost when the app quits. There is no way to start a new
meeting without discarding the last, and no way to revisit past meetings.

## Goals

- Every recording and its Gemini analysis persist across app launches.
- A history list shows past meetings; opening one restores its full results workspace.
- Saved meetings support: open, rename, re-analyze, play audio, delete.
- Audio is saved the moment recording stops — before analysis — so a failed Gemini call
  never loses a recording.
- A "New Meeting" action returns the workspace to a record-ready state.

## Non-goals (YAGNI)

- Migrating the single legacy `~/Documents/EchoScribe_Record.m4a` file.
- Search/filtering, iCloud sync, waveform scrubbing, audio export.
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
    var model: String?                          // model that produced the analysis
    var analysis: MeetingAnalysisResponse?      // nil = "not analyzed yet"
    var audioFileName: String                   // "<id>.m4a", relative to store dir
}
```

`MeetingStore: ObservableObject`

- Storage root: `~/Library/Application Support/EchoScribe/` — injectable
  (`init(directory: URL)`) so tests can point at a temp dir.
- Layout: `meetings.json` (index, array of `Meeting`, newest first) + one
  `<UUID>.m4a` per meeting alongside it.
- API:
  - `@Published private(set) var meetings: [Meeting]`
  - `@Published var lastError: String?`
  - `create(audioAt tempURL: URL, title: String, participants: [String], duration: TimeInterval) -> Meeting?`
    — moves (not copies) the audio into the store, prepends the record, saves.
  - `updateAnalysis(id: UUID, analysis: MeetingAnalysisResponse, model: String)`
  - `rename(id: UUID, to: String)`
  - `delete(id: UUID)` — removes the index entry and its audio file.
  - `audioURL(for: Meeting) -> URL`
- Index writes are atomic (`Data.write(options: .atomic)`) after every mutation.
- Corrupted index on load: rename to `meetings.json.bak`, start with an empty list,
  set `lastError`. Audio files are never deleted except by explicit `delete`.
- `MeetingAnalysisResponse` is already `Codable` (defined in `GeminiClient.swift`), so
  analysis persistence needs no new encoding work. `TranscriptSegment.id` is excluded
  from coding keys (stored `let id = UUID()`), which is compatible.

### 2. Recording flow

- `AudioRecorderManager.startRecording()` records to a unique temp file
  (`FileManager.temporaryDirectory/<UUID>.m4a`) instead of the fixed Documents path.
  This kills the overwrite behavior at the source.
- `ContentView.stopAndAnalyze()`:
  1. Stop recording → get temp audio URL + duration.
  2. `store.create(...)` with the current meeting title and participants — the audio
     is now durable, shown in history as "Not analyzed".
  3. Select the new meeting; run the Gemini call on the stored audio (off-main read,
     as today).
  4. On success → `store.updateAnalysis(...)`; the workspace shows results.
     On failure → existing error card; the meeting stays saved, Re-analyze available.

### 3. UI

Left panel (below participants):

- Section header **"Previous Meetings (N)"** with a **New Meeting** button.
- Scrollable list rows: title (one line), caption `date · duration`, status dot
  (analyzed / not analyzed), selected highlight.
- Row interactions: click = open; context menu = Rename / Re-analyze / Delete.
  Rename swaps the row title for an inline `TextField` (commit on Return).

Right workspace:

- When a meeting is open: compact header above the existing tabs — meeting title,
  date, **Play/Pause + elapsed** (new `AudioPlaybackManager: ObservableObject`
  wrapping `AVAudioPlayer`), **Re-analyze** button. Existing tab views unchanged.
- Empty state and error card unchanged.

### 4. State flow — single source of truth

- `ContentView` gains `@StateObject store: MeetingStore` and
  `@State selectedMeetingID: UUID?`.
- The workspace renders the **selected meeting's stored analysis** — never
  `gemini.result` directly. Live results are written into the store first, so
  "just analyzed" and "opened from history" share one rendering path.
- Existing actions (sync Reminders, copy email, open Mail) read from the selected
  meeting's analysis.
- New Meeting: clears selection (and stops playback); workspace returns to the
  record-ready empty state.
- Deleting the selected meeting clears the selection.
- Re-analyze is disabled while `gemini.isProcessing`.
- Missing audio file (removed outside the app): Play and Re-analyze surface an
  error; the stored analysis remains viewable.

### 5. Error handling

- Store mutations set `store.lastError` on failure (disk full, move failed…).
- The right-panel error card shows `gemini.error ?? store.lastError`.
- Recording-stop with no URL (already handled) leaves state Idle.

### 6. Testing

`MeetingStoreTests` in the existing `EchoScribeTests` bundle (store pointed at a
fresh temp directory per test):

- create → reload roundtrip (new store instance reads the same directory).
- create moves the audio file (source gone, destination exists).
- `updateAnalysis` persists across reload.
- `rename` persists; `delete` removes both index entry and audio file.
- Corrupted `meetings.json` → `.bak` created, empty list, `lastError` set.

`MeetingStore.swift` is added to the test target sources (alongside
`GeminiClient.swift`, which provides `MeetingAnalysisResponse`). Existing 7
error-mapping tests stay green; full app build must succeed.

## Decisions log

- Storage: **JSON index + files** chosen over SwiftData (too heavy for this app) and
  folder-per-meeting (close second; revisit if per-meeting share/backup matters).
- Save timing: **on recording stop**, not after analysis — protects audio from
  API failures (the app just lived through a month of silent model-retirement 404s).
- All four management actions (delete, re-analyze, play, rename) are in scope.
