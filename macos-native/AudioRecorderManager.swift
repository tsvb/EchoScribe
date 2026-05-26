import Foundation
import AVFoundation
import Combine

class AudioRecorderManager: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var audioLevels: [Float] = Array(repeating: -160.0, count: 20)
    @Published var elapsedSeconds: TimeInterval = 0
    
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
        
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioURL = documentDirectory.appendingPathComponent("EchoScribe_Record.m4a")
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
                
                // Shift levels array and push new value
                self.audioLevels.removeFirst()
                self.audioLevels.append(power)
            }
    }
    
    private func stopTimers() {
        timer?.cancel()
        levelTimer?.cancel()
        timer = nil
        levelTimer = nil
    }
}
