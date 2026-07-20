# 🎙️ EchoScribe — macOS Native App

The native Swift & SwiftUI implementation of the **EchoScribe Meeting Assistant**.
It records meeting audio, sends it to Gemini for transcription/summary/action items,
and can push those action items into Apple Reminders.

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

### 3. (Optional) Build from the command line
```bash
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

**Gemini API key:** open the in-app **Settings** (gear) and paste your key. Recording
works without it, but "Stop & Analyze" needs it.

> `SpeechTranscriptionManager` (Apple `Speech` framework) is present but not currently
> wired into the flow, so no Speech-recognition permission is requested. If you hook it
> up, add `NSSpeechRecognitionUsageDescription` to `project.yml`.

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
- `ContentView.swift` — main UI + `AudioLevelVisualizer`
- `AudioRecorderManager.swift` — recording + level metering (`AudioLevelMonitor`)
- `SpeechTranscriptionManager.swift` — on-device Speech transcription (unused for now)
- `GeminiClient.swift` — Gemini request/response
- `EventKitManager.swift` — Reminders integration
