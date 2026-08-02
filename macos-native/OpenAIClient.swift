import Foundation

/// Stateless client for the OpenAI Audio Transcription + Chat Completions APIs.
/// Mirrors GeminiClient's error-mapping style but is async-first: pure,
/// unit-tested request builders/decoders/error-mapping, plus a thin
/// (untested, same trust level as Gemini's dataTask) transport layer.
enum OpenAIClient {

    // MARK: - Decodable payloads

    /// OpenAI's standard error envelope: {"error":{"message","type","param","code"}}
    struct APIError: Decodable {
        struct Payload: Decodable {
            let message: String
            let type: String?
            let param: String?
            let code: String?
        }
        let error: Payload
    }

    /// One entry from the `segments` array of a diarized_json transcription
    /// response. `start`/`end` and any other keys are ignored (default
    /// Decodable behavior — only declared properties are decoded).
    struct DiarizedSegment: Decodable, Equatable {
        let speaker: String
        let text: String
    }

    /// A label→name mapping returned by the chat step's speaker_names array.
    struct SpeakerName: Decodable, Equatable {
        let label: String
        let name: String
    }

    /// The structured chat-completion payload (everything except the
    /// transcript, which is kept verbatim locally and relabelled).
    struct ChatAnalysisPayload: Decodable {
        let summary: String
        let sentiment: String
        let actionItems: [String]
        let followUpEmail: FollowUpEmail
        let speakerNames: [SpeakerName]

        enum CodingKeys: String, CodingKey {
            case summary, sentiment
            case actionItems = "action_items"
            case followUpEmail = "follow_up_email"
            case speakerNames = "speaker_names"
        }
    }

    /// Fixed transcription model — this client only ever calls the diarizing
    /// transcription endpoint with this model. Internal (not private) so
    /// OpenAIEngine.transcriptionModel can reference this as the single
    /// source of truth for the value the engine layer reports as
    /// progress/model metadata.
    static let transcriptionModel = "gpt-4o-transcribe-diarize"

    // MARK: - Request builders (pure, unit-tested)

    static func transcriptionRequest(audioData: Data, apiKey: String, boundary: String = "echoscribe-\(UUID().uuidString)") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField(name: "model", value: transcriptionModel)
        appendField(name: "response_format", value: "diarized_json")
        appendField(name: "chunking_strategy", value: "auto")

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".utf8))
        body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))

        body.append(Data("--\(boundary)--\r\n".utf8))

        request.httpBody = body
        return request
    }

    static func chatRequest(segments: [DiarizedSegment], title: String, participants: [String], model: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let callTeam = participants.isEmpty ? "Speakers on call" : participants.joined(separator: ", ")
        let transcriptText = segments.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")

        let systemPrompt = "You are a premium corporate executive meeting assistant."
        let userPrompt = """
        You have been provided with the diarized transcript of a meeting titled "\(title)".
        The listed participants on the call are: [\(callTeam)].

        Here is the transcript. Speakers are labelled by diarization tags (A, B, C, …):
        \(transcriptText)

        Please complete the following tasks:
        1. DETAILED SUMMARY: Generate an elegant executive summary. Start with a list of major takeaways. Extract key details, discussions, decisions, and overall meeting mood/sentiment (collaborative, urgent, alignment, brainstorm).
        2. SENTIMENT: Capture the overall meeting sentiment in a short phrase.
        3. ACTION CHECKLIST: Compile all action items. Assign a clear owner to each item (from the participant list [\(callTeam)] where possible).
        4. FOLLOW-UP EMAIL DRAFT: Draft a highly professional follow-up email. The subject must be compelling and the body structured. The email must synthesize the meeting discussions, gratitude, and next steps.
        5. SPEAKER IDENTIFICATION: The diarized transcript labels speakers A, B, …. Map each label to a participant name using context (self-introductions, direct address, role cues). Only include labels you can map confidently.

        Return the response strictly in JSON format matching the schema requested. Do NOT wrap the JSON in Markdown block ticks like ```json. Return pure JSON.
        """

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["summary", "sentiment", "action_items", "follow_up_email", "speaker_names"],
            "properties": [
                "summary": ["type": "string"],
                "sentiment": ["type": "string"],
                "action_items": [
                    "type": "array",
                    "items": ["type": "string"],
                ],
                "follow_up_email": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["subject", "body"],
                    "properties": [
                        "subject": ["type": "string"],
                        "body": ["type": "string"],
                    ],
                ],
                "speaker_names": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["label", "name"],
                        "properties": [
                            "label": ["type": "string"],
                            "name": ["type": "string"],
                        ],
                    ],
                ],
            ],
        ]

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "meeting_analysis",
                    "strict": true,
                    "schema": schema,
                ],
            ],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        return request
    }

    // MARK: - Decoders (pure, unit-tested)

    static func decodeTranscription(_ data: Data) throws -> [DiarizedSegment] {
        struct Envelope: Decodable { let segments: [DiarizedSegment] }
        return try JSONDecoder().decode(Envelope.self, from: data).segments
    }

    static func decodeChatPayload(_ data: Data) throws -> ChatAnalysisPayload {
        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let content = (try? JSONDecoder().decode(Envelope.self, from: data))?.choices.first?.message.content else {
            throw AnalysisError(message: "Unexpected response structure from OpenAI API")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try JSONDecoder().decode(ChatAnalysisPayload.self, from: Data(trimmed.utf8))
        } catch {
            throw AnalysisError(message: "OpenAI returned analysis JSON that couldn't be decoded: \(error.localizedDescription)")
        }
    }

    // MARK: - Error mapping (pure, unit-tested)

    /// Maps a non-200 OpenAI API response to an actionable, user-facing
    /// message. (Error shapes verified against developers.openai.com, August 2026.)
    /// Order matters: insufficient_quota errors arrive with HTTP 429, so the
    /// quota check MUST run before the generic 429 (rate limit) check.
    static func userFacingError(statusCode: Int, body: Data, model: String) -> String {
        let payload = (try? JSONDecoder().decode(APIError.self, from: body))?.error

        if payload?.code == "invalid_api_key" || statusCode == 401 {
            return "OpenAI rejected the API key. Check that it was pasted completely, or create a new key at platform.openai.com/api-keys — keys start with \"sk-\" or \"sk-proj-\"."
        }
        // Quota exhaustion arrives as HTTP 429 like plain rate limiting, but the
        // envelope differs: legacy responses put insufficient_quota in `code`;
        // current docs (Aug 2026) keep it in `type` and use specific billing
        // codes for the cause.
        let billingCodes: Set<String> = [
            "insufficient_quota", "credit_balance_exhausted",
            "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
            "organization_usage_limit_exceeded",
        ]
        if payload?.type == "insufficient_quota" || billingCodes.contains(payload?.code ?? "") {
            return "This OpenAI account is out of quota (\(payload?.code ?? "insufficient_quota")). Check billing and spend limits at platform.openai.com, or switch engines in Settings."
        }
        if statusCode == 404 || payload?.code == "model_not_found" {
            if model == transcriptionModel {
                return "The transcription model \"\(transcriptionModel)\" is no longer available — OpenAI has retired it. Update EchoScribe to a newer version, or switch the analysis engine in Settings."
            }
            return "The model \"\(model)\" is no longer available — OpenAI has retired it. Choose a newer model in Settings."
        }
        if statusCode == 403 {
            return "This API key doesn't have access to \"\(model)\". Check the project's model permissions at platform.openai.com."
        }
        if statusCode == 429 {
            return "Rate limit reached for this OpenAI key. Wait a minute and retry, or switch to a lighter model in Settings."
        }
        if let message = payload?.message, !message.isEmpty {
            return "OpenAI API error (HTTP \(statusCode)): \(message)"
        }
        let raw = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "OpenAI API error (HTTP \(statusCode))." + (raw.isEmpty ? "" : " \(raw.prefix(200))")
    }

    // MARK: - Transport (thin, NOT unit-tested — same trust level as Gemini's dataTask)

    static func perform(_ request: URLRequest, model: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AnalysisError(message: "Network error: \(error.localizedDescription)")
        }
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw AnalysisError(message: userFacingError(statusCode: httpResponse.statusCode, body: data, model: model))
        }
        return data
    }
}
