import XCTest

final class EngineResolverTests: XCTestCase {
    func testAutoPrefersAppleWhenAvailable() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: true, cloudKeys: ["gemini"]))
        XCTAssertEqual(c, .apple)
    }

    func testAutoFallsBackToGeminiWithKey() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false, cloudKeys: ["gemini"]))
        XCTAssertEqual(c, .cloud("gemini"))
    }

    func testAutoWithNothingExplainsBothFixes() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false, cloudKeys: []))
        guard case .none(let reason) = c else { return XCTFail("expected .none") }
        XCTAssertTrue(reason.contains("Apple Intelligence"), reason)
        XCTAssertTrue(reason.contains("Gemini"), reason)
    }

    func testExplicitAppleUnavailableFails() {
        let c = resolveEngine(preference: .apple,
                              context: EngineContext(appleAvailable: false, cloudKeys: ["gemini"]))
        guard case .none = c else { return XCTFail("expected .none") }
    }

    func testExplicitGeminiWithoutKeyFails() {
        let c = resolveEngine(preference: .cloud(id: "gemini"),
                              context: EngineContext(appleAvailable: true, cloudKeys: []))
        guard case .none = c else { return XCTFail("expected .none") }
    }

    // MARK: - Multi-provider selection

    func testAutoFallsBackToOpenAIWhenItIsTheOnlyKey() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false, cloudKeys: ["openai"]))
        XCTAssertEqual(c, .cloud("openai"))
    }

    func testAutoPrefersRegistryOrderWhenBothKeysPresent() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false,
                                                     cloudKeys: ["openai", "gemini"]))
        XCTAssertEqual(c, .cloud("gemini"))
    }

    func testExplicitOpenAIWithoutKeyNamesOpenAI() {
        let c = resolveEngine(preference: .cloud(id: "openai"),
                              context: EngineContext(appleAvailable: true, cloudKeys: ["gemini"]))
        guard case .none(let reason) = c else { return XCTFail("expected .none") }
        XCTAssertTrue(reason.contains("OpenAI"), reason)
    }

    func testExplicitOpenAIWithKeyBeatsAvailableApple() {
        let c = resolveEngine(preference: .cloud(id: "openai"),
                              context: EngineContext(appleAvailable: true, cloudKeys: ["openai"]))
        XCTAssertEqual(c, .cloud("openai"))
    }

    /// A preference left behind by a provider that no longer exists must
    /// self-heal into the auto resolution rather than dead-ending.
    func testUnknownProviderIdFallsBackToAutoResolution() {
        let c = resolveEngine(preference: .cloud(id: "anthropic"),
                              context: EngineContext(appleAvailable: true, cloudKeys: []))
        XCTAssertEqual(c, .apple)
    }

    func testAppleUnavailableReasonListsEveryCloudProvider() {
        let c = resolveEngine(preference: .apple,
                              context: EngineContext(appleAvailable: false, cloudKeys: []))
        guard case .none(let reason) = c else { return XCTFail("expected .none") }
        XCTAssertTrue(reason.contains("Gemini"), reason)
        XCTAssertTrue(reason.contains("OpenAI"), reason)
    }

    func testNothingAvailableReasonListsEveryOption() {
        let c = resolveEngine(preference: .auto,
                              context: EngineContext(appleAvailable: false, cloudKeys: []))
        guard case .none(let reason) = c else { return XCTFail("expected .none") }
        XCTAssertTrue(reason.contains("Apple Intelligence"), reason)
        XCTAssertTrue(reason.contains("Gemini"), reason)
        XCTAssertTrue(reason.contains("OpenAI"), reason)
    }

    // MARK: - Preference parsing

    func testPreferenceParsingFromStoredRawValues() {
        XCTAssertEqual(EnginePreference(raw: "auto"), .auto)
        XCTAssertEqual(EnginePreference(raw: "apple"), .apple)
        XCTAssertEqual(EnginePreference(raw: "gemini"), .cloud(id: "gemini"))
        XCTAssertEqual(EnginePreference(raw: "openai"), .cloud(id: "openai"))
        XCTAssertEqual(EnginePreference(raw: "not-a-real-engine"), .cloud(id: "not-a-real-engine"))
    }
}
