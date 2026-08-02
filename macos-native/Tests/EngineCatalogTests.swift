import XCTest

final class EngineCatalogTests: XCTestCase {
    func testBadgeLabelNamesKnownEnginesAndEchoesUnknownOnes() {
        XCTAssertEqual(CloudProviders.badgeLabel(engine: "apple"), "On-device")
        XCTAssertEqual(CloudProviders.badgeLabel(engine: "gemini"), "Gemini")
        XCTAssertEqual(CloudProviders.badgeLabel(engine: "openai"), "OpenAI")
        XCTAssertEqual(CloudProviders.badgeLabel(engine: "mystery"), "mystery")
    }

    func testTranscriptHeaderOnlyPromisesSpeakersForCloudEngines() {
        XCTAssertEqual(CloudProviders.transcriptHeader(engine: nil), "Transcript")
        XCTAssertEqual(CloudProviders.transcriptHeader(engine: "apple"), "Transcript")
        XCTAssertEqual(CloudProviders.transcriptHeader(engine: "mystery"), "Transcript")
        XCTAssertEqual(CloudProviders.transcriptHeader(engine: "gemini"), "Speaker-Attributed Dialogue")
        XCTAssertEqual(CloudProviders.transcriptHeader(engine: "openai"), "Speaker-Attributed Dialogue")
    }

    func testHealedModelKeepsValidStoredIDs() {
        for provider in CloudProviders.all {
            for model in provider.models {
                XCTAssertEqual(CloudProviders.healedModel(stored: model.id, for: provider), model.id)
            }
        }
    }

    func testHealedModelResetsRetiredOrMissingIDs() throws {
        let gemini = try XCTUnwrap(CloudProviders.find("gemini"))
        let openai = try XCTUnwrap(CloudProviders.find("openai"))

        XCTAssertEqual(CloudProviders.healedModel(stored: "gemini-2.0-flash", for: gemini),
                       "gemini-3.5-flash")
        XCTAssertEqual(CloudProviders.healedModel(stored: "gpt-4o", for: openai),
                       "gpt-5.6-terra")
        XCTAssertEqual(CloudProviders.healedModel(stored: nil, for: gemini), gemini.defaultModel)
        XCTAssertEqual(CloudProviders.healedModel(stored: nil, for: openai), openai.defaultModel)
    }

    func testFindResolvesKnownIDsOnly() {
        XCTAssertEqual(CloudProviders.find("gemini")?.displayName, "Gemini")
        XCTAssertEqual(CloudProviders.find("openai")?.displayName, "OpenAI")
        XCTAssertNil(CloudProviders.find("mystery"))
        XCTAssertNil(CloudProviders.find(nil))
    }

    func testRegistryRowsAreWellFormed() {
        let ids = CloudProviders.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "provider ids must be unique")

        let accounts = CloudProviders.all.map(\.keychain.account)
        XCTAssertEqual(Set(accounts).count, accounts.count, "keychain accounts must be distinct")

        let defaultsKeys = CloudProviders.all.map(\.modelDefaultsKey)
        XCTAssertEqual(Set(defaultsKeys).count, defaultsKeys.count,
                       "model defaults keys must be distinct")

        for provider in CloudProviders.all {
            XCTAssertTrue(provider.models.contains { $0.id == provider.defaultModel },
                          "\(provider.id) default model is not in its own model list")
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertFalse(provider.engineOptionLabel.isEmpty)
            XCTAssertFalse(provider.keyPlaceholder.isEmpty)
        }
    }

    /// The Gemini row must stay byte-identical to the pre-registry constants:
    /// changing the id or default silently retires working user setups.
    func testGeminiRowPreservesIncumbentConfiguration() throws {
        let gemini = try XCTUnwrap(CloudProviders.find("gemini"))
        XCTAssertEqual(CloudProviders.all.first?.id, "gemini", "gemini must stay first for auto")
        XCTAssertEqual(gemini.defaultModel, "gemini-3.5-flash")
        XCTAssertEqual(gemini.modelDefaultsKey, "gemini_selected_model")
        XCTAssertEqual(gemini.keychain.account, "gemini_api_key")
        XCTAssertEqual(gemini.models.map(\.id),
                       ["gemini-3.5-flash", "gemini-3.1-flash-lite", "gemini-3.1-pro-preview"])
    }

    func testProviderRowsBuildTheirOwnEngine() throws {
        let gemini = try XCTUnwrap(CloudProviders.find("gemini"))
        let openai = try XCTUnwrap(CloudProviders.find("openai"))
        XCTAssertEqual(gemini.makeEngine("key", "gemini-3.5-flash").id, "gemini")
        XCTAssertEqual(openai.makeEngine("key", "gpt-5.6-terra").id, "openai")
        XCTAssertEqual(openai.makeEngine("key", "gpt-5.6-sol").modelName, "gpt-5.6-sol")
    }
}
