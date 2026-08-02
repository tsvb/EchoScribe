import XCTest

/// Tests for OpenAIClient's pure request builders — deterministic given an
/// injected boundary, so bodies are byte-for-byte assertable.
final class OpenAIRequestBuilderTests: XCTestCase {

    func testTranscriptionRequestShape() {
        let audio = Data("fake-audio-bytes".utf8)
        let request = OpenAIClient.transcriptionRequest(audioData: audio, apiKey: "sk-test", boundary: "TESTBOUNDARY")

        XCTAssertTrue(request.url?.absoluteString.hasSuffix("/v1/audio/transcriptions") ?? false, "\(String(describing: request.url))")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.contains("TESTBOUNDARY"), contentType)
        XCTAssertEqual(request.timeoutInterval, 300)

        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("gpt-4o-transcribe-diarize"), body)
        XCTAssertTrue(body.contains("diarized_json"), body)
        XCTAssertTrue(body.contains("chunking_strategy"), body)
        XCTAssertTrue(body.contains("auto"), body)
        XCTAssertTrue(body.contains("filename=\"audio.m4a\""), body)
        XCTAssertTrue(body.contains("audio/mp4"), body)
        XCTAssertTrue(body.contains("--TESTBOUNDARY--"), body)
    }

    func testChatRequestShape() throws {
        let segments = [
            OpenAIClient.DiarizedSegment(speaker: "A", text: "Let's ship the release Friday."),
        ]
        let request = try OpenAIClient.chatRequest(segments: segments, title: "Launch Sync", participants: ["Tim", "Dana"], model: "gpt-4o", apiKey: "sk-test")

        XCTAssertTrue(request.url?.absoluteString.hasSuffix("/v1/chat/completions") ?? false, "\(String(describing: request.url))")
        XCTAssertEqual(request.timeoutInterval, 120)

        let bodyData = request.httpBody ?? Data()
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "gpt-4o")

        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let jsonSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(jsonSchema["strict"] as? Bool, true)
        let schema = try XCTUnwrap(jsonSchema["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let required = try XCTUnwrap(schema["required"] as? [String])
        XCTAssertEqual(Set(required), Set(["summary", "sentiment", "action_items", "follow_up_email", "speaker_names"]))

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages.first { ($0["role"] as? String) == "user" })
        let userContent = try XCTUnwrap(userMessage["content"] as? String)
        XCTAssertTrue(userContent.contains("Let's ship the release Friday."), userContent)
        XCTAssertTrue(userContent.contains("Dana"), userContent)
    }
}
