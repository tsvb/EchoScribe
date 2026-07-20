import Foundation
import AVFoundation
import Speech

/// Fully on-device analysis: SpeechTranscriber (macOS 26+) for the transcript,
/// FoundationModels for summary/actions/email (Task 10). No API key; audio
/// never leaves the machine. Limitation (per spec): no speaker diarization —
/// segments are attributed to "Speaker".
@available(macOS 26.0, *)
final class AppleAnalysisEngine: AnalysisEngine {
    let id = "apple"
    let modelName = "apple-on-device"

    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse {
        progress("Transcribing on device…")
        let transcript = try await Self.transcribe(url: audioURL, progress: progress)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalysisError(message: "No speech was detected in the recording.")
        }
        // Task 10 replaces this stub with FoundationModels summarization.
        throw AnalysisError(message: "On-device summarization not implemented yet.")
    }

    // MARK: - Transcription

    static func transcribe(url: URL,
                           progress: @escaping (String) -> Void) async throws -> String {
        let locale = try await pickLocale()
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])

        // One-time locale model download into system storage.
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            progress("Downloading on-device speech model…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            // nil request means assets are already installed — treat as success.
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Consume results while the file is analyzed.
        async let collected: String = transcriber.results.reduce(into: "") { acc, result in
            acc += String(result.text.characters)
            acc += "\n"
        }

        let audioFile = try AVAudioFile(forReading: url)
        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await collected
    }

    /// Current locale if the transcriber supports it, else en_US, else error.
    private static func pickLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let match = supported.first(where: {
            $0.identifier(.bcp47) == current.identifier(.bcp47)
        }) { return match }
        if let english = supported.first(where: { $0.identifier(.bcp47) == "en-US" }) {
            return english
        }
        throw AnalysisError(message:
            "On-device transcription doesn't support this language. Switch the analysis engine to Gemini in Settings.")
    }

    // MARK: - Segmentation (no diarization — group into readable turns)

    static func transcriptSegments(from text: String) -> [TranscriptSegment] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var segments: [TranscriptSegment] = []
        var current = ""
        for paragraph in paragraphs {
            // Split oversized paragraphs into ≤500-char pieces
            let pieces = splitOversizedParagraph(paragraph, maxLength: 500)

            for piece in pieces {
                let candidate = current.isEmpty ? piece : current + " " + piece
                if candidate.count <= 500 {
                    current = candidate
                } else {
                    if !current.isEmpty {
                        segments.append(TranscriptSegment(speaker: "Speaker", text: current))
                    }
                    current = piece
                }
            }
        }
        if !current.isEmpty {
            segments.append(TranscriptSegment(speaker: "Speaker", text: current))
        }
        return segments
    }

    /// Split a paragraph into pieces of at most `maxLength` characters,
    /// cutting at word boundaries when possible.
    private static func splitOversizedParagraph(_ paragraph: String, maxLength: Int) -> [String] {
        guard paragraph.count > maxLength else { return [paragraph] }

        var pieces: [String] = []
        var remaining = paragraph

        while remaining.count > maxLength {
            // Find the last space within the first maxLength characters
            let prefix = String(remaining.prefix(maxLength))
            if let lastSpaceIndex = prefix.lastIndex(of: " ") {
                let piece = String(prefix[..<lastSpaceIndex]).trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty {
                    pieces.append(piece)
                }
                remaining = String(remaining[prefix.index(after: lastSpaceIndex)...]).trimmingCharacters(in: .whitespaces)
            } else {
                // No space found; hard-cut at maxLength
                pieces.append(prefix)
                remaining = String(remaining.dropFirst(maxLength)).trimmingCharacters(in: .whitespaces)
            }
        }

        if !remaining.isEmpty {
            pieces.append(remaining)
        }

        return pieces.filter { !$0.isEmpty }
    }
}
