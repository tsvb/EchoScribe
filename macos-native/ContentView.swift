import SwiftUI
import FoundationModels

struct ContentView: View {
    // API State. Keys are held in memory by provider id and mirrored into the
    // Keychain on change; the model lists live in the CloudProviders registry.
    @State private var cloudKeys: [String: String] = [:]
    // Providers whose Keychain read FAILED (vs "no item"): their field shows ""
    // that we invented, so an empty value must never be saved back as a delete.
    @State private var unreadableKeyProviders: Set<String> = []
    @State private var showSettings = false
    
    // Call Team State
    @State private var participants: [String] = []
    @State private var newParticipantName = ""
    
    // Meeting Context State
    @State private var meetingTitle = "Product Brainstorm"
    
    // Subsystem States
    @StateObject private var recorder = AudioRecorderManager()
    @StateObject private var eventKit = EventKitManager()
    @StateObject private var store = MeetingStore()
    @StateObject private var playback = AudioPlaybackManager()

    // History / selection state. The store is the single source of truth: the
    // workspace always renders the SELECTED meeting's stored analysis.
    @State private var selectedMeetingID: UUID?
    @State private var analysisError: String?

    // Engine preference ("auto" | "apple" | a CloudProviders id). Auto prefers
    // the on-device Apple engine when available.
    @AppStorage("analysis_engine") private var enginePreferenceRaw = "auto"
    private var appleEngineAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        return false
    }

    private var selectedMeeting: Meeting? {
        store.meetings.first { $0.id == selectedMeetingID }
    }

    /// Editing binding for one provider's key field; missing entries read empty.
    private func keyBinding(_ provider: CloudProvider) -> Binding<String> {
        Binding(get: { cloudKeys[provider.id] ?? "" },
                set: { cloudKeys[provider.id] = $0 })
    }

    /// Provider ids that currently have a usable key.
    private var presentCloudKeys: Set<String> {
        Set(cloudKeys.filter { !$0.value.isEmpty }.keys)
    }

    private var displayedError: String? {
        analysisError ?? store.lastError ?? playback.lastError
    }

    /// True when the current engine preference cannot produce an analysis
    /// (e.g. a cloud engine selected with no key, or nothing available at all).
    private var engineUnavailable: Bool {
        let preference = EnginePreference(raw: enginePreferenceRaw)
        let context = EngineContext(appleAvailable: appleEngineAvailable,
                                    cloudKeys: presentCloudKeys)
        if case .none = resolveEngine(preference: preference, context: context) {
            return true
        }
        return false
    }

    // Section: Previous meetings
    private var meetingHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Previous Meetings (\(store.meetings.count))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .textCase(.uppercase)
                Spacer()
                Button(action: startNewMeeting) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.06))
                    .foregroundStyle(.white.opacity(0.8))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if store.meetings.isEmpty {
                Text("Recordings you make will appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.meetings) { meeting in
                            MeetingRow(
                                meeting: meeting,
                                isSelected: meeting.id == selectedMeetingID,
                                onOpen: {
                                    guard stepState != "Processing" else { return }
                                    selectedMeetingID = meeting.id
                                    analysisError = nil
                                    stepState = meeting.analysis == nil ? "Idle" : "Results"
                                },
                                onRename: { newTitle in store.rename(id: meeting.id, to: newTitle) },
                                onReanalyze: { if stepState != "Processing" { runAnalysis(on: meeting) } },
                                onDelete: {
                                    if playback.currentURL == store.audioURL(for: meeting) { playback.stop() }
                                    if selectedMeetingID == meeting.id { startNewMeeting() }
                                    store.delete(id: meeting.id)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func meetingHeader(_ meeting: Meeting) -> some View {
        let audioURL = store.audioURL(for: meeting)
        let audioExists = FileManager.default.fileExists(atPath: audioURL.path)
        let isThisPlaying = playback.isPlaying && playback.currentURL == audioURL

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(MeetingRow.headerDate(meeting.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()

            Button(action: { playback.togglePlayback(url: audioURL) }) {
                HStack(spacing: 6) {
                    Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                    PlaybackTimeLabel(clock: playback.clock, isActive: isThisPlaying,
                                      fallback: meeting.duration)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .foregroundStyle(.white.opacity(audioExists ? 0.9 : 0.3))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!audioExists)

            Button(action: { runAnalysis(on: meeting) }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Re-analyze")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(accentPurple.opacity(0.15))
                .foregroundStyle(.white.opacity(audioExists ? 0.9 : 0.3))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!audioExists || stepState == "Processing")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.25))
    }

    @ViewBuilder
    private func notAnalyzedView(_ meeting: Meeting) -> some View {
        VStack(spacing: 16) {
            if let apiError = displayedError {
                errorCard(apiError)
            }
            Image(systemName: "doc.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.25))
            Text("Not analyzed yet")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("The recording is saved. Run analysis to generate the transcript, summary, action items, and follow-up email.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text("Analysis Failed")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { analysisError = nil; store.lastError = nil; playback.lastError = nil }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            Text(message)
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
    }

    // Workspace States
    @State private var selectedTab = 0 // 0: Summary, 1: Transcript, 2: Action Items, 3: Email
    @State private var stepState = "Idle"
    @State private var progressText = ""
    // Drives the processing ring's rotation. Engines report progress as text
    // only, so this local flag keeps the spinner animating for whichever
    // engine (cloud or on-device) is running.
    @State private var processingSpinner = false
    
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
                                
                                Text("macOS v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"))
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
                    
                    // Warn only when the current engine preference can't actually run —
                    // keyless is fine when the on-device Apple engine covers "auto".
                    if engineUnavailable {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(warningColor)
                            Text("No Analysis Engine")
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
                                
                                Text("Add who is on the call so analysis can attribute action items — and, with a cloud engine, map dialogue to speakers.")
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

                            Divider().background(Color.white.opacity(0.05))

                            meetingHistorySection
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
                                            .rotationEffect(.degrees(processingSpinner ? 360 : 0))
                                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: processingSpinner)
                                        
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
                                        StepItem(title: progressText.isEmpty ? "Analyzing..." : progressText, active: true, done: false, colors: [accentPurple, accentCyan])
                                    }
                                    .padding(20)
                                    .frame(width: 380)
                                    .background(Color.black.opacity(0.2))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderDark, lineWidth: 1))
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .onAppear { processingSpinner = true }
                                .onDisappear { processingSpinner = false }
                            } else if let meeting = selectedMeeting, let analysis = meeting.analysis {
                                // Dynamic results view with tabs
                                VStack(spacing: 0) {
                                    meetingHeader(meeting)
                                    if let apiError = displayedError {
                                        errorCard(apiError)
                                            .padding(.top, 12)
                                    }
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
                                                Text(CloudProviders.transcriptHeader(engine: meeting.engine))
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
                            } else if let meeting = selectedMeeting {
                                // Saved but not analyzed (engine failed or none configured)
                                VStack(spacing: 0) {
                                    meetingHeader(meeting)
                                    notAnalyzedView(meeting)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                // Default Empty State (shows the last API error, if any —
                                // failures used to be swallowed silently here)
                                VStack(spacing: 16) {
                                    if let apiError = displayedError {
                                        errorCard(apiError)
                                            .padding(.bottom, 12)
                                    }

                                    Image(systemName: "waveform.circle.fill")
                                        .font(.system(size: 72))
                                        .foregroundStyle(LinearGradient(gradient: Gradient(colors: [accentPurple, accentCyan]), startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .padding(.bottom, 8)
                                    
                                    Text("Ready to Listen")
                                        .font(.system(size: 22, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    
                                    Text("List the participants and press the microphone to record. Analysis runs on-device with Apple Intelligence, or through Gemini or OpenAI when configured — transcripts, summaries, action items, and a follow-up email draft.")
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
                        Text("Analysis Settings")
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
                        Text("Analysis can run fully on-device with Apple Intelligence — no key needed. A Gemini or OpenAI API key is optional: cloud engines add speaker attribution and higher-polish summaries; OpenAI performs true voice-based speaker diarization.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineSpacing(4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Analysis Engine")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))

                            Picker("", selection: $enginePreferenceRaw) {
                                Text("Auto — on-device when available").tag("auto")
                                Text("Apple on-device (private, no key)").tag("apple")
                                ForEach(CloudProviders.all) { provider in
                                    Text(provider.engineOptionLabel).tag(provider.id)
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

                        ForEach(CloudProviders.all) { provider in
                            CloudProviderSettingsSection(provider: provider,
                                                         apiKey: keyBinding(provider))
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
            // Migrate the legacy plaintext-UserDefaults Gemini key into the
            // Keychain once, then load every registered provider's key from
            // the Keychain (loop below).
            if let legacy = UserDefaults.standard.string(forKey: "gemini_api_key") {
                // Migrate only into a CONFIRMED-empty Keychain, and only drop the
                // legacy copy once the Keychain write is confirmed (never lose the
                // only copy). A failed read confirms nothing — skip the migration
                // this launch and retry on the next one.
                do {
                    if legacy.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "gemini_api_key")
                    } else if try KeychainStore.geminiAPIKey.read() == nil {
                        if KeychainStore.geminiAPIKey.save(legacy) {
                            UserDefaults.standard.removeObject(forKey: "gemini_api_key")
                        }
                    } else {
                        // Keychain already authoritative; stale defaults copy can go.
                        UserDefaults.standard.removeObject(forKey: "gemini_api_key")
                    }
                } catch {
                    // Keychain unreadable (locked / access denied) — leave the
                    // legacy copy in place for a future launch.
                }
            }
            for provider in CloudProviders.all {
                do {
                    cloudKeys[provider.id] = try provider.keychain.read() ?? ""
                    unreadableKeyProviders.remove(provider.id)
                } catch {
                    // The key may exist but be unreadable. Show an empty field,
                    // and remember not to issue deletes for this provider.
                    cloudKeys[provider.id] = ""
                    unreadableKeyProviders.insert(provider.id)
                }

                // Heal a stored model the provider has since retired (e.g. the
                // old gemini-2.0-flash default) — otherwise every analysis
                // fails. Done here rather than in the settings subview so
                // runAnalysis sees healed values even if Settings never opens.
                // Only rewrite an existing choice: writing on a missing key
                // would pin users who never opened Settings to today's default.
                if let stored = UserDefaults.standard.string(forKey: provider.modelDefaultsKey) {
                    let healed = CloudProviders.healedModel(stored: stored, for: provider)
                    if healed != stored {
                        UserDefaults.standard.set(healed, forKey: provider.modelDefaultsKey)
                    }
                }
            }
        }
        .onChange(of: cloudKeys) { oldValue, newValue in
            // `oldValue[id] == nil` is the onAppear seeding pass — not a user
            // edit, so nothing may be written from it. (Read-failure protection
            // is handled separately below; both guards are load-bearing.)
            for provider in CloudProviders.all
            where oldValue[provider.id] != nil && oldValue[provider.id] != newValue[provider.id] {
                let value = newValue[provider.id] ?? ""
                guard KeychainStore.shouldPersist(
                    newValue: value,
                    readFailed: unreadableKeyProviders.contains(provider.id)) else { continue }
                if provider.keychain.save(value) {   // empty string deletes
                    unreadableKeyProviders.remove(provider.id)
                }
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
        guard stepState != "Processing" else { return }
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
        let preference = EnginePreference(raw: enginePreferenceRaw)
        let context = EngineContext(appleAvailable: appleEngineAvailable,
                                    cloudKeys: presentCloudKeys)
        let engine: AnalysisEngine
        switch resolveEngine(preference: preference, context: context) {
        case .cloud(let id):
            // Unreachable: the resolver only returns ids it found in the registry.
            guard let provider = CloudProviders.find(id) else {
                analysisError = "Unknown engine."
                stepState = "Idle"
                return
            }
            let model = CloudProviders.healedModel(
                stored: UserDefaults.standard.string(forKey: provider.modelDefaultsKey),
                for: provider)
            engine = provider.makeEngine(cloudKeys[id] ?? "", model)
        case .apple:
            guard #available(macOS 26.0, *) else {
                analysisError = "On-device analysis requires macOS 26 or newer."
                stepState = "Idle"
                return
            }
            engine = AppleAnalysisEngine()
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
                    // FIFO on the main queue — Task { @MainActor } would let
                    // out-of-order progress messages race each other.
                    DispatchQueue.main.async { progressText = message }
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
        guard stepState != "Processing" else { return }
        selectedMeetingID = nil
        playback.stop()
        analysisError = nil
        stepState = "Idle"
    }

    func syncToReminders() {
        guard let meeting = selectedMeeting, let analysis = meeting.analysis else { return }
        eventKit.createReminders(from: analysis.actionItems, listTitle: "\(meeting.title) Actions")
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

/// Observes the playback clock so 0.5s ticks re-render only this label,
/// not the whole window (same isolation pattern as AudioLevelVisualizer).
struct PlaybackTimeLabel: View {
    @ObservedObject var clock: AudioPlaybackManager.Clock
    let isActive: Bool          // this meeting is the one playing
    let fallback: TimeInterval  // meeting duration shown when not playing
    var body: some View {
        Text(MeetingRow.clock(isActive ? clock.currentTime : fallback))
            .monospacedDigit()
    }
}

/// One cloud provider's settings block: API key field plus model picker. The
/// model selection is stored per provider under its own defaults key, so adding
/// a registry row adds a section here with no other changes.
private struct CloudProviderSettingsSection: View {
    let provider: CloudProvider
    @Binding var apiKey: String
    @AppStorage private var selectedModel: String

    // Mirrors ContentView.borderDark (an instance property there, so not
    // reachable from this subview).
    private let borderDark = Color.white.opacity(0.08)

    init(provider: CloudProvider, apiKey: Binding<String>) {
        self.provider = provider
        self._apiKey = apiKey
        self._selectedModel = AppStorage(wrappedValue: provider.defaultModel,
                                         provider.modelDefaultsKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(provider.keyFieldLabel)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))

                SecureField(provider.keyPlaceholder, text: $apiKey)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderDark, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("\(provider.displayName) Model")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))

                Picker("", selection: $selectedModel) {
                    ForEach(provider.models, id: \.id) { model in
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
    }
}

/// One compact history row: status dot, title (inline-renamable), date · duration,
/// engine badge. Row-local rename state keeps ContentView untouched.
struct MeetingRow: View {
    let meeting: Meeting
    let isSelected: Bool
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onReanalyze: () -> Void
    let onDelete: () -> Void

    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFieldFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(meeting.analysis == nil ? Color.orange : Color.green)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .focused($renameFieldFocused)
                        .onSubmit {
                            isRenaming = false
                            onRename(draftTitle)
                        }
                        .onExitCommand {
                            // Reset the draft before dropping isRenaming so the
                            // onChange-driven commit below (which fires when
                            // focus resigns) sees the unchanged title — escape
                            // cancels instead of renaming.
                            draftTitle = meeting.title
                            isRenaming = false
                        }
                        .onChange(of: renameFieldFocused) {
                            if !renameFieldFocused && isRenaming {
                                // Clicking away from the field: commit instead
                                // of leaving it stuck in edit mode.
                                isRenaming = false
                                onRename(draftTitle)
                            }
                        }
                } else {
                    Text(meeting.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text("\(Self.dateFormatter.string(from: meeting.createdAt)) · \(Self.formatDuration(meeting.duration))")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer(minLength: 4)

            if let engine = meeting.engine {
                Text(CloudProviders.badgeLabel(engine: engine))
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.07))
                    .foregroundStyle(.white.opacity(0.6))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Rename") {
                draftTitle = meeting.title
                isRenaming = true
                renameFieldFocused = true
            }
            Button("Re-analyze") { onReanalyze() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    static func headerDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        formatDuration(seconds)
    }
}
