import XCTest

/// Tests for GeminiClient.userFacingError — the mapping from Google's error
/// envelope (https://generativelanguage.googleapis.com) to actionable UI text.
/// Error shapes verified against Google docs/forums as of July 2026.
final class GeminiClientErrorTests: XCTestCase {

    /// Builds a standard Google API error envelope body.
    private func envelope(code: Int, status: String, message: String, reason: String? = nil) -> Data {
        var error: [String: Any] = ["code": code, "message": message, "status": status]
        if let reason = reason {
            error["details"] = [[
                "@type": "type.googleapis.com/google.rpc.ErrorInfo",
                "reason": reason,
                "domain": "googleapis.com",
            ]]
        }
        return try! JSONSerialization.data(withJSONObject: ["error": error])
    }

    func testInvalidAPIKeyPointsAtAIStudio() {
        let body = envelope(code: 400, status: "INVALID_ARGUMENT",
                            message: "API key not valid. Please pass a valid API key.",
                            reason: "API_KEY_INVALID")
        let msg = GeminiClient.userFacingError(statusCode: 400, body: body, model: "gemini-3.5-flash")
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("api key"), msg)
        XCTAssertTrue(msg.contains("aistudio.google.com"), msg)
    }

    func testRetiredModel404NamesModelAndSettings() {
        let body = envelope(code: 404, status: "NOT_FOUND",
                            message: "This model models/gemini-2.0-flash is no longer available. Please update your code to use a newer model for the latest features and improvements.")
        let msg = GeminiClient.userFacingError(statusCode: 404, body: body, model: "gemini-2.0-flash")
        XCTAssertTrue(msg.contains("gemini-2.0-flash"), msg)
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("settings"), msg)
    }

    func testUnauthenticated401MentionsAuthentication() {
        let body = envelope(code: 401, status: "UNAUTHENTICATED",
                            message: "Request had invalid authentication credentials.",
                            reason: "ACCESS_TOKEN_TYPE_UNSUPPORTED")
        let msg = GeminiClient.userFacingError(statusCode: 401, body: body, model: "gemini-3.5-flash")
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("authenticat"), msg)
    }

    func testPermissionDenied403MentionsPermission() {
        let body = envelope(code: 403, status: "PERMISSION_DENIED",
                            message: "Your API key doesn't have the required permissions.")
        let msg = GeminiClient.userFacingError(statusCode: 403, body: body, model: "gemini-3.5-flash")
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("permission"), msg)
    }

    func testRateLimited429MentionsRateLimit() {
        let body = envelope(code: 429, status: "RESOURCE_EXHAUSTED",
                            message: "You exceeded your current quota.")
        let msg = GeminiClient.userFacingError(statusCode: 429, body: body, model: "gemini-3.5-flash")
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("rate limit") || msg.localizedCaseInsensitiveContains("quota"), msg)
    }

    func testUnparseableBodyFallsBackToStatusCode() {
        let body = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        let msg = GeminiClient.userFacingError(statusCode: 502, body: body, model: "gemini-3.5-flash")
        XCTAssertTrue(msg.contains("502"), msg)
    }

    func testUnknownGoogleErrorPassesMessageThrough() {
        let body = envelope(code: 400, status: "INVALID_ARGUMENT",
                            message: "Request payload size exceeds the limit: 20971520 bytes.")
        let msg = GeminiClient.userFacingError(statusCode: 400, body: body, model: "gemini-3.5-flash")
        XCTAssertTrue(msg.contains("Request payload size exceeds the limit"), msg)
    }
}
