import XCTest

final class EngineResolverTests: XCTestCase {
    func testAutoPrefersAppleWhenAvailable() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: true, hasGeminiKey: true))
        XCTAssertEqual(c, .apple)
    }

    func testAutoFallsBackToGeminiWithKey() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false, hasGeminiKey: true))
        XCTAssertEqual(c, .gemini)
    }

    func testAutoWithNothingExplainsBothFixes() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false, hasGeminiKey: false))
        guard case .none(let reason) = c else { return XCTFail("expected .none") }
        XCTAssertTrue(reason.contains("Apple Intelligence"), reason)
        XCTAssertTrue(reason.contains("Gemini"), reason)
    }

    func testExplicitAppleUnavailableFails() {
        let c = resolveEngine(preference: .apple,
                              context: EngineContext(appleAvailable: false, hasGeminiKey: true))
        guard case .none = c else { return XCTFail("expected .none") }
    }

    func testExplicitGeminiWithoutKeyFails() {
        let c = resolveEngine(preference: .gemini,
                              context: EngineContext(appleAvailable: true, hasGeminiKey: false))
        guard case .none = c else { return XCTFail("expected .none") }
    }
}
