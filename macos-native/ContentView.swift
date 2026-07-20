import SwiftUI

struct ContentView: View {
    // API State
    @AppStorage("gemini_api_key") private var apiKey = ""
    @AppStorage("gemini_selected_model") private var selectedModel = ContentView.defaultModel

    // Live Gemini models as of July 2026. Google retires model IDs regularly
    // (1.5: Sept 2025, 2.0: June 2026) — when it happens again, the API's 404
    // is surfaced in the UI and points the user here.
    static let defaultModel = "gemini-3.5-flash"
    static let availableModels: [(id: String, label: String)] = [
        ("gemini-3.5-flash", "Gemini 3.5 Flash (recommended)"),
        ("gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite (fastest)"),
        ("gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview — paid key required)"),
    ]
    @State private var showSettings = false
    @State private var apiStatusText = "Not Set"
    
    // Call Team State
    @State private var participants: [String] = []
    @State private var newParticipantName = ""
    
    // Meeting Context State
    @State private var meetingTitle = "Product Brainstorm"
    
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

    // Workspace States
    @State private var selectedTab = 0 // 0: Summary, 1: Transcript, 2: Action Items, 3: Email
    @State private var stepState = "Idle"
    @State private var progressText = ""
    
    // Colors
    let bgDark = Color(red: 0.03, green: 0.02, blue: 0.06)
    let panelDark = Color(red: 0.06, green: 0.05, blue: 0.11).opacity(0.65)
    let borderDark = Color.white.opacity(0.08)
    let accentPurple = Color(red: 0.54, green: 0.36, blue: 0.96)
    let accentCyan = Color(red: 0.02, green: 0.71, blue: 0.83)
    let successColor = Color(red: 0.06, green: 0.73, blue: 0.51)
    let warningColor = Color(red: 0.96, green: 0.62, blue: 0.04)
    
    var body: some View {
        ZStack {
            // Background Dark & Ambient Glow Effects
            bgDark.ignoresSafeArea()
            
            // Ambient Radial Glows
            RadialGradient(gradient: Gradient(colors: [accentPurple.opacity(0.12), .clear]), center: .topTrailing, startRadius: 10, endRadius: 300)
                .ignoresSafeArea()
            RadialGradient(gradient: Gradient(colors: [accentCyan.opacity(0.08), .clear]), center: .bottomLeading, startRadius: 10, endRadius: 350)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header Bar
                HStack {
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(LinearGradient(gradient: Gradient(colors: [accentPurple, accentCyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .padding(8)
                            .background(Color.white.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderDark, lineWidth: 1))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text("EchoScribe")
                                    .font(.system(size: 20, weight: .black, design: .rounded))
                                    .foregroundStyle(.white)
                                
                                Text("macOS v2.0")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(accentPurple.opacity(0.15))
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(accentPurple.opacity(0.3), lineWidth: 1))
                            }
                            Text("Premium Local Meeting Assistant")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    
                    Spacer()
                    
                    // API Warning Banner Inline
                    if apiKey.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(warningColor)
                            Text("Missing API Key")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(warningColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(warningColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(warningColor.opacity(0.2), lineWidth: 1))
                    }
                    
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderDark, lineWidth: 1))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(panelDark)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(borderDark, lineWidth: 1))
                
                // Main Workspace Grid
                GeometryReader { geo in
                    HStack(spacing: 20) {
                        // LEFT PANEL: Meeting Controls
                        VStack(alignment: .leading, spacing: 20) {
                            // Section: Meeting Title Input
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Meeting Context")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .textCase(.uppercase)
                                
                                TextField("Enter title...", text: $meetingTitle)
                                    .textFieldStyle(.plain)
                                    .padding(10)
                                    .background(Color.white.opacity(0.03))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderDark, lineWidth: 1))
                            }
                            
                            Divider().background(Color.white.opacity(0.05))
                            
                            // Section: Recorder Station
                            VStack(alignment: .center, spacing: 16) {
                                Text("Audio Recorder")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .textCase(.uppercase)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // Glowing Mic Button
                                Button(action: toggleRecording) {
                                    ZStack {
                                        Circle()
                                            .fill(recorder.isRecording ? (recorder.isPaused ? warningColor : Color.red) : accentPurple)
                                            .frame(width: 80, height: 80)
                                            .blur(radius: 8)
                                            .opacity(recorder.isRecording ? 0.6 : 0.2)
                                        
                                        Circle()
                                            .fill(Color(red: 0.08, green: 0.07, blue: 0.14))
                                            .frame(width: 70, height: 70)
                                            .shadow(color: .black.opacity(0.5), radius: 6)
                                        
                                        Image(systemName: recorder.isRecording ? (recorder.isPaused ? "play.fill" : "pause.fill") : "mic.fill")
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundStyle(recorder.isRecording ? (recorder.isPaused ? warningColor : Color.red) : accentPurple)
                                    }
                                }
                                .buttonStyle(.plain)
                                
                                // Time & Status
                                VStack(spacing: 4) {
                                    Text(recorder.isRecording ? (recorder.isPaused ? "Recording Paused" : "Recording Active") : "Idle")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(recorder.isRecording ? (recorder.isPaused ? warningColor : Color.red) : .white.opacity(0.6))
                                    
                                    Text(formatTime(recorder.elapsedSeconds))
                                        .font(.system(size: 26, weight: .black, design: .monospaced))
                                        .foregroundStyle(.white)
                                }
                                
                                // Pause & Stop buttons
                                if recorder.isRecording {
                                    HStack(spacing: 12) {
                                        Button(action: { recorder.pauseRecording() }) {
                                            HStack {
                                                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                                                Text(recorder.isPaused ? "Resume" : "Pause")
                                            }
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(warningColor.opacity(0.12))
                                            .foregroundStyle(warningColor)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(warningColor.opacity(0.25), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        
                                        Button(action: stopAndAnalyze) {
                                            HStack {
                                                Image(systemName: "stop.fill")
                                                Text("Stop & Analyze")
                                            }
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 8)
                                            .background(Color.red.opacity(0.12))
                                            .foregroundStyle(.red)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.25), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                
                                // Live levels visualizer wave — isolated subview so the
                                // ~10 Hz metering updates re-render only these bars, not
                                // the whole ContentView.
                                AudioLevelVisualizer(recorder: recorder, accentPurple: accentPurple, accentCyan: accentCyan)
                            }
                            
                            Divider().background(Color.white.opacity(0.05))
                            
                            // Section: Participant Directory
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Meeting Call Team")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .textCase(.uppercase)
                                    Spacer()
                                    Text("\(participants.count) on call")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.06))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .clipShape(Capsule())
                                }
                                
                                Text("Add who is speaking to provide vocal mapping context to Gemini.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.4))
                                
                                HStack(spacing: 8) {
                                    TextField("Enter name...", text: $newParticipantName, onCommit: addParticipant)
                                        .textFieldStyle(.plain)
                                        .padding(10)
                                        .background(Color.white.opacity(0.03))
                                        .foregroundStyle(.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderDark, lineWidth: 1))
                                    
                                    Button(action: addParticipant) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(10)
                                            .background(LinearGradient(gradient: Gradient(colors: [accentPurple, accentCyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                // Chips Flow list
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(participants, id: \.self) { p in
                                            HStack(spacing: 6) {
                                                Text(String(p.prefix(1).uppercased()))
                                                    .font(.system(size: 10, weight: .bold))
                                                    .frame(width: 18, height: 18)
                                                    .background(getDeterministicColor(p))
                                                    .foregroundStyle(.white)
                                                    .clipShape(Circle())
                                                
                                                Text(p)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(.white)
                                                
                                                Button(action: { participants.removeAll(where: { $0 == p }) }) {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 8, weight: .bold))
                                                        .foregroundStyle(.white.opacity(0.5))
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color.white.opacity(0.04))
                                            .clipShape(Capsule())
                                            .overlay(Capsule().stroke(borderDark, lineWidth: 1))
                                        }
                                    }
                                }
                                .frame(height: 35)
                            }
                        }
                        .padding(24)
                        .frame(width: 380)
                        .frame(maxHeight: .infinity)
                        .background(panelDark)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(borderDark, lineWidth: 1))
                        
                        // RIGHT PANEL: Results Workspace
                        VStack(spacing: 0) {
                            if stepState == "Processing" {
                                // Processing / loading view
                                VStack(spacing: 24) {
                                    ZStack {
                                        Circle()
                                            .stroke(accentPurple.opacity(0.15), lineWidth: 3)
                                            .frame(width: 70, height: 70)
                                        
                                        Circle()
                                            .trim(from: 0, to: 0.6)
                                            .stroke(LinearGradient(gradient: Gradient(colors: [accentPurple, accentCyan]), startPoint: .top, endPoint: .bottom), lineWidth: 3)
                                            .frame(width: 70, height: 70)
                                            .rotationEffect(.degrees(gemini.isProcessing ? 360 : 0))
                                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: gemini.isProcessing)
                                        
                                        Image(systemName: "brain.headset")
                                            .font(.system(size: 24))
                                            .foregroundStyle(accentCyan)
                                    }
                                    
                                    VStack(spacing: 8) {
                                        Text("Generating Intelligent Analysis")
                                            .font(.system(size: 18, weight: .bold, design: .rounded))
                                        Text(progressText)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.white.opacity(0.6))
                                    }
                                    
                                    // Custom visual steps checklist
                                    VStack(alignment: .leading, spacing: 14) {
                                        StepItem(title: "Compiling raw audio stream...", active: true, done: true, colors: [successColor, accentPurple])
                                        StepItem(title: "Sending payload to Gemini...", active: true, done: true, colors: [successColor, accentPurple])
                                        StepItem(title: "Applying voice separation & speaker mapping...", active: true, done: true, colors: [successColor, accentPurple])
                                        StepItem(title: "Compiling transcript, action items & email draft...", active: true, done: false, colors: [accentPurple, accentCyan])
                                    }
                                    .padding(20)
                                    .frame(width: 380)
                                    .background(Color.black.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderDark, lineWidth: 1))
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else if let meeting = selectedMeeting, let analysis = meeting.analysis {
                                // Dynamic results view with tabs
                                VStack(spacing: 0) {
                                    // Tab buttons header
                                    HStack(spacing: 4) {
                                        TabButton(title: "Summary", systemName: "doc.text.fill", isSelected: selectedTab == 0) { selectedTab = 0 }
                                        TabButton(title: "Transcript", systemName: "bubble.left.and.bubble.right.fill", isSelected: selectedTab == 1) { selectedTab = 1 }
                                        TabButton(title: "Action Items", systemName: "checklist", isSelected: selectedTab == 2) { selectedTab = 2 }
                                        TabButton(title: "Follow-up Email", systemName: "envelope.fill", isSelected: selectedTab == 3) { selectedTab = 3 }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.top, 16)
                                    .background(Color.black.opacity(0.2))
                                    
                                    // Tab views viewport
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 20) {
                                            if selectedTab == 0 {
                                                // Summary View
                                                HStack {
                                                    Text("Meeting Digest")
                                                        .font(.system(size: 18, weight: .bold))
                                                    Spacer()
                                                    HStack(spacing: 6) {
                                                        Text("💡")
                                                        Text(analysis.sentiment)
                                                            .font(.system(size: 11, weight: .bold))
                                                            .foregroundStyle(accentCyan)
                                                    }
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 4)
                                                    .background(accentCyan.opacity(0.1))
                                                    .clipShape(Capsule())
                                                    .overlay(Capsule().stroke(accentCyan.opacity(0.25), lineWidth: 1))
                                                }
                                                
                                                Text(analysis.summary)
                                                    .font(.system(size: 14))
                                                    .lineSpacing(6)
                                                    .foregroundStyle(.white.opacity(0.9))
                                            } else if selectedTab == 1 {
                                                // Transcript View
                                                Text("Speaker-Attributed Dialogue")
                                                    .font(.system(size: 18, weight: .bold))
                                                
                                                VStack(alignment: .leading, spacing: 14) {
                                                    ForEach(analysis.transcript) { item in
                                                        HStack(alignment: .top, spacing: 12) {
                                                            Text(String(item.speaker.prefix(1).uppercased()))
                                                                .font(.system(size: 12, weight: .bold))
                                                                .frame(width: 32, height: 32)
                                                                .background(getDeterministicColor(item.speaker))
                                                                .foregroundStyle(.white)
                                                                .clipShape(Circle())
                                                            
                                                            VStack(alignment: .leading, spacing: 4) {
                                                                Text(item.speaker)
                                                                    .font(.system(size: 12, weight: .bold))
                                                                    .foregroundStyle(getDeterministicColor(item.speaker))
                                                                Text(item.text)
                                                                    .font(.system(size: 13))
                                                                    .foregroundStyle(.white.opacity(0.85))
                                                            }
                                                            .padding(12)
                                                            .background(Color.white.opacity(0.02))
                                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderDark, lineWidth: 1))
                                                        }
                                                    }
                                                }
                                            } else if selectedTab == 2 {
                                                // Action Items View
                                                HStack {
                                                    Text("Action Checklist")
                                                        .font(.system(size: 18, weight: .bold))
                                                    Spacer()
                                                    Button(action: syncToReminders) {
                                                        HStack(spacing: 6) {
                                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                            Text("Sync to Reminders")
                                                        }
                                                        .font(.system(size: 11, weight: .bold))
                                                        .foregroundStyle(accentPurple)
                                                    }
                                                    .buttonStyle(.plain)
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 6)
                                                    .background(accentPurple.opacity(0.1))
                                                    .clipShape(Capsule())
                                                    .overlay(Capsule().stroke(accentPurple.opacity(0.25), lineWidth: 1))
                                                }
                                                
                                                VStack(alignment: .leading, spacing: 10) {
                                                    ForEach(analysis.actionItems, id: \.self) { item in
                                                        HStack(alignment: .top, spacing: 12) {
                                                            Image(systemName: "square")
                                                                .foregroundStyle(accentCyan)
                                                            Text(item)
                                                                .font(.system(size: 13))
                                                                .foregroundStyle(.white)
                                                        }
                                                        .padding(14)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(Color.white.opacity(0.02))
                                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderDark, lineWidth: 1))
                                                    }
                                                }
                                            } else if selectedTab == 3 {
                                                // Email View
                                                HStack {
                                                    Text("Follow-up Draft")
                                                        .font(.system(size: 18, weight: .bold))
                                                    Spacer()
                                                    
                                                    HStack(spacing: 8) {
                                                        Button(action: copyEmailToClipboard) {
                                                            HStack(spacing: 4) {
                                                                Image(systemName: "doc.on.doc")
                                                                Text("Copy")
                                                            }
                                                        }
                                                        .buttonStyle(.plain)
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 6)
                                                        .background(Color.white.opacity(0.06))
                                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderDark, lineWidth: 1))
                                                        
                                                        Button(action: openInMailApp) {
                                                            HStack(spacing: 4) {
                                                                Image(systemName: "paperplane.fill")
                                                                Text("Send")
                                                            }
                                                            .foregroundStyle(.black)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 6)
                                                        .background(LinearGradient(gradient: Gradient(colors: [accentPurple, accentCyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                                    }
                                                    .font(.system(size: 11, weight: .bold))
                                                }
                                                
                                                VStack(alignment: .leading, spacing: 0) {
                                                    HStack(spacing: 8) {
                                                        Text("Subject:")
                                                            .font(.system(size: 12, weight: .bold))
                                                            .foregroundStyle(.white.opacity(0.6))
                                                        Text(analysis.followUpEmail.subject)
                                                            .font(.system(size: 12, weight: .bold))
                                                            .foregroundStyle(.white)
                                                    }
                                                    .padding(14)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(Color.white.opacity(0.02))
                                                    .overlay(Rectangle().stroke(borderDark, lineWidth: 0.5))
                                                    
                                                    Text(analysis.followUpEmail.body)
                                                        .font(.system(size: 13, design: .monospaced))
                                                        .lineSpacing(5)
                                                        .padding(20)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(Color.black.opacity(0.15))
                                                }
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderDark, lineWidth: 1))
                                            }
                                        }
                                        .padding(28)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                // Default Empty State (shows the last API error, if any —
                                // failures used to be swallowed silently here)
                                VStack(spacing: 16) {
                                    if let apiError = displayedError {
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

                                            Text(apiError)
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
                                        .padding(.bottom, 12)
                                    }

                                    Image(systemName: "waveform.circle.fill")
                                        .font(.system(size: 72))
                                        .foregroundStyle(LinearGradient(gradient: Gradient(colors: [accentPurple, accentCyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .padding(.bottom, 8)
                                    
                                    Text("Ready to Listen")
                                        .font(.system(size: 22, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    
                                    Text("Configure your API Key, list the meeting participants, and press the microphone to record. Gemini will analyze the audio to compile professional transcripts, action item checklists, and follow-up email drafts.")
                                        .font(.system(size: 13))
                                        .multilineTextAlignment(.center)
                                        .lineSpacing(4)
                                        .foregroundStyle(.white.opacity(0.5))
                                        .padding(.horizontal, 48)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(panelDark)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(borderDark, lineWidth: 1))
                    }
                }
            }
            .padding(24)
            
            // Native Settings Modal dialog
            if showSettings {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { showSettings = false }
                
                VStack(spacing: 20) {
                    HStack {
                        Text("Gemini Configuration")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Spacer()
                        Button(action: { showSettings = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Configure your private Gemini API Key to enable raw meeting transcription, dialogue speaker attribution, summaries, and action item compiling.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineSpacing(4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Gemini API Key")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                            
                            SecureField("AQ.… (from aistudio.google.com/apikey)", text: $apiKey)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.white.opacity(0.04))
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderDark, lineWidth: 1))
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Model Selection")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                            
                            Picker("", selection: $selectedModel) {
                                ForEach(ContentView.availableModels, id: \.id) { model in
                                    Text(model.label).tag(model.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .background(Color.white.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderDark, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 20)
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    HStack {
                        Spacer()
                        Button("Close") { showSettings = false }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(LinearGradient(gradient: Gradient(colors: [accentPurple, accentCyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .frame(width: 420)
                .background(Color(red: 0.08, green: 0.07, blue: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(accentPurple.opacity(0.3), lineWidth: 1))
                .shadow(color: accentPurple.opacity(0.15), radius: 30)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(minWidth: 1000, minHeight: 650)
        .onAppear {
            // Heal a stored model that Google has since retired (e.g. the old
            // gemini-2.0-flash default) — otherwise every analysis 404s.
            if !ContentView.availableModels.contains(where: { $0.id == selectedModel }) {
                selectedModel = ContentView.defaultModel
            }
        }
    }

    // Actions & Handlers
    
    func formatTime(_ sec: TimeInterval) -> String {
        let mins = Int(sec) / 60
        let secs = Int(sec) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    func addParticipant() {
        let name = newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !participants.contains(name) {
            participants.append(name)
        }
        newParticipantName = ""
    }
    
    func toggleRecording() {
        if recorder.isRecording {
            recorder.pauseRecording()
        } else {
            recorder.startRecording()
            stepState = "Idle"
        }
    }
    
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

    func syncToReminders() {
        guard let analysis = selectedMeeting?.analysis else { return }
        eventKit.createReminders(from: analysis.actionItems, listTitle: "\(meetingTitle) Actions")
    }

    func copyEmailToClipboard() {
        guard let analysis = selectedMeeting?.analysis else { return }
        let text = "Subject: \(analysis.followUpEmail.subject)\n\n\(analysis.followUpEmail.body)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openInMailApp() {
        guard let analysis = selectedMeeting?.analysis else { return }
        let subject = analysis.followUpEmail.subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = analysis.followUpEmail.body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:?subject=\(subject)&body=\(body)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func getDeterministicColor(_ str: String) -> Color {
        var hash = 0
        for char in str.unicodeScalars {
            hash = Int(char.value) + ((hash << 5) - hash)
        }
        let hue = Double(abs(hash % 360)) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.7)
    }
}

struct StepItem: View {
    let title: String
    let active: Bool
    let done: Bool
    let colors: [Color]
    
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(done ? Color(red: 0.06, green: 0.73, blue: 0.51) : (active ? accentColor : Color.white.opacity(0.2)))
                .frame(width: 8, height: 8)
            
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(done ? .white.opacity(0.7) : (active ? .white : .white.opacity(0.35)))
            
            Spacer()
        }
    }
    
    private var accentColor: Color {
        colors.first ?? Color.blue
    }
}

struct TabButton: View {
    let title: String
    let systemName: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                Text(title)
            }
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(isSelected ? Color(red: 0.02, green: 0.71, blue: 0.83) : Color.white.opacity(0.5))
            .background(isSelected ? Color(red: 0.06, green: 0.05, blue: 0.11).opacity(0.4) : Color.clear)
            .overlay(
                Rectangle()
                    .frame(height: 2)
                    .foregroundStyle(isSelected ? Color(red: 0.02, green: 0.71, blue: 0.83) : Color.clear),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }
}

/// Live audio-level bars. Owns its own AudioLevelMonitor so the ~10 Hz metering
/// updates re-render only this view. It feeds the recorder's `onAudioLevel`
/// closure into the monitor; the recorder holds a stable reference here.
struct AudioLevelVisualizer: View {
    let recorder: AudioRecorderManager
    let accentPurple: Color
    let accentCyan: Color

    @StateObject private var monitor = AudioLevelMonitor()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(monitor.levels.indices, id: \.self) { idx in
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(gradient: Gradient(colors: [accentPurple, accentCyan]), startPoint: .top, endPoint: .bottom))
                    .frame(width: 4, height: max(4, CGFloat(160 + monitor.levels[idx]) * 0.4))
            }
        }
        .frame(height: 50)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            recorder.onAudioLevel = { power in
                monitor.append(power)
            }
        }
    }
}
