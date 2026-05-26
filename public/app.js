/**
 * EchoScribe - Premium Local Meeting Assistant Core Logic
 */

// Application State
const state = {
  apiKey: localStorage.getItem('gemini_api_key') || '',
  participants: JSON.parse(localStorage.getItem('meeting_participants')) || [],
  isRecording: false,
  isPaused: false,
  mediaRecorder: null,
  audioChunks: [],
  recordingTimerInterval: null,
  secondsElapsed: 0,
  audioContext: null,
  analyser: null,
  dataArray: null,
  animationId: null,
  results: null
};

// DOM Elements
const DOM = {
  meetingTitle: document.getElementById('meeting-title'),
  btnSettingsToggle: document.getElementById('btn-settings-toggle'),
  btnSettingsClose: document.getElementById('btn-settings-close'),
  btnSettingsCancel: document.getElementById('btn-settings-cancel'),
  btnSettingsSave: document.getElementById('btn-settings-save'),
  settingsDialog: document.getElementById('settings-dialog'),
  inputApiKey: document.getElementById('input-api-key'),
  btnToggleKeyVisibility: document.getElementById('btn-toggle-key-visibility'),
  apiStatusBadge: document.getElementById('api-status-badge'),
  apiKeyWarning: document.getElementById('api-key-warning'),
  btnSettingsLink: document.getElementById('btn-settings-link'),
  
  // Recording
  btnRecordPrimary: document.getElementById('btn-record-primary'),
  recordingStatus: document.getElementById('recording-status'),
  recordingTimer: document.getElementById('recording-timer'),
  activeControls: document.getElementById('active-controls'),
  btnRecordPause: document.getElementById('btn-record-pause'),
  btnRecordStop: document.getElementById('btn-record-stop'),
  canvasVisualizer: document.getElementById('canvas-visualizer'),
  
  // Participants
  inputParticipant: document.getElementById('input-participant'),
  btnAddParticipant: document.getElementById('btn-add-participant'),
  participantsList: document.getElementById('participants-list'),
  participantsCount: document.getElementById('participants-count'),
  
  // Workspace States
  stateEmpty: document.getElementById('state-empty'),
  stateProcessing: document.getElementById('state-processing'),
  stateResults: document.getElementById('state-results'),
  
  // Processing steps
  stepAudio: document.getElementById('step-audio'),
  stepUpload: document.getElementById('step-upload'),
  stepDiarization: document.getElementById('step-diarization'),
  stepSynthesis: document.getElementById('step-synthesis'),
  
  // Tabs & Panels
  tabSummary: document.getElementById('tab-summary'),
  tabTranscript: document.getElementById('tab-transcript'),
  tabActions: document.getElementById('tab-actions'),
  tabEmail: document.getElementById('tab-email'),
  panelSummary: document.getElementById('panel-summary'),
  panelTranscript: document.getElementById('panel-transcript'),
  panelActions: document.getElementById('panel-actions'),
  panelEmail: document.getElementById('panel-email'),
  
  // Content viewports
  summaryMeetingName: document.getElementById('summary-meeting-name'),
  summaryMeetingSentiment: document.getElementById('summary-meeting-sentiment'),
  contentSummary: document.getElementById('content-summary'),
  contentTranscript: document.getElementById('content-transcript'),
  contentActions: document.getElementById('content-actions'),
  emailPreviewSubject: document.getElementById('email-preview-subject'),
  emailPreviewBody: document.getElementById('email-preview-body'),
  
  // Clipboard/Share buttons
  btnCopyActions: document.getElementById('btn-copy-actions'),
  btnCopyEmail: document.getElementById('btn-copy-email'),
  linkSendEmail: document.getElementById('link-send-email'),
  
  // Toast
  toast: document.getElementById('notification-toast'),
  toastMessage: document.getElementById('notification-message')
};

// -------------------------------------------------------------
// 1. Initializers & Setup
// -------------------------------------------------------------
function initApp() {
  setupEventListeners();
  updateApiKeyStatus();
  renderParticipants();
  adjustCanvasSize();
  window.addEventListener('resize', adjustCanvasSize);
}

function setupEventListeners() {
  // Settings Dialog Controls
  DOM.btnSettingsToggle.addEventListener('click', openSettings);
  DOM.btnSettingsClose.addEventListener('click', closeSettings);
  DOM.btnSettingsCancel.addEventListener('click', closeSettings);
  DOM.btnSettingsSave.addEventListener('click', saveApiKey);
  DOM.btnSettingsLink.addEventListener('click', openSettings);
  DOM.btnToggleKeyVisibility.addEventListener('click', toggleKeyVisibility);
  
  // Settings click outside to close (light dismiss)
  DOM.settingsDialog.addEventListener('click', (e) => {
    const rect = DOM.settingsDialog.getBoundingClientRect();
    const isInDialog = (
      rect.top <= e.clientY && e.clientY <= rect.top + rect.height &&
      rect.left <= e.clientX && e.clientX <= rect.left + rect.width
    );
    if (!isInDialog) {
      closeSettings();
    }
  });

  // Participant Management
  DOM.btnAddParticipant.addEventListener('click', addParticipantFromInput);
  DOM.inputParticipant.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      addParticipantFromInput();
    }
  });

  // Recording Controls
  DOM.btnRecordPrimary.addEventListener('click', toggleRecordingState);
  DOM.btnRecordPause.addEventListener('click', togglePauseState);
  DOM.btnRecordStop.addEventListener('click', stopRecording);

  // Tab Navigation
  const tabs = [
    { button: DOM.tabSummary, panel: DOM.panelSummary },
    { button: DOM.tabTranscript, panel: DOM.panelTranscript },
    { button: DOM.tabActions, panel: DOM.panelActions },
    { button: DOM.tabEmail, panel: DOM.panelEmail }
  ];

  tabs.forEach(({ button, panel }) => {
    button.addEventListener('click', () => {
      // Deactivate all
      tabs.forEach(t => {
        t.button.classList.remove('active');
        t.button.setAttribute('aria-selected', 'false');
        t.panel.classList.add('hidden');
      });
      // Activate clicked
      button.classList.add('active');
      button.setAttribute('aria-selected', 'true');
      panel.classList.remove('hidden');
    });
  });

  // Action Items Copy
  DOM.btnCopyActions.addEventListener('click', copyActionItemsToClipboard);
  DOM.btnCopyEmail.addEventListener('click', copyEmailToClipboard);
}

// -------------------------------------------------------------
// 2. Settings & API Key Handling
// -------------------------------------------------------------
function openSettings() {
  DOM.inputApiKey.value = state.apiKey;
  DOM.settingsDialog.showModal();
}

function closeSettings() {
  DOM.settingsDialog.close();
}

function toggleKeyVisibility() {
  const isPassword = DOM.inputApiKey.type === 'password';
  DOM.inputApiKey.type = isPassword ? 'text' : 'password';
  DOM.btnToggleKeyVisibility.textContent = isPassword ? '🔒' : '👁️';
}

function saveApiKey() {
  const key = DOM.inputApiKey.value.trim();
  state.apiKey = key;
  localStorage.setItem('gemini_api_key', key);
  updateApiKeyStatus();
  showToast('Gemini API Key saved successfully.');
  closeSettings();
}

function updateApiKeyStatus() {
  if (state.apiKey) {
    DOM.apiStatusBadge.textContent = 'Configured';
    DOM.apiStatusBadge.className = 'status-badge active';
    DOM.apiKeyWarning.classList.add('hidden');
  } else {
    DOM.apiStatusBadge.textContent = 'Not Set';
    DOM.apiStatusBadge.className = 'status-badge inactive';
    DOM.apiKeyWarning.classList.remove('hidden');
  }
}

// -------------------------------------------------------------
// 3. Participant Directory Management
// -------------------------------------------------------------
function addParticipantFromInput() {
  const name = DOM.inputParticipant.value.trim();
  if (!name) return;

  if (state.participants.includes(name)) {
    showToast(`${name} is already listed.`);
    DOM.inputParticipant.value = '';
    return;
  }

  state.participants.push(name);
  localStorage.setItem('meeting_participants', JSON.stringify(state.participants));
  renderParticipants();
  DOM.inputParticipant.value = '';
  DOM.inputParticipant.focus();
}

function removeParticipant(name) {
  state.participants = state.participants.filter(p => p !== name);
  localStorage.setItem('meeting_participants', JSON.stringify(state.participants));
  renderParticipants();
}

function renderParticipants() {
  DOM.participantsList.innerHTML = '';
  
  if (state.participants.length === 0) {
    DOM.participantsCount.textContent = '0 on call';
    return;
  }
  
  DOM.participantsCount.textContent = `${state.participants.length} on call`;

  state.participants.forEach(name => {
    const chip = document.createElement('div');
    chip.className = 'chip';
    chip.setAttribute('role', 'listitem');

    const avatarColor = getDeterministicColor(name);
    const initial = name.charAt(0).toUpperCase();

    chip.innerHTML = `
      <span class="chip-avatar" style="background: ${avatarColor}">${initial}</span>
      <span>${name}</span>
      <button class="chip-remove" aria-label="Remove ${name}">&times;</button>
    `;

    chip.querySelector('.chip-remove').addEventListener('click', () => removeParticipant(name));
    DOM.participantsList.appendChild(chip);
  });
}

// -------------------------------------------------------------
// 4. Wave Visualizer (Web Audio Analyser)
// -------------------------------------------------------------
function adjustCanvasSize() {
  const container = DOM.canvasVisualizer.parentElement;
  DOM.canvasVisualizer.width = container.clientWidth;
  DOM.canvasVisualizer.height = 60;
  
  // Draw an initial baseline
  drawBaselineVisualizer();
}

function drawBaselineVisualizer() {
  const ctx = DOM.canvasVisualizer.getContext('2d');
  const width = DOM.canvasVisualizer.width;
  const height = DOM.canvasVisualizer.height;
  
  ctx.clearRect(0, 0, width, height);
  ctx.strokeStyle = 'rgba(139, 92, 246, 0.2)';
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(0, height / 2);
  ctx.lineTo(width, height / 2);
  ctx.stroke();
}

function setupAudioVisualizer(stream) {
  // Web Audio Context setup
  state.audioContext = new (window.AudioContext || window.webkitAudioContext)();
  state.analyser = state.audioContext.createAnalyser();
  
  const source = state.audioContext.createMediaStreamSource(stream);
  source.connect(state.analyser);
  
  state.analyser.fftSize = 256;
  const bufferLength = state.analyser.frequencyBinCount;
  state.dataArray = new Uint8Array(bufferLength);
  
  animateVisualizer();
}

function animateVisualizer() {
  if (!state.isRecording) return;
  
  state.animationId = requestAnimationFrame(animateVisualizer);
  
  state.analyser.getByteFrequencyData(state.dataArray);
  
  const ctx = DOM.canvasVisualizer.getContext('2d');
  const width = DOM.canvasVisualizer.width;
  const height = DOM.canvasVisualizer.height;
  
  ctx.clearRect(0, 0, width, height);
  
  // Beautiful neon cyan and purple wave gradient
  const grad = ctx.createLinearGradient(0, 0, width, 0);
  grad.addColorStop(0, '#8b5cf6');
  grad.addColorStop(0.5, '#06b6d4');
  grad.addColorStop(1, '#8b5cf6');
  
  ctx.lineWidth = 3;
  ctx.strokeStyle = grad;
  ctx.shadowBlur = 8;
  ctx.shadowColor = 'rgba(6, 182, 212, 0.4)';
  ctx.beginPath();
  
  const sliceWidth = width / state.dataArray.length;
  let x = 0;
  
  for (let i = 0; i < state.dataArray.length; i++) {
    // Height factor, modified by recording/pause state
    const value = state.dataArray[i] / 255.0;
    const amplitude = state.isPaused ? 0.05 : 0.8;
    const y = (height / 2) + (value * (height / 2) * amplitude * Math.sin(i * 0.15 + Date.now() * 0.005));
    
    if (i === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
    
    x += sliceWidth;
  }
  
  ctx.lineTo(width, height / 2);
  ctx.stroke();
  ctx.shadowBlur = 0; // reset
}

function cleanupVisualizer() {
  if (state.animationId) {
    cancelAnimationFrame(state.animationId);
    state.animationId = null;
  }
  if (state.audioContext) {
    state.audioContext.close();
    state.audioContext = null;
  }
  drawBaselineVisualizer();
}

// -------------------------------------------------------------
// 5. Recording Controls & MediaRecorder Pipeline
// -------------------------------------------------------------
async function toggleRecordingState() {
  if (!state.isRecording) {
    // Validate API Key exists before recording
    if (!state.apiKey) {
      showToast('Please set your Gemini API Key in Settings first!', 'warning');
      openSettings();
      return;
    }
    
    await startRecording();
  } else {
    // Primary mic button toggles pause/resume or stop. Let's make it pause/resume!
    togglePauseState();
  }
}

async function startRecording() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    
    state.audioChunks = [];
    state.secondsElapsed = 0;
    state.isRecording = true;
    state.isPaused = false;
    
    // Check supported types
    let options = { mimeType: 'audio/webm' };
    if (!MediaRecorder.isTypeSupported(options.mimeType)) {
      options = { mimeType: 'audio/mp4' };
      if (!MediaRecorder.isTypeSupported(options.mimeType)) {
        options = {}; // browser default
      }
    }
    
    state.mediaRecorder = new MediaRecorder(stream, options);
    
    state.mediaRecorder.ondataavailable = (event) => {
      if (event.data.size > 0) {
        state.audioChunks.push(event.data);
      }
    };
    
    state.mediaRecorder.onstop = () => {
      stream.getTracks().forEach(track => track.stop());
      processAudioAndAnalyze();
    };
    
    state.mediaRecorder.start(1000); // chunk every 1 sec
    
    // UI state change
    DOM.btnRecordPrimary.className = 'btn-record recording';
    DOM.btnRecordPrimary.setAttribute('aria-label', 'Pause Recording');
    DOM.recordingStatus.textContent = 'Recording active';
    DOM.recordingTimer.textContent = '00:00';
    DOM.activeControls.classList.remove('hidden');
    
    // Start timers and visualizers
    startTimer();
    setupAudioVisualizer(stream);
    showToast('Recording started.');
    
    // Collapse results or empty states
    DOM.stateEmpty.classList.remove('hidden');
    DOM.stateResults.classList.add('hidden');
    
  } catch (err) {
    console.error('Error starting audio recording:', err);
    showToast('Failed to access microphone. Please check permissions.', 'warning');
  }
}

function togglePauseState() {
  if (!state.isRecording || !state.mediaRecorder) return;
  
  if (!state.isPaused) {
    state.mediaRecorder.pause();
    state.isPaused = true;
    DOM.btnRecordPrimary.className = 'btn-record paused';
    DOM.recordingStatus.textContent = 'Recording paused';
    DOM.btnRecordPause.innerHTML = `
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <polygon points="5 3 19 12 5 21 5 3"></polygon>
      </svg>
      <span>Resume</span>
    `;
    showToast('Recording paused.');
  } else {
    state.mediaRecorder.resume();
    state.isPaused = false;
    DOM.btnRecordPrimary.className = 'btn-record recording';
    DOM.recordingStatus.textContent = 'Recording active';
    DOM.btnRecordPause.innerHTML = `
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <line x1="18" y1="4" x2="18" y2="20"></line>
        <line x1="6" y1="4" x2="6" y2="20"></line>
      </svg>
      <span>Pause</span>
    `;
    showToast('Recording resumed.');
  }
}

function stopRecording() {
  if (!state.isRecording || !state.mediaRecorder) return;
  
  showToast('Stopping recording and compiling audio...');
  
  state.isRecording = false;
  clearInterval(state.recordingTimerInterval);
  cleanupVisualizer();
  
  // UI Cleanups
  DOM.btnRecordPrimary.className = 'btn-record idle';
  DOM.btnRecordPrimary.setAttribute('aria-label', 'Start Recording');
  DOM.recordingStatus.textContent = 'Idle';
  DOM.activeControls.classList.add('hidden');
  
  // Trigger Stop Event
  state.mediaRecorder.stop();
}

function startTimer() {
  clearInterval(state.recordingTimerInterval);
  state.recordingTimerInterval = setInterval(() => {
    if (state.isPaused) return;
    
    state.secondsElapsed++;
    
    const minutes = Math.floor(state.secondsElapsed / 60);
    const seconds = state.secondsElapsed % 60;
    
    const formatMin = String(minutes).padStart(2, '0');
    const formatSec = String(seconds).padStart(2, '0');
    
    DOM.recordingTimer.textContent = `${formatMin}:${formatSec}`;
  }, 1000);
}

// -------------------------------------------------------------
// 6. Gemini Integration & AI Analysis
// -------------------------------------------------------------
async function processAudioAndAnalyze() {
  // Construct Blob from parts
  const audioBlob = new Blob(state.audioChunks, { type: state.mediaRecorder.mimeType || 'audio/webm' });
  
  if (audioBlob.size < 1000) {
    showToast('The recorded audio is too short or empty.', 'warning');
    DOM.stateEmpty.classList.remove('hidden');
    DOM.stateProcessing.classList.add('hidden');
    return;
  }

  // Switch Workspace View State to Processing
  DOM.stateEmpty.classList.add('hidden');
  DOM.stateResults.classList.add('hidden');
  DOM.stateProcessing.classList.remove('hidden');
  
  // Reset loader checklist animations
  resetStepper();

  try {
    // Step 1: Base64 Compile
    updateStepper('step-audio', 'completed');
    updateStepper('step-upload', 'active');
    
    const base64Audio = await convertBlobToBase64(audioBlob);
    
    // Step 2: Upload state
    await delay(1200); // visual timing to make transitions smooth
    updateStepper('step-upload', 'completed');
    updateStepper('step-diarization', 'active');
    
    // Step 3: Diarization & mapping
    await delay(1500);
    updateStepper('step-diarization', 'completed');
    updateStepper('step-synthesis', 'active');
    
    // Clean Mime type for API payload
    const rawMime = audioBlob.type.split(';')[0] || 'audio/webm';
    
    // Request content from Gemini API
    const result = await requestGeminiAnalysis(base64Audio, rawMime);
    
    updateStepper('step-synthesis', 'completed');
    await delay(800);
    
    // Store results
    state.results = result;
    
    // Render
    renderResults();
    
    // Switch Workspace View State to Results
    DOM.stateProcessing.classList.add('hidden');
    DOM.stateResults.classList.remove('hidden');
    showToast('Meeting Analysis complete!', 'success');
    
  } catch (error) {
    console.error('Gemini Analysis Failed:', error);
    showToast(error.message || 'An error occurred during AI processing.', 'warning');
    
    // Rollback to empty state
    DOM.stateProcessing.classList.add('hidden');
    DOM.stateEmpty.classList.remove('hidden');
  }
}

async function requestGeminiAnalysis(base64Audio, mimeType) {
  const apiKey = state.apiKey;
  const title = DOM.meetingTitle.value.trim() || 'Product Sync';
  const callTeam = state.participants.length > 0 
    ? state.participants.join(', ')
    : 'Speakers on call';

  const promptText = `You are a premium corporate executive meeting assistant.
You have been provided with the raw audio of a meeting titled "${title}".
The listed participants on the call are: [${callTeam}].

Please complete the following actions:
1. SPEAKER-ATTRIBUTED DIALOGUE TRANSCRIPT: Transcribe the audio word-for-word. Group consecutive dialogue turns. Analyze the raw audio's vocal frequencies, conversation flow, and semantic context to attribute each part to the correct speaker from the list of participants: [${callTeam}]. If multiple speakers are detected but can't be mapped directly, label them as "Speaker A", "Speaker B", etc. or use context to match their names.
2. DETAILED SUMMARY: Generate an elegant executive summary. Start with a list of major takeaways. Extract key details, discussions, decisions, and overall meeting mood/sentiment (collaborative, urgent, alignment, brainstorm).
3. ACTION CHECKLIST: Compile all action items. Assign a clear owner to each item (from the participant list [${callTeam}] where possible).
4. FOLLOW-UP EMAIL DRAFT: Draft a highly professional follow-up email. The subject must be compelling and the body structured. The email must synthesize the meeting discussions, gratitude, and next steps.

Return the response strictly in JSON format matching the schema requested below. Do NOT wrap the JSON in Markdown block ticks like \`\`\`json. Return pure JSON.`;

  // Construct structured JSON Schema response configuration
  const requestBody = {
    contents: [
      {
        role: 'user',
        parts: [
          {
            inlineData: {
              mimeType: mimeType,
              data: base64Audio
            }
          },
          {
            text: promptText
          }
        ]
      }
    ],
    generationConfig: {
      responseMimeType: 'application/json',
      responseSchema: {
        type: 'OBJECT',
        properties: {
          transcript: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: {
                speaker: { type: 'STRING' },
                text: { type: 'STRING' }
              },
              required: ['speaker', 'text']
            }
          },
          summary: { type: 'STRING' },
          sentiment: { type: 'STRING' },
          action_items: {
            type: 'ARRAY',
            items: { type: 'STRING' }
          },
          follow_up_email: {
            type: 'OBJECT',
            properties: {
              subject: { type: 'STRING' },
              body: { type: 'STRING' }
            },
            required: ['subject', 'body']
          }
        },
        required: ['transcript', 'summary', 'sentiment', 'action_items', 'follow_up_email']
      }
    }
  };

  // We will call the beta endpoint for Flash 2.0 to support full direct audio files with structured outputs
  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${apiKey}`;

  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(requestBody)
  });

  if (!response.ok) {
    const errorJson = await response.json().catch(() => ({}));
    const message = errorJson.error?.message || `HTTP error ${response.status}`;
    throw new Error(`Gemini API Error: ${message}`);
  }

  const responseData = await response.json();
  const textResponse = responseData.candidates?.[0]?.content?.parts?.[0]?.text;
  
  if (!textResponse) {
    throw new Error('Received an empty response from the Gemini model.');
  }

  try {
    return JSON.parse(textResponse.trim());
  } catch (err) {
    console.error('Failed to parse Gemini output text as JSON:', textResponse);
    throw new Error('API returned invalid JSON format. Please try again.');
  }
}

// -------------------------------------------------------------
// 7. Results Dashboard Renderers
// -------------------------------------------------------------
function renderResults() {
  const data = state.results;
  if (!data) return;

  // Title chip & Sentiment
  DOM.summaryMeetingName.textContent = DOM.meetingTitle.value.trim() || 'Product Sync';
  DOM.summaryMeetingSentiment.textContent = data.sentiment ? `💡 ${data.sentiment}` : '💡 Productive';

  // 1. Render Summary
  // We can treat summaries as plain text or format basic markdown lines safely
  DOM.contentSummary.innerHTML = formatMarkdownParagraphs(data.summary);

  // 2. Render Transcript
  DOM.contentTranscript.innerHTML = '';
  if (data.transcript && data.transcript.length > 0) {
    data.transcript.forEach(speech => {
      const wrapper = document.createElement('div');
      wrapper.className = 'speech-bubble-wrapper';

      const initial = speech.speaker ? speech.speaker.charAt(0).toUpperCase() : 'S';
      const color = getDeterministicColor(speech.speaker || 'Speaker');

      wrapper.innerHTML = `
        <div class="speech-avatar" style="background: ${color}">${initial}</div>
        <div class="speech-content-card">
          <span class="speech-speaker" style="color: ${color}">${speech.speaker || 'Unknown'}</span>
          <span class="speech-text">${speech.text || ''}</span>
        </div>
      `;
      DOM.contentTranscript.appendChild(wrapper);
    });
  } else {
    DOM.contentTranscript.innerHTML = '<p class="section-subtext">No transcript records found.</p>';
  }

  // 3. Render Action Items
  DOM.contentActions.innerHTML = '';
  if (data.action_items && data.action_items.length > 0) {
    data.action_items.forEach((item, index) => {
      const checklistItem = document.createElement('div');
      checklistItem.className = 'checklist-item';
      checklistItem.id = `action-item-${index}`;

      checklistItem.innerHTML = `
        <div class="checkbox-custom"></div>
        <span class="checklist-item-text">${item}</span>
      `;

      checklistItem.addEventListener('click', () => {
        checklistItem.classList.toggle('checked');
      });

      DOM.contentActions.appendChild(checklistItem);
    });
  } else {
    DOM.contentActions.innerHTML = '<p class="section-subtext">No action items detected.</p>';
  }

  // 4. Render Email
  const subject = data.follow_up_email?.subject || 'Meeting Follow-up';
  const body = data.follow_up_email?.body || 'Dear Team, \nThank you for attending the sync.';
  
  DOM.emailPreviewSubject.textContent = subject;
  DOM.emailPreviewBody.textContent = body;

  // mailto structure
  DOM.linkSendEmail.href = `mailto:?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}

// -------------------------------------------------------------
// 8. Helper Functions & Utilities
// -------------------------------------------------------------
function convertBlobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = reject;
    reader.onload = () => {
      const base64String = reader.result.split(',')[1];
      resolve(base64String);
    };
    reader.readAsDataURL(blob);
  });
}

function getDeterministicColor(str) {
  // Generate deterministic HSL color based on string hash for matching avatars
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = str.charCodeAt(i) + ((hash << 5) - hash);
  }
  const hue = Math.abs(hash % 360);
  // Keep saturation high and lightness medium-low for rich glow contrast on dark theme
  return `hsl(${hue}, 70%, 55%)`;
}

function formatMarkdownParagraphs(text) {
  if (!text) return '';
  // Super simple and safe markdown converter for paragraphs, bullet lines and bold headers
  return text
    .split('\n')
    .map(line => {
      const trimmed = line.trim();
      if (!trimmed) return '';
      
      // Bullets
      if (trimmed.startsWith('* ') || trimmed.startsWith('- ')) {
        return `<li>${formatInlineBold(trimmed.substring(2))}</li>`;
      }
      // H4 Headers
      if (trimmed.startsWith('####')) {
        return `<h4>${formatInlineBold(trimmed.substring(4).trim())}</h4>`;
      }
      if (trimmed.startsWith('###')) {
        return `<h4>${formatInlineBold(trimmed.substring(3).trim())}</h4>`;
      }
      
      return `<p>${formatInlineBold(trimmed)}</p>`;
    })
    .join('')
    .replace(/(<li>.*<\/li>)/gs, '<ul>$1</ul>')
    .replace(/<\/ul><ul>/g, ''); // consolidate consecutive lists
}

function formatInlineBold(str) {
  // safe regex match for bold text (**bold**)
  return str.replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');
}

function updateStepper(stepId, stateClass) {
  const el = document.getElementById(stepId);
  if (!el) return;
  
  el.className = `processing-step ${stateClass}`;
}

function resetStepper() {
  updateStepper('step-audio', 'active');
  updateStepper('step-upload', '');
  updateStepper('step-diarization', '');
  updateStepper('step-synthesis', '');
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function copyActionItemsToClipboard() {
  if (!state.results?.action_items) return;
  
  const text = state.results.action_items
    .map((item, idx) => {
      const el = document.getElementById(`action-item-${idx}`);
      const isChecked = el && el.classList.contains('checked');
      return `[${isChecked ? 'x' : ' '}] ${item}`;
    })
    .join('\n');

  navigator.clipboard.writeText(text)
    .then(() => showToast('Action items list copied to clipboard!', 'success'))
    .catch(err => console.error('Failed to copy text:', err));
}

function copyEmailToClipboard() {
  if (!state.results?.follow_up_email) return;

  const subject = state.results.follow_up_email.subject;
  const body = state.results.follow_up_email.body;
  const text = `Subject: ${subject}\n\n${body}`;

  navigator.clipboard.writeText(text)
    .then(() => showToast('Email draft copied to clipboard!', 'success'))
    .catch(err => console.error('Failed to copy text:', err));
}

function showToast(message, type = 'info') {
  DOM.toastMessage.textContent = message;
  
  // Apply toast visual styling based on level
  if (type === 'success') {
    DOM.toast.style.borderColor = 'var(--color-success)';
  } else if (type === 'warning') {
    DOM.toast.style.borderColor = 'var(--color-danger)';
  } else {
    DOM.toast.style.borderColor = 'var(--accent-purple)';
  }

  DOM.toast.classList.remove('hidden');

  // Dismiss automatically after 3.5 seconds
  setTimeout(() => {
    DOM.toast.classList.add('hidden');
  }, 3500);
}

// Kickstart App on window load
window.addEventListener('DOMContentLoaded', initApp);
