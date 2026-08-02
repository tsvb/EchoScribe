import Foundation
import Combine

class GeminiClient: ObservableObject {
    @Published var isProcessing = false
    @Published var error: String?
    @Published var result: MeetingAnalysisResponse?

    /// Standard Google API error envelope, e.g.
    /// {"error": {"code": 400, "message": "...", "status": "INVALID_ARGUMENT",
    ///            "details": [{"@type": "...ErrorInfo", "reason": "API_KEY_INVALID", ...}]}}
    private struct GoogleAPIError: Decodable {
        struct Payload: Decodable {
            struct Detail: Decodable { let reason: String? }
            let code: Int
            let message: String
            let status: String?
            let details: [Detail]?
        }
        let error: Payload
    }

    /// Maps a non-200 Gemini API response to an actionable, user-facing message.
    /// (Error shapes verified against Google docs/forum reports, July 2026.)
    static func userFacingError(statusCode: Int, body: Data, model: String) -> String {
        let payload = (try? JSONDecoder().decode(GoogleAPIError.self, from: body))?.error
        let reasons = payload?.details?.compactMap(\.reason) ?? []

        if reasons.contains("API_KEY_INVALID") {
            return "Google rejected the API key (\"API key not valid\"). Check that it was pasted completely, or create a new key at aistudio.google.com/apikey — current keys start with \"AQ.\" and that format is correct."
        }

        switch statusCode {
        case 401:
            return "Google could not authenticate this API key. Try a freshly created key from aistudio.google.com/apikey. (Google has acknowledged issues with some \"AQ.\" keys on this endpoint — if a fresh key still fails, that is likely the cause.)"
        case 403:
            return "This API key doesn't have permission for the Gemini API, or was blocked after being reported as leaked. Create a new key at aistudio.google.com/apikey."
        case 404:
            return "The model \"\(model)\" is no longer available — Google has retired it. Choose a newer model in Settings."
        case 429:
            return "Rate limit reached for this API key (free-tier quota). Wait a minute and retry, or switch to a lighter model in Settings."
        default:
            if let message = payload?.message, !message.isEmpty {
                return "Gemini API error (HTTP \(statusCode)): \(message)"
            }
            let raw = String(data: body, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "Gemini API error (HTTP \(statusCode))." + (raw.isEmpty ? "" : " \(raw.prefix(200))")
        }
    }
    
    func requestAnalysis(audioData: Data, mimeType: String, apiKey: String, model: String, title: String, participants: [String], completion: @escaping (MeetingAnalysisResponse?) -> Void) {
        isProcessing = true
        error = nil
        
        let base64Audio = audioData.base64EncodedString()
        let callTeam = participants.isEmpty ? "Speakers on call" : participants.joined(separator: ", ")
        
        let promptText = """
        You are a premium corporate executive meeting assistant.
        You have been provided with the raw audio of a meeting titled "\(title)".
        The listed participants on the call are: [\(callTeam)].
        
        Please complete the following actions:
        1. SPEAKER-ATTRIBUTED DIALOGUE TRANSCRIPT: Transcribe the audio word-for-word. Group consecutive dialogue turns. Analyze the raw audio's vocal frequencies, conversation flow, and semantic context to attribute each part to the correct speaker from the list of participants: [\(callTeam)]. If multiple speakers are detected but can't be mapped directly, label them as "Speaker A", "Speaker B", etc. or use context to match their names.
        2. DETAILED SUMMARY: Generate an elegant executive summary. Start with a list of major takeaways. Extract key details, discussions, decisions, and overall meeting mood/sentiment (collaborative, urgent, alignment, brainstorm).
        3. ACTION CHECKLIST: Compile all action items. Assign a clear owner to each item (from the participant list [\(callTeam)] where possible).
        4. FOLLOW-UP EMAIL DRAFT: Draft a highly professional follow-up email. The subject must be compelling and the body structured. The email must synthesize the meeting discussions, gratitude, and next steps.
        
        Return the response strictly in JSON format matching the schema requested below. Do NOT wrap the JSON in Markdown block ticks like ```json. Return pure JSON.
        """
        
        // Define Gemini Structured JSON Request Schema
        let requestSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "transcript": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "speaker": ["type": "STRING"],
                            "text": ["type": "STRING"]
                        ],
                        "required": ["speaker", "text"]
                    ]
                ],
                "summary": ["type": "STRING"],
                "sentiment": ["type": "STRING"],
                "action_items": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"]
                ],
                "follow_up_email": [
                    "type": "OBJECT",
                    "properties": [
                        "subject": ["type": "STRING"],
                        "body": ["type": "STRING"]
                    ],
                    "required": ["subject", "body"]
                ]
            ],
            "required": ["transcript", "summary", "sentiment", "action_items", "follow_up_email"]
        ]
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        [
                            "inlineData": [
                                "mimeType": mimeType,
                                "data": base64Audio
                            ]
                        ],
                        [
                            "text": promptText
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": requestSchema
            ]
        ]
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.error = "Invalid API endpoint URL"
                completion(nil)
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Pass the API key as a header rather than a `?key=` query param so it
        // doesn't leak into URL logs, proxies, or on-disk caches.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        } catch {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.error = "Failed to serialize JSON body: \(error.localizedDescription)"
                completion(nil)
            }
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, urlError in
            DispatchQueue.main.async {
                self?.isProcessing = false
            }
            
            if let urlError = urlError {
                DispatchQueue.main.async {
                    self?.error = "Network error: \(urlError.localizedDescription)"
                    completion(nil)
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    self?.error = "Received empty response from Gemini server."
                    completion(nil)
                }
                return
            }
            
            // Check status code
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                let message = GeminiClient.userFacingError(statusCode: httpResponse.statusCode, body: data, model: model)
                DispatchQueue.main.async {
                    self?.error = message
                    completion(nil)
                }
                return
            }
            
            do {
                // Parse response to find candidate text
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let firstCandidate = candidates.first,
                   let content = firstCandidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let firstPart = parts.first,
                   let text = firstPart["text"] as? String {
                    
                    let textData = Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                    let decoder = JSONDecoder()
                    let resultResponse = try decoder.decode(MeetingAnalysisResponse.self, from: textData)
                    
                    DispatchQueue.main.async {
                        self?.result = resultResponse
                        completion(resultResponse)
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.error = "Unexpected response structure from Gemini API"
                        completion(nil)
                    }
                }
            } catch {
                print("Failed to decode JSON: \(error)")
                DispatchQueue.main.async {
                    self?.error = "Decoding failed: \(error.localizedDescription)"
                    completion(nil)
                }
            }
        }.resume()
    }
}
