# CLAUDE.md

Guidance for AI coding agents working in this repository.

## What this repo is

EchoScribe, a meeting recorder/transcriber/summarizer. Two apps:

- **`macos-native/` — primary.** SwiftUI, deployment target macOS 14, but the
  on-device analysis path uses macOS 26+ APIs behind `@available` guards.
- **`public/` + `server.js` — legacy web prototype.** Browser recording + direct
  Gemini calls. Lower priority; its model picker is known-stale.

## Build & test (macos-native)

The Xcode project is **generated** — never commit `EchoScribe.xcodeproj`
(git-ignored). `project.yml` is the source of truth; regenerate after adding,
renaming, or deleting any Swift file:

```bash
cd macos-native
xcodegen generate
xcodebuild test -project EchoScribe.xcodeproj -scheme EchoScribe          # 31 tests
xcodebuild -project EchoScribe.xcodeproj -scheme EchoScribe \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO                      # compile check
```

New test files under `macos-native/Tests/` are picked up automatically; new
production files must ALSO be listed explicitly in the `EchoScribeTests` target's
`sources` in `project.yml` if tests need them (the test bundle compiles sources
directly — no TEST_HOST).

**Ignore per-file editor/SourceKit diagnostics** ("Cannot find X in scope",
"No such module XCTest") — files are analyzed in isolation; only `xcodebuild`
results count.

## Architecture (macos-native)

- `MeetingStore` — single source of truth. Persistent history in
  `~/Library/Application Support/EchoScribe/` (`meetings.json` + one `.m4a` per
  meeting). All mutations save atomically and roll back on failed index writes.
  **Audio files are deleted only inside `MeetingStore.delete(id:)`.**
- `AnalysisEngine` protocol — `AppleAnalysisEngine` (on-device: `SpeechTranscriber`
  + FoundationModels chunked map-reduce, macOS 26+) and `GeminiEngine` (audio upload).
  `resolveEngine(preference:context:)` is pure and unit-tested; preference lives in
  `@AppStorage("analysis_engine")` (`auto`/`apple`/`gemini`).
- Recording is never gated on an API key; recordings are saved to the store on stop,
  BEFORE analysis. UI renders the selected meeting's stored analysis — never a
  client's in-memory result.
- Design/plan history: `docs/superpowers/` (dated records — don't treat as living docs).

## Gemini API facts (verified 2026-07; do not "correct" these backwards)

- Current API keys start with **`AQ.`** (AI Studio only issues these now; legacy
  `AIza` keys die Sept 2026). Never tell users to get an `AIza` key.
- Live models are listed in `ContentView.availableModels` (default
  `gemini-3.5-flash`). `gemini-1.5-*` and `gemini-2.0-*` are retired and 404.
  Google churns model IDs ~yearly — on a "model not available" bug, check
  ai.google.dev/gemini-api/docs/deprecations before debugging app code.
- Key goes in the `x-goog-api-key` header, not the URL. Error envelope parsing
  lives in `GeminiClient.userFacingError` (unit-tested).

## Conventions

- Follow existing code style; plain `ObservableObject` managers, no external
  dependencies.
- Keep high-frequency UI updates (audio metering, playback ticks) scoped to small
  observer subviews (see `AudioLevelVisualizer`) rather than `@Published` state
  observed by all of `ContentView`.
- Run both xcodebuild gates before claiming any change works.
