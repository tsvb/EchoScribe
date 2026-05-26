# 🎙️ EchoScribe — Premium Local Meeting Assistant

EchoScribe is a premium, beautifully designed single-page application (SPA) that acts as a local meeting recorder, transcriber, and summarizer. It records meetings directly from your microphone, processes the audio locally using the Web Audio API, and generates highly accurate speaker-attributed dialogue transcripts, detailed executive summaries, actionable checklist items, and formal follow-up email drafts powered by Gemini 2.0.

---

## ✨ Features

* **Glassmorphic UI Design**: Designed with harmonious dark-mode aesthetics, custom radial glowing background animations, and modern typographic hierarchies.
* **Real-time Web Audio Visualizer**: Captures and routes microphone audio through a Web Audio `AnalyserNode`, drawing a dynamic neon-gradient frequency wave on a canvas.
* **Deterministic Speaker Attribution**: Assigns unique, consistent HSL avatar colors to call participants, mapping dialogues directly to specific speakers.
* **Structured Output Integration**: Leverages Gemini 2.0's official structured JSON schema capability to produce perfectly aligned analytical data (transcripts, checklists, email drafts).
* **Engaging visual stepper**: Walks the user step-by-step through the audio compilation, upload, voice diarization, and synthesis processing states.
* **Local & Private**: Processes everything client-side. Your Gemini API key is stored safely in your browser's local storage and never leaves your computer.

---

## 🛠️ Architecture & Stack

* **Frontend**: Vanilla HTML5, CSS3 (Custom Variables, CSS Grid, Glassmorphic effects, Floating Glows), Vanilla JS.
* **Backend**: Lightweight Node.js Express server to serve static assets and automatically launch the app in the browser.
* **AI Model**: `gemini-2.0-flash` content generation API (structured JSON output schema).

---

## 🚀 Getting Started

### 1. Prerequisites
Ensure you have [Node.js](https://nodejs.org/) installed on your machine.

### 2. Install Dependencies
Clone this repository and install the Express package:
```bash
npm install
```

### 3. Run the App
Start the local server:
```bash
npm start
```
The server will boot up and automatically launch `http://localhost:3000` in your default browser.

### 4. Configuration
1. Open the application in your browser.
2. Click the gear icon (**Settings**) in the top right.
3. Paste your private Gemini API Key (get one free at [Google AI Studio](https://aistudio.google.com/)).
4. Add the names of the meeting participants under the **Meeting Call Team** section.
5. Tap the microphone to record, then click **Stop & Analyze** when done!

---

## 🛡️ License

This project is open-source and available under the MIT License.
