# EchoScribe — macOS Native App

This is the engineering doc for the native app. For the product overview and
engine comparison, see the [root README](../README.md); just want the app?
Download the signed DMG from
[Releases](https://github.com/tsvb/EchoScribe/releases/latest).

EchoScribe is a SwiftUI meeting recorder/transcriber/summarizer with a
pluggable analysis engine (`AnalysisEngine` protocol) and persistent meeting
history. Engine-selection behavior, the feature list, and the privacy story are
covered in the root README; the specifics that matter for working on this code:

- **Apple on-device engine** (`AppleAnalysisEngine`, macOS 26+ behind
  `@available` guards) — `SpeechTranscriber` transcription + FoundationModels
  summarization. Long transcripts are summarized with chunked map-reduce per
  Apple TN3193 (`TranscriptChunker` + `RetryPolicy` for context-window
  overflow fallback).
- **Gemini engine** (`GeminiEngine`) — audio upload to Google's Gemini API.
  Live model IDs are kept in the **`CloudProviders.gemini`** registry row in
  `AnalysisEngine.swift` (default `gemini-3.5-flash`) — that registry is the
  source of truth when Google retires model IDs; stored ids heal back to the
  default on load. The API key lives in the macOS login Keychain
  (`KeychainStore.geminiAPIKey`), migrated automatically from the old
  UserDefaults location on first launch.
- **OpenAI engine** (`OpenAIEngine` + `OpenAIClient`) — two-step cloud
  pipeline: diarized transcription (`gpt-4o-transcribe-diarize`,
  `diarized_json`, 25 MB upload cap) followed by a structured
  chat-completion analysis (default `gpt-5.6-terra`; models live in the
  `CloudProviders.openai` registry row). The key lives in the Keychain
  (`KeychainStore.openaiAPIKey`).
- **Recording never requires a key.** Every recording is saved the moment you
  stop — *before* any analysis — to
  `~/Library/Application Support/EchoScribe/` (a `meetings.json` index plus one
  `.m4a` per meeting), so a failed or skipped analysis never loses audio.

The Xcode project is **generated from [`project.yml`](project.yml)** with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so it's reproducible and never
drifts out of git. The `.xcodeproj` itself is intentionally git-ignored.

---

## Build & Run

**Version support:** the deployment target is **macOS 14** (set in
`project.yml`). The on-device analysis path is compiled behind
`@available(macOS 26, *)` guards, so contributors on macOS 14–15 can build,
run, and test everything except live Apple-engine runs — the FoundationModels
integration test self-skips when Apple Intelligence is unavailable.

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

**Adding tests:** new test files under `Tests/` are picked up automatically.
But the test bundle compiles production sources directly (there is no
TEST_HOST), so any *production* file a test exercises must **also** be listed
in the `EchoScribeTests` target's `sources` in `project.yml` — then re-run
`xcodegen generate`.

---

## Permissions & first run

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
System Settings — without it, the app falls back to a configured cloud engine
(Gemini or OpenAI, with a key) or explains what's missing.

---

## Releasing

[`scripts/release.sh`](scripts/release.sh) (run from `macos-native/` as
`scripts/release.sh`) produces a signed, notarized, stapled
`EchoScribe-<version>.dmg` plus a stapled `EchoScribe.app` ready for
`/Applications`. It notarizes and staples the **app first**, then packages,
signs, notarizes, and staples the **DMG** (two round-trips), so both the
download and a first offline launch are Gatekeeper-clean.

- **Hardened Runtime** is applied at signing time with
  [`Packaging/EchoScribe.entitlements`](Packaging/EchoScribe.entitlements)
  (mic + Reminders access). Local dev builds stay un-hardened (see
  `project.yml` comments).
- **App Sandbox stays off**, deliberately: sandboxing would relocate
  `~/Library/Application Support/EchoScribe` into a container and hide
  existing meeting history. Notarization does not require it.
- Prerequisites (one-time): a "Developer ID Application" certificate in the
  login keychain and a notarytool keychain profile
  (`xcrun notarytool store-credentials`). The defaults baked into the script
  (`DEVELOPER_ID_APP` identity, `NOTARY_PROFILE` name) are the maintainer's
  machine defaults — contributors must override both via those env vars.
- Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` before
  cutting a release.
- Finished DMGs are published to
  [GitHub Releases](https://github.com/tsvb/EchoScribe/releases/latest)
  (v1.0 is out). Built artifacts (`build/`, `*.dmg`) are git-ignored, so
  release binaries live only on the Releases page — never in the repo.

The app icon is generated — regenerate
`Assets.xcassets/AppIcon.appiconset` with `swift Packaging/IconGen.swift`
after editing `Packaging/IconGen.swift`.

---

## Source files

- `EchoScribeApp.swift` — `@main` app, window, menu-bar item
- `ContentView.swift` — main UI: recorder, history list, results workspace, Settings
- `MeetingStore.swift` — persistent meeting history (atomic JSON index + audio files)
- `AnalysisEngine.swift` — engine protocol, `GeminiEngine` adapter, Auto
  resolution, and the `CloudProviders` registry (cloud model lists, picker
  rows, key fields, stored-model healing)
- `AppleAnalysisEngine.swift` — on-device transcription + summarization (macOS 26+)
- `TranscriptChunker.swift` — token-budget chunking for the on-device model window
- `RetryPolicy.swift` — budgeted retry helper (context-window overflow fallback)
- `KeychainStore.swift` — Keychain storage for the cloud API keys (Gemini, OpenAI)
- `AudioRecorderManager.swift` — recording + level metering (`AudioLevelMonitor`)
- `AudioPlaybackManager.swift` — playback of stored meeting audio
- `GeminiClient.swift` — Gemini request/response + user-facing API error mapping
- `OpenAIClient.swift` — stateless OpenAI request builders/decoders + user-facing
  API error mapping
- `OpenAIEngine.swift` — two-step OpenAI pipeline (diarized transcription, then
  structured chat analysis)
- `EventKitManager.swift` — Reminders integration
- `Tests/` — unit tests (store, resolver, provider catalog, chunker, segmentation,
  Gemini and OpenAI error mapping, OpenAI request builders and transcript mapping,
  retry policy, Keychain storage) plus a FoundationModels integration test that runs
  when Apple Intelligence is available
