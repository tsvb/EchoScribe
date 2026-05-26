import Foundation
import Combine

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
    var id: UUID { UUID() }
    let speaker: String
    let text: String
}

struct FollowUpEmail: Codable {
    let subject: String
    let body: String
}

class GeminiClient: ObservableObject {
    @Published var isProcessing = false
    @Published var error: String?
    @Published var result: MeetingAnalysisResponse?
    
    func requestAnalysis(audioData: Data, mimeType: String, apiKey: String, title: String, participants: [String], completion: @escaping (MeetingAnalysisResponse?) -> Void) {
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
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(apiKey)") else {
            DispatchQueue.main.async {
                self.isProcessing = false
                self.error = "Invalid API endpoint URL"
                completion(nil)
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
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
                let statusMessage = String(data: data, encoding: .utf8) ?? "HTTP error \(httpResponse.statusCode)"
                DispatchQueue.main.async {
                    self?.error = "Gemini API Error: \(statusMessage)"
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
