import Foundation
import AVFoundation
import Speech
import FoundationModels

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
        progress("Summarizing on device…")
        let notes = try await Self.summarize(transcript: transcript, title: title,
                                             participants: participants, progress: progress)
        return MeetingAnalysisResponse(
            transcript: Self.transcriptSegments(from: transcript),
            summary: notes.summary,
            sentiment: notes.sentiment,
            actionItems: notes.actionItems,
            followUpEmail: FollowUpEmail(subject: notes.emailSubject, body: notes.emailBody)
        )
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
        if !installed.contains(where: {
            $0.identifier(.bcp47).lowercased() == locale.identifier(.bcp47).lowercased()
        }) {
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
        // Make sure the analyzer is always finished, even if analyzeSequence
        // throws partway through — otherwise it's left dangling.
        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        return try await collected
    }

    /// Current locale if the transcriber supports it, else en_US, else error.
    private static func pickLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let match = supported.first(where: {
            $0.identifier(.bcp47).lowercased() == current.identifier(.bcp47).lowercased()
        }) { return match }
        if let english = supported.first(where: { $0.identifier(.bcp47).lowercased() == "en-us" }) {
            return english
        }
        throw AnalysisError(message:
            "On-device transcription doesn't support this language. Switch the analysis engine to \(CloudProviders.displayNameList) in Settings.")
    }

    // MARK: - Summarization (FoundationModels, TN3193 map-reduce)

    @Generable
    struct MeetingNotes {
        @Guide(description: "Executive summary of the meeting, 3-6 sentences, leading with the major takeaways")
        var summary: String
        @Guide(description: "Overall meeting mood as one lowercase word, e.g. collaborative, urgent, alignment, brainstorm")
        var sentiment: String
        @Guide(description: "Every action item, each starting with the owner's name when one is identifiable")
        var actionItems: [String]
        @Guide(description: "Compelling subject line for a professional follow-up email")
        var emailSubject: String
        @Guide(description: "Body of a professional follow-up email synthesizing the discussion, gratitude, and next steps")
        var emailBody: String
    }

    static func summarize(transcript: String, title: String, participants: [String],
                          progress: @escaping (String) -> Void) async throws -> MeetingNotes {
        guard SystemLanguageModel.default.isAvailable else {
            throw AnalysisError(message:
                "Apple Intelligence isn't available. Enable it in System Settings, or switch the analysis engine to \(CloudProviders.displayNameList).")
        }
        // Spec §6: on context-window overflow, retry once at a smaller budget
        // (TN3193). withBudgetRetry has no notion of progress reporting, so
        // isRetryable is the seam: it emits the "retrying" message as a side
        // effect before signalling that a smaller budget should be tried.
        return try await withBudgetRetry(budgets: [2500, 1200], isRetryable: { error in
            guard case LanguageModelSession.GenerationError.exceededContextWindowSize = error else {
                return false
            }
            progress("Transcript too dense — retrying with smaller segments…")
            return true
        }) { budget in
            try await summarizePass(transcript: transcript, title: title,
                                    participants: participants, budget: budget,
                                    progress: progress)
        }
    }

    private static func summarizePass(transcript: String, title: String,
                                      participants: [String], budget: Int,
                                      progress: @escaping (String) -> Void) async throws -> MeetingNotes {
        let who = participants.isEmpty ? "unknown" : participants.joined(separator: ", ")
        // 2,500-token chunks leave headroom for instructions + output in the
        // 4,096-token on-device window (TN3193); the overflow retry halves that.
        let chunker = TranscriptChunker(counter: EstimatedTokenCounter(), budget: budget)
        let chunks = chunker.chunk(transcript)

        // Map: per-chunk notes in fresh sessions.
        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            if chunks.count > 1 {
                progress("Summarizing part \(index + 1)/\(chunks.count) on device…")
            }
            let session = LanguageModelSession(instructions:
                "You summarize one segment of a meeting transcript. Preserve decisions, owners, deadlines, action items, and the mood. Be concise.")
            let response = try await session.respond(to:
                "Meeting: \(title)\nParticipants: \(who)\n\nTranscript segment:\n\(chunk)")
            partials.append(response.content)
        }

        // Reduce: final structured notes.
        progress("Compiling meeting notes on device…")
        let reduceSession = LanguageModelSession(instructions:
            "You write final meeting notes from segment summaries of a single meeting. Attribute action items to participants when possible.")
        let combined = partials.joined(separator: "\n---\n")
        let final = try await reduceSession.respond(
            to: "Meeting: \(title)\nParticipants: \(who)\n\nSegment notes:\n\(combined)",
            generating: MeetingNotes.self)
        return final.content
    }

    // MARK: - Segmentation (no diarization — group into readable turns)

    static func transcriptSegments(from text: String) -> [TranscriptSegment] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
            // Find the last space within the first maxLength characters, using
            // indices computed directly on `remaining` — not on a separately
            // copied prefix String, whose indices aren't a documented-safe
            // way to subscript back into `remaining`.
            let cutoff = remaining.index(remaining.startIndex, offsetBy: maxLength)
            if let lastSpaceIndex = remaining[..<cutoff].lastIndex(of: " ") {
                let piece = String(remaining[..<lastSpaceIndex]).trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty {
                    pieces.append(piece)
                }
                remaining = String(remaining[remaining.index(after: lastSpaceIndex)...]).trimmingCharacters(in: .whitespaces)
            } else {
                // No space found; hard-cut at maxLength
                pieces.append(String(remaining[..<cutoff]))
                remaining = String(remaining[cutoff...]).trimmingCharacters(in: .whitespaces)
            }
        }

        if !remaining.isEmpty {
            pieces.append(remaining)
        }

        return pieces.filter { !$0.isEmpty }
    }
}
