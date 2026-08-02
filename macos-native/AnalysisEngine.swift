import Foundation

struct AnalysisError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Analysis payload (shared by every engine)

struct MeetingAnalysisResponse: Codable {
    let transcript: [TranscriptSegment]
    let summary: String
    let sentiment: String
    let actionItems: [String]
    let followUpEmail: FollowUpEmail

    enum CodingKeys: String, CodingKey {
        case transcript
        case summary
        case sentiment
        case actionItems = "action_items"
        case followUpEmail = "follow_up_email"
    }
}

struct TranscriptSegment: Codable, Identifiable {
    // Stored once per instance. A computed `UUID()` returns a brand-new id on
    // every access, which breaks SwiftUI list identity/diffing.
    let id = UUID()
    let speaker: String
    let text: String

    // `id` is generated locally and isn't part of the Gemini JSON payload,
    // so keep it out of the coding keys (otherwise decoding would look for it).
    enum CodingKeys: String, CodingKey {
        case speaker, text
    }
}

struct FollowUpEmail: Codable {
    let subject: String
    let body: String
}

/// Seam between the app and whatever produces a MeetingAnalysisResponse.
/// Implementations: GeminiEngine (cloud, optional key), AppleAnalysisEngine
/// (on-device, macOS 26+, added in Phase 2).
protocol AnalysisEngine {
    var id: String { get }          // "apple" | "gemini" | "openai" — stored on Meeting.engine
    var modelName: String { get }   // stored on Meeting.model
    func analyze(audioURL: URL, title: String, participants: [String],
                 progress: @escaping (String) -> Void) async throws -> MeetingAnalysisResponse
}

// MARK: - Engine selection (pure, unit-tested)

/// Stored raw preference: "auto" | "apple" | a cloud provider id.
enum EnginePreference: Equatable {
    case auto, apple, cloud(id: String)

    init(raw: String) {
        switch raw {
        case "auto": self = .auto
        case "apple": self = .apple
        default: self = .cloud(id: raw)      // "gemini", "openai", future ids
        }
    }
}

struct EngineContext {
    let appleAvailable: Bool
    let cloudKeys: Set<String>               // provider ids with a non-empty key
}

enum EngineChoice: Equatable {
    case apple
    case cloud(String)
    case none(reason: String)
}

func resolveEngine(preference: EnginePreference, context: EngineContext,
                   providers: [CloudProvider] = CloudProviders.all) -> EngineChoice {
    let providerNames = providers.map(\.displayName).joined(separator: " or ")

    // Shared by `.auto` and by any preference naming a provider we no longer
    // ship — a stale pref self-heals instead of dead-ending on an unknown id.
    func automatic() -> EngineChoice {
        if context.appleAvailable { return .apple }
        if let ready = providers.first(where: { context.cloudKeys.contains($0.id) }) {
            return .cloud(ready.id)
        }
        return .none(reason:
            "No analysis engine available. Enable Apple Intelligence for on-device analysis, or add a \(providerNames) API key in Settings.")
    }

    switch preference {
    case .apple:
        return context.appleAvailable ? .apple : .none(reason:
            "Apple Intelligence isn't available on this Mac. Enable it in System Settings, or switch the analysis engine to \(providerNames).")
    case .cloud(let id):
        guard let provider = providers.first(where: { $0.id == id }) else { return automatic() }
        return context.cloudKeys.contains(id) ? .cloud(id) : .none(reason:
            "No \(provider.displayName) API key configured. Add one in Settings, or switch the analysis engine to Apple (on-device).")
    case .auto:
        return automatic()
    }
}

// MARK: - Cloud provider registry

/// Everything the app needs to know about one cloud engine: selection,
/// settings UI, credential storage, and how to build the engine itself.
/// Adding a provider means adding a row here — nothing in ContentView changes.
struct CloudProvider: Identifiable {
    let id: String                        // "gemini" | "openai" — engine id, pref raw, Meeting.engine
    let displayName: String               // "Gemini" / "OpenAI" — badge + messages
    let engineOptionLabel: String         // settings engine-picker row
    let keyPlaceholder: String
    let keychain: KeychainStore
    let modelDefaultsKey: String          // "gemini_selected_model" / "openai_selected_model"
    let defaultModel: String
    let models: [(id: String, label: String)]
    let makeEngine: (_ apiKey: String, _ model: String) -> AnalysisEngine

    var keyFieldLabel: String { "\(displayName) API Key (optional)" }
}

enum CloudProviders {
    /// Registry order doubles as the "auto" preference order: Gemini stays
    /// first so existing users' auto behavior is unchanged.
    static let all: [CloudProvider] = [gemini, openai]

    static let gemini = CloudProvider(
        id: "gemini",
        displayName: "Gemini",
        engineOptionLabel: "Gemini cloud (best quality, speaker names)",
        keyPlaceholder: "AQ.… (from aistudio.google.com/apikey)",
        keychain: .geminiAPIKey,
        modelDefaultsKey: "gemini_selected_model",
        // Live Gemini models as of July 2026. Google retires model IDs regularly
        // (1.5: Sept 2025, 2.0: June 2026) — when it happens again, the API's 404
        // is surfaced in the UI and points the user here.
        defaultModel: "gemini-3.5-flash",
        models: [
            ("gemini-3.5-flash", "Gemini 3.5 Flash (recommended)"),
            ("gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite (fastest)"),
            ("gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview — paid key required)"),
        ],
        makeEngine: { GeminiEngine(client: GeminiClient(), apiKey: $0, model: $1) }
    )

    static let openai = CloudProvider(
        id: "openai",
        displayName: "OpenAI",
        engineOptionLabel: "OpenAI cloud (true speaker diarization)",
        keyPlaceholder: "sk-… (from platform.openai.com/api-keys)",
        keychain: .openaiAPIKey,
        modelDefaultsKey: "openai_selected_model",
        // OpenAI retires chat model ids just as regularly (gpt-4o, 4.1, 5 and
        // 5.1 are all gone as of this list's verification, Aug 2026). A stored
        // id that disappears from this list is healed back to the default.
        defaultModel: "gpt-5.6-terra",
        models: [
            ("gpt-5.6-terra", "GPT-5.6 Terra (recommended)"),
            ("gpt-5.6-sol", "GPT-5.6 Sol (highest quality)"),
            ("gpt-5.6-luna", "GPT-5.6 Luna (fastest, cheapest)"),
        ],
        makeEngine: { OpenAIEngine(apiKey: $0, chatModel: $1) }
    )

    static func find(_ id: String?) -> CloudProvider? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// History-row badge for a stored `Meeting.engine`. Unknown ids echo through
    /// rather than being mislabelled as one particular provider.
    static func badgeLabel(engine: String) -> String {
        engine == "apple" ? "On-device" : (find(engine)?.displayName ?? engine)
    }

    /// Only the cloud engines attribute dialogue to speakers.
    static func transcriptHeader(engine: String?) -> String {
        find(engine) == nil ? "Transcript" : "Speaker-Attributed Dialogue"
    }

    /// Replaces a stored model id the provider has since retired — otherwise
    /// every analysis fails against a model that no longer exists.
    static func healedModel(stored: String?, for provider: CloudProvider) -> String {
        guard let stored, provider.models.contains(where: { $0.id == stored }) else {
            return provider.defaultModel
        }
        return stored
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
