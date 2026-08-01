# 🎙️ EchoScribe — macOS Native App

The native Swift & SwiftUI implementation of the **EchoScribe Meeting Assistant**.
It records meeting audio, analyzes it with a pluggable engine, keeps a persistent
history of every meeting, and can push action items into Apple Reminders.

**Analysis engines** (Settings → Analysis Engine, default **Auto**):

- **Apple on-device** — `SpeechTranscriber` transcription + FoundationModels
  summarization (macOS 26+ with Apple Intelligence enabled). No API key, free,
  and audio never leaves the Mac. Long transcripts are summarized with chunked
  map-reduce (Apple TN3193). No speaker diarization — transcript turns are
  unattributed.
- **Gemini** *(optional)* — uploads audio to Google's Gemini API. Best-quality
  output plus per-speaker dialogue attribution. Needs an
  [AI Studio](https://aistudio.google.com/apikey) key — current keys start with
  `AQ.` (legacy `AIza` keys stop working Sept 2026). Live model IDs are kept in
  `ContentView.availableModels` (default `gemini-3.5-flash`). The key is stored
  in the macOS login Keychain, migrated automatically from the old UserDefaults
  location on first launch.
- **Auto** picks Apple when available, else Gemini when a key is set, else shows
  an actionable error. **Recording never requires a key.**

**Meeting history:** every recording is saved the moment you stop — *before* any
analysis — to `~/Library/Application Support/EchoScribe/` (a `meetings.json` index
plus one `.m4a` per meeting). The left-panel list reopens past meetings with their
full results; right-click a row to rename, re-analyze (with the currently selected
engine — e.g. upgrade an on-device meeting to Gemini for speaker names), or delete.
Playback runs from the detail header. A failed analysis leaves the meeting saved as
"Not analyzed".

The Xcode project is **generated from [`project.yml`](project.yml)** with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so it's reproducible and never
drifts out of git. The `.xcodeproj` itself is intentionally git-ignored.

---

## 🚀 Build & Run

### 1. One-time prerequisites
- **Xcode** (from the Mac App Store).
- **XcodeGen**: `brew install xcodegen`

### 2. Generate the project and run
```bash
cd macos-native
xcodegen generate          # creates EchoScribe.xcodeproj from project.yml
open EchoScribe.xcodeproj   # then press ⌘R in Xcode
```

Re-run `xcodegen generate` any time you add/rename a Swift file or change build
settings in `project.yml`.

### 3. Build & test from the command line
```bash
# Run the full unit-test suite (must end ** TEST SUCCEEDED **):
xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe

# Compile-only check (no signing needed):
xcodebuild -project EchoScribe.xcodeproj -scheme EchoScribe -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```
In Xcode, a team-less build is signed "to run locally" automatically, which is all
you need for local testing (TCC permissions key off the local signature).

---

## 🔐 Permissions & first run

Privacy usage strings are declared in `project.yml` and injected into the generated
`Info.plist`, so the app won't crash when it touches these APIs:

| Capability | Info.plist key | Why |
|---|---|---|
| Microphone | `NSMicrophoneUsageDescription` | `AudioRecorderManager` records via `AVAudioRecorder` |
| Reminders (full access) | `NSRemindersFullAccessUsageDescription` | `EventKitManager` calls `requestFullAccessToReminders` on macOS 14+ |

On first launch macOS will prompt for **Microphone** and **Reminders** access.
To re-test those prompts later:
```bash
tccutil reset Microphone com.echoscribe.EchoScribe
tccutil reset Reminders  com.echoscribe.EchoScribe
```

On-device transcription (the macOS 26 `SpeechTranscriber` API) needs no extra
Speech-recognition permission; its language model downloads into system storage on
first use. On-device summarization requires **Apple Intelligence** to be enabled in
System Settings — without it, the app falls back to Gemini (with a key) or explains
what's missing.

---

## 📦 Distribution note

For local development, **App Sandbox** and **Hardened Runtime** are OFF (see the
comments in `project.yml`) so permissions come straight from the normal TCC prompts.
Before distributing (App Store / notarization), re-enable them and add the matching
entitlements — at minimum `com.apple.security.app-sandbox`,
`com.apple.security.device.audio-input`, and `com.apple.security.network.client`.

---

## 🗂 Source files

- `EchoScribeApp.swift` — `@main` app, window, menu-bar item
- `ContentView.swift` — main UI: recorder, history list, results workspace, Settings
- `MeetingStore.swift` — persistent meeting history (atomic JSON index + audio files)
- `AnalysisEngine.swift` — engine protocol, `GeminiEngine` adapter, Auto resolution
- `AppleAnalysisEngine.swift` — on-device transcription + summarization (macOS 26+)
- `TranscriptChunker.swift` — token-budget chunking for the on-device model window
- `RetryPolicy.swift` — budgeted retry helper (context-window overflow fallback)
- `KeychainStore.swift` — Keychain storage for the Gemini API key
- `AudioRecorderManager.swift` — recording + level metering (`AudioLevelMonitor`)
- `AudioPlaybackManager.swift` — playback of stored meeting audio
- `GeminiClient.swift` — Gemini request/response + user-facing API error mapping
- `EventKitManager.swift` — Reminders integration
- `Tests/` — unit tests (store, resolver, chunker, segmentation, error mapping,
  retry policy, Keychain storage) plus a FoundationModels integration test that runs
  when Apple Intelligence is available
