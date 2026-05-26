import Foundation
import Speech
import Combine

class SpeechTranscriptionManager: ObservableObject {
    @Published var isTranscribing = false
    @Published var transcriptionResult = ""
    @Published var permissionGranted = false
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.permissionGranted = true
                    completion(true)
                default:
                    self.permissionGranted = false
                    completion(false)
                }
            }
        }
    }
    
    func transcribeAudioFile(url: URL, completion: @escaping (String?) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            print("Speech recognizer is not available on this locale.")
            completion(nil)
            return
        }
        
        isTranscribing = true
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.isTranscribing = false
                if let error = error {
                    print("Speech transcription error: \(error.localizedDescription)")
                    completion(nil)
                    return
                }
                
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    self?.transcriptionResult = text
                    completion(text)
                } else {
                    completion(nil)
                }
            }
        }
    }
}
