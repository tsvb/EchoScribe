import Foundation

struct AnalysisError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Seam between the app and whatever produces a MeetingAnalysisResponse.
/// Implementations: GeminiEngine (cloud, optional key), AppleAnalysisEngine
/// (on-device, macOS 26+, added in Phase 2).
protocol AnalysisEngine {
    var id: String { get }          // "apple" | "gemini" — stored on Meeting.engine
    var modelName: String { get }   // stored on Meeting.model
    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse
}

// MARK: - Engine selection (pure, unit-tested)

enum EnginePreference: String {
    case auto, apple, gemini
}

struct EngineContext {
    let appleAvailable: Bool
    let hasGeminiKey: Bool
}

enum EngineChoice: Equatable {
    case apple
    case gemini
    case none(reason: String)
}

func resolveEngine(preference: EnginePreference, context: EngineContext) -> EngineChoice {
    switch preference {
    case .apple:
        return context.appleAvailable ? .apple : .none(reason:
            "Apple Intelligence isn't available on this Mac. Enable it in System Settings, or switch the analysis engine to Gemini.")
    case .gemini:
        return context.hasGeminiKey ? .gemini : .none(reason:
            "No Gemini API key configured. Add one in Settings, or switch the analysis engine to Apple (on-device).")
    case .auto:
        if context.appleAvailable { return .apple }
        if context.hasGeminiKey { return .gemini }
        return .none(reason:
            "No analysis engine available. Enable Apple Intelligence for on-device analysis, or add a Gemini API key in Settings.")
    }
}

// MARK: - Gemini engine (adapter over the existing client)

final class GeminiEngine: AnalysisEngine {
    let id = "gemini"
    var modelName: String { model }

    private let client: GeminiClient
    private let apiKey: String
    private let model: String

    init(client: GeminiClient, apiKey: String, model: String) {
        self.client = client
        self.apiKey = apiKey
        self.model = model
    }

    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse {
        guard !apiKey.isEmpty else {
            throw AnalysisError(message: "No Gemini API key configured. Add one in Settings.")
        }
        progress("Encoding audio for Gemini…")
        let audioData = try Data(contentsOf: audioURL)   // background: analyze() runs off-main
        progress("Sending multimodal payload to Gemini…")
        return try await withCheckedThrowingContinuation { continuation in
            client.requestAnalysis(audioData: audioData, mimeType: "audio/mp4",
                                   apiKey: apiKey, model: model,
                                   title: title, participants: participants) { result in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    // Completion runs on the main queue after client.error is set.
                    continuation.resume(throwing: AnalysisError(
                        message: self.client.error ?? "Gemini analysis failed."))
                }
            }
        }
    }
}
