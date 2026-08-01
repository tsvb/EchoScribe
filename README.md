# 🎙️ EchoScribe — Meeting Assistant

EchoScribe records meetings and turns them into speaker-aware transcripts, executive
summaries, action-item checklists, and follow-up email drafts. The repository contains
two implementations:

| App | Where | Status |
|---|---|---|
| **macOS native app** (primary) | [`macos-native/`](macos-native/) | Actively developed — persistent meeting history, on-device analysis |
| **Web app** (legacy companion) | [`public/`](public/) + [`server.js`](server.js) | Prototype; working — uses current Gemini models (default `gemini-3.5-flash`) |

## macOS app (start here)

A SwiftUI app with persistent meeting history and a pluggable analysis engine:

- **Apple on-device engine** *(default on macOS 26+ with Apple Intelligence)* —
  transcription via `SpeechTranscriber` and summarization via Apple's FoundationModels.
  **No API key, no cost, and your audio never leaves the Mac.**
- **Gemini engine** *(optional)* — uploads audio to Google's Gemini API for the highest
  quality output plus per-speaker dialogue attribution. Needs an
  [AI Studio](https://aistudio.google.com/apikey) key (current keys start with `AQ.`).
- Every recording is saved **before** analysis runs, so a failed or skipped analysis
  never loses audio. Past meetings can be reopened, played back, renamed, re-analyzed
  (with whichever engine is currently selected), or deleted.

Build/run/test instructions: [`macos-native/README.md`](macos-native/README.md).

## Web app

A single-page prototype (vanilla HTML/CSS/JS + a tiny Express static server). Audio is
captured in the browser and sent **directly from your browser to Google's Gemini API**
with your key — no third-party server is involved, and the key is stored only in your
browser's localStorage. It is *not* fully local: audio and key go to Google for
analysis. For fully on-device analysis, use the macOS app.

```bash
npm install
npm start          # serves http://localhost:3000 and opens your browser
```

Then open **Settings** (gear icon), paste a Gemini API key, add participants, and
record. The model picker lists the current Gemini generation — `gemini-3.5-flash`
(default), `gemini-3.1-flash-lite`, and `gemini-3.1-pro-preview` — and a previously
stored retired model is automatically reset to the default so analysis keeps working.

## Repository layout

```
macos-native/     SwiftUI app (XcodeGen project — see its README)
public/           Web app static assets (index.html, app.js, styles)
server.js         Express static server for the web app
docs/superpowers/ Dated design specs and implementation plans (historical records)
```

## License

Open source under the MIT License.
