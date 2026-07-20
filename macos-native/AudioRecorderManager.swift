import Foundation
import AVFoundation
import Combine

class AudioRecorderManager: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsedSeconds: TimeInterval = 0

    /// Emits the latest metering power (dBFS) ~10×/sec while recording. Kept as a
    /// plain closure (not @Published) so these high-frequency updates don't force
    /// every observer of this manager to re-render — the visualizer subscribes via
    /// AudioLevelMonitor instead.
    var onAudioLevel: ((Float) -> Void)?

    private var audioRecorder: AVAudioRecorder?
    private var timer: AnyCancellable?
    private var levelTimer: AnyCancellable?
    private var recordedURL: URL?
    
    func startRecording() {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error.localizedDescription)")
            return
        }
        #endif
        
        // Unique temp file per session — MeetingStore takes ownership on stop.
        // (The old fixed ~/Documents path silently overwrote every prior recording.)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoScribe-\(UUID().uuidString).m4a")
        self.recordedURL = audioURL
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            isRecording = true
            isPaused = false
            elapsedSeconds = 0
            
            startTimers()
        } catch {
            print("Failed to initialize AVAudioRecorder: \(error.localizedDescription)")
        }
    }
    
    func pauseRecording() {
        guard isRecording, let recorder = audioRecorder else { return }
        if recorder.isRecording {
            recorder.pause()
            isPaused = true
        } else {
            recorder.record()
            isPaused = false
        }
    }
    
    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isRecording else {
            completion(nil)
            return
        }
        
        audioRecorder?.stop()
        stopTimers()
        
        isRecording = false
        isPaused = false
        
        #if os(iOS)
        // Clean up audio session
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        
        completion(recordedURL)
    }
    
    private func startTimers() {
        // Recording duration timer
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, !self.isPaused else { return }
                self.elapsedSeconds += 1
            }
        
        // Visualizer level metering timer
        levelTimer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self, let recorder = self.audioRecorder, self.isRecording && !self.isPaused else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)

                // Forward the level to whoever is listening (the visualizer's
                // AudioLevelMonitor) instead of mutating a @Published property here.
                self.onAudioLevel?(power)
            }
    }
    
    private func stopTimers() {
        timer?.cancel()
        levelTimer?.cancel()
        timer = nil
        levelTimer = nil
    }
}

/// Owns the rolling window of audio metering levels for the live visualizer.
/// The recording UI's visualizer is the only observer, so the ~10 Hz updates
/// here re-render just those bars rather than the whole window.
final class AudioLevelMonitor: ObservableObject {
    @Published private(set) var levels: [Float]

    init(barCount: Int = 20) {
        self.levels = Array(repeating: -160.0, count: barCount)
    }

    /// Shift in the newest metering sample, dropping the oldest.
    func append(_ power: Float) {
        levels.removeFirst()
        levels.append(power)
    }
}
