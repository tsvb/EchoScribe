import XCTest

/// Tests for OpenAIClient.userFacingError — the mapping from OpenAI's error
/// envelope (https://api.openai.com) to actionable UI text.
/// Error shapes verified against developers.openai.com, August 2026.
final class OpenAIClientErrorTests: XCTestCase {

    /// Builds a standard OpenAI API error envelope body.
    private func envelope(message: String, type: String? = nil, code: String? = nil) -> Data {
        var error: [String: Any] = ["message": message]
        if let type = type { error["type"] = type }
        if let code = code { error["code"] = code }
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    func testInvalidAPIKeyCodePointsAtPlatform() {
        let body = envelope(message: "Incorrect API key provided.", type: "invalid_request_error", code: "invalid_api_key")
        let msg = OpenAIClient.userFacingError(statusCode: 401, body: body, model: "gpt-4o")
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("api key"), msg)
        XCTAssertTrue(msg.contains("platform.openai.com"), msg)
    }

    func testBare401WithoutCodeStillMapsToAPIKeyMessage() {
        let body = envelope(message: "Unauthorized.")
        let msg = OpenAIClient.userFacingError(statusCode: 401, body: body, model: "gpt-4o")
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("api key"), msg)
        XCTAssertTrue(msg.contains("platform.openai.com"), msg)
    }

    func testModelNotFound404NamesModelAndSettings() {
        let body = envelope(message: "The model `gpt-4o` does not exist.", type: "invalid_request_error", code: "model_not_found")
        let msg = OpenAIClient.userFacingError(statusCode: 404, body: body, model: "gpt-4o")
        XCTAssertTrue(msg.contains("gpt-4o"), msg)
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("settings"), msg)
    }

    func testInsufficientQuotaAt429PrecedesGenericRateLimitMessage() {
        let body = envelope(message: "You exceeded your current quota.", type: "insufficient_quota", code: "insufficient_quota")
        let msg = OpenAIClient.userFacingError(statusCode: 429, body: body, model: "gpt-4o")
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("quota"), msg)
        XCTAssertFalse(msg.localizedCaseInsensitiveContains("rate limit"), msg)
    }

    func testBare429MentionsRateLimit() {
        let body = envelope(message: "Rate limit reached for requests.", type: "requests")
        let msg = OpenAIClient.userFacingError(statusCode: 429, body: body, model: "gpt-4o")
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("rate limit"), msg)
    }

    func testForbidden403MentionsModelAndPermissions() {
        let body = envelope(message: "You do not have access to this model.")
        let msg = OpenAIClient.userFacingError(statusCode: 403, body: body, model: "gpt-4o")
        XCTAssertTrue(msg.contains("gpt-4o"), msg)
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("permission"), msg)
    }

    func testUnparseableBodyFallsBackToStatusCode() {
        let body = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        let msg = OpenAIClient.userFacingError(statusCode: 502, body: body, model: "gpt-4o")
        XCTAssertTrue(msg.contains("502"), msg)
    }

    func testUnknownErrorPassesMessageThrough() {
        let body = envelope(message: "Request too large for gpt-4o.", type: "invalid_request_error")
        let msg = OpenAIClient.userFacingError(statusCode: 400, body: body, model: "gpt-4o")
        XCTAssertTrue(msg.contains("Request too large for gpt-4o"), msg)
    }
}
