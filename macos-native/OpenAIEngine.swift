import Foundation

/// AnalysisEngine adapter for OpenAI: audio transcription with diarization
/// (gpt-4o-transcribe-diarize) followed by a structured chat-completion pass
/// that maps diarization labels to participant names and produces the
/// summary/sentiment/action items/follow-up email.
final class OpenAIEngine: AnalysisEngine {
    let id = "openai"
    var modelName: String { chatModel }

    static let transcriptionModel = "gpt-4o-transcribe-diarize"
    static let maxUploadBytes = 25 * 1024 * 1024

    private let apiKey: String
    private let chatModel: String

    init(apiKey: String, chatModel: String) {
        self.apiKey = apiKey
        self.chatModel = chatModel
    }

    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse {
        guard !apiKey.isEmpty else {
            throw AnalysisError(message: "No OpenAI API key configured. Add one in Settings.")
        }

        progress("Preparing audio for OpenAI…")
        let audioData = try Data(contentsOf: audioURL)   // background: analyze() runs off-main
        if let oversize = Self.oversizeMessage(bytes: audioData.count) {
            throw AnalysisError(message: oversize)
        }

        progress("Transcribing with speaker diarization…")
        let transcriptionRequest = OpenAIClient.transcriptionRequest(audioData: audioData, apiKey: apiKey)
        let transcriptionData = try await OpenAIClient.perform(transcriptionRequest, model: Self.transcriptionModel)
        let segments = try OpenAIClient.decodeTranscription(transcriptionData)
        guard !segments.isEmpty else {
            throw AnalysisError(message: "No speech was detected in the recording.")
        }

        progress("Analyzing transcript with \(chatModel)…")
        let chatRequest = try OpenAIClient.chatRequest(segments: segments, title: title, participants: participants,
                                                        model: chatModel, apiKey: apiKey)
        let chatData = try await OpenAIClient.perform(chatRequest, model: chatModel)
        let payload = try OpenAIClient.decodeChatPayload(chatData)

        return MeetingAnalysisResponse(
            transcript: Self.resolvedTranscript(segments: segments, names: payload.speakerNames),
            summary: payload.summary,
            sentiment: payload.sentiment,
            actionItems: payload.actionItems,
            followUpEmail: payload.followUpEmail
        )
    }

    /// nil when `bytes` is within OpenAI's transcription upload limit.
    static func oversizeMessage(bytes: Int) -> String? {
        guard bytes > maxUploadBytes else { return nil }
        let megabytes = Int((Double(bytes) / 1_048_576).rounded())
        return "This recording is \(megabytes) MB — OpenAI's transcription API accepts files up to 25 MB (roughly two hours at EchoScribe's recording quality). Use the Apple or Gemini engine for this meeting."
    }

    /// Relabels the verbatim diarized transcript using the chat step's
    /// label→name mapping, then merges consecutive same-speaker segments.
    static func resolvedTranscript(segments: [OpenAIClient.DiarizedSegment],
                                    names: [OpenAIClient.SpeakerName]) -> [TranscriptSegment] {
        // On a duplicate label, the last entry in `names` wins — a plain
        // assignment loop overwrites earlier entries as later ones are seen.
        var labelToName: [String: String] = [:]
        for entry in names {
            labelToName[entry.label] = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func resolvedSpeaker(for label: String) -> String {
            guard let name = labelToName[label], !name.isEmpty,
                  name.caseInsensitiveCompare(label) != .orderedSame else {
                return "Speaker \(label)"
            }
            return name
        }

        var result: [TranscriptSegment] = []
        for segment in segments {
            let speaker = resolvedSpeaker(for: segment.speaker)
            if let last = result.last, last.speaker == speaker {
                result[result.count - 1] = TranscriptSegment(speaker: speaker, text: last.text + " " + segment.text)
            } else {
                result.append(TranscriptSegment(speaker: speaker, text: segment.text))
            }
        }
        return result
    }
}
