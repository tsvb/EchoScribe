import XCTest

/// Tests for OpenAIClient's pure decoders and OpenAIEngine's pure transcript
/// mapping/sizing helpers. No network mocks — fixtures are literal JSON.
final class OpenAIEngineMappingTests: XCTestCase {

    // MARK: - decodeTranscription

    func testDecodeTranscriptionIgnoresExtraKeys() throws {
        let json = """
        {
          "task": "transcribe",
          "duration": 12.5,
          "segments": [
            {"speaker": "A", "text": "Hello everyone.", "start": 0.0, "end": 1.2, "id": 0},
            {"speaker": "B", "text": "Hi, thanks for joining.", "start": 1.2, "end": 3.0}
          ]
        }
        """
        let segments = try OpenAIClient.decodeTranscription(Data(json.utf8))
        XCTAssertEqual(segments, [
            OpenAIClient.DiarizedSegment(speaker: "A", text: "Hello everyone."),
            OpenAIClient.DiarizedSegment(speaker: "B", text: "Hi, thanks for joining."),
        ])
    }

    // MARK: - decodeChatPayload

    func testDecodeChatPayloadDigsEmbeddedJSONString() throws {
        let inner = """
        {"summary":"Shipped the release.","sentiment":"positive","action_items":["Follow up with QA"],"follow_up_email":{"subject":"Recap","body":"Thanks all."},"speaker_names":[{"label":"A","name":"Tim"}]}
        """
        let innerEscaped = inner.replacingOccurrences(of: "\"", with: "\\\"")
        let envelope = """
        {"choices":[{"message":{"content":"\(innerEscaped)"}}]}
        """
        let payload = try OpenAIClient.decodeChatPayload(Data(envelope.utf8))
        XCTAssertEqual(payload.summary, "Shipped the release.")
        XCTAssertEqual(payload.sentiment, "positive")
        XCTAssertEqual(payload.actionItems, ["Follow up with QA"])
        XCTAssertEqual(payload.followUpEmail.subject, "Recap")
        XCTAssertEqual(payload.followUpEmail.body, "Thanks all.")
        XCTAssertEqual(payload.speakerNames, [OpenAIClient.SpeakerName(label: "A", name: "Tim")])
    }

    func testDecodeChatPayloadThrowsOnMalformedEnvelope() {
        let envelope = """
        {"choices":[{"message":{}}]}
        """
        XCTAssertThrowsError(try OpenAIClient.decodeChatPayload(Data(envelope.utf8)))
    }

    // MARK: - resolvedTranscript

    func testResolvedTranscriptAppliesMappedNames() {
        let segments = [
            OpenAIClient.DiarizedSegment(speaker: "A", text: "Let's start."),
            OpenAIClient.DiarizedSegment(speaker: "B", text: "Sounds good."),
        ]
        let names = [
            OpenAIClient.SpeakerName(label: "A", name: "Tim"),
            OpenAIClient.SpeakerName(label: "B", name: "Dana"),
        ]
        let result = OpenAIEngine.resolvedTranscript(segments: segments, names: names)
        XCTAssertEqual(result.map(\.speaker), ["Tim", "Dana"])
        XCTAssertEqual(result.map(\.text), ["Let's start.", "Sounds good."])
    }

    func testResolvedTranscriptFallsBackForUnmappedLabel() {
        let segments = [OpenAIClient.DiarizedSegment(speaker: "B", text: "Anyone there?")]
        let result = OpenAIEngine.resolvedTranscript(segments: segments, names: [])
        XCTAssertEqual(result.map(\.speaker), ["Speaker B"])
    }

    func testResolvedTranscriptFallsBackForEmptyOrWhitespaceName() {
        let segments = [OpenAIClient.DiarizedSegment(speaker: "A", text: "Hello.")]
        let names = [OpenAIClient.SpeakerName(label: "A", name: "   ")]
        let result = OpenAIEngine.resolvedTranscript(segments: segments, names: names)
        XCTAssertEqual(result.map(\.speaker), ["Speaker A"])
    }

    func testResolvedTranscriptFallsBackWhenNameEqualsLabelCaseInsensitive() {
        let segments = [OpenAIClient.DiarizedSegment(speaker: "A", text: "Hello.")]
        let names = [OpenAIClient.SpeakerName(label: "A", name: "a")]
        let result = OpenAIEngine.resolvedTranscript(segments: segments, names: names)
        XCTAssertEqual(result.map(\.speaker), ["Speaker A"])
    }

    func testResolvedTranscriptMergesConsecutiveSameSpeakerSegments() {
        let segments = [
            OpenAIClient.DiarizedSegment(speaker: "A", text: "First part."),
            OpenAIClient.DiarizedSegment(speaker: "A", text: "second part."),
            OpenAIClient.DiarizedSegment(speaker: "B", text: "A reply."),
            OpenAIClient.DiarizedSegment(speaker: "A", text: "Back again."),
        ]
        let names = [
            OpenAIClient.SpeakerName(label: "A", name: "Tim"),
            OpenAIClient.SpeakerName(label: "B", name: "Dana"),
        ]
        let result = OpenAIEngine.resolvedTranscript(segments: segments, names: names)
        XCTAssertEqual(result.map(\.speaker), ["Tim", "Dana", "Tim"])
        XCTAssertEqual(result.map(\.text), ["First part. second part.", "A reply.", "Back again."])
    }

    func testResolvedTranscriptLastDuplicateLabelWins() {
        let segments = [OpenAIClient.DiarizedSegment(speaker: "A", text: "Hello.")]
        let names = [
            OpenAIClient.SpeakerName(label: "A", name: "Tim"),
            OpenAIClient.SpeakerName(label: "A", name: "Timothy"),
        ]
        let result = OpenAIEngine.resolvedTranscript(segments: segments, names: names)
        XCTAssertEqual(result.map(\.speaker), ["Timothy"])
    }

    // MARK: - oversizeMessage

    func testOversizeMessageNilAtLimit() {
        XCTAssertNil(OpenAIEngine.oversizeMessage(bytes: OpenAIEngine.maxUploadBytes))
    }

    func testOversizeMessageOverLimitMentions25MB() {
        let message = OpenAIEngine.oversizeMessage(bytes: OpenAIEngine.maxUploadBytes + 1)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("25 MB") ?? false, message ?? "nil")
    }
}
