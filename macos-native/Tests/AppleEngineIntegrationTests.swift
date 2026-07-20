import XCTest
import FoundationModels

final class AppleEngineIntegrationTests: XCTestCase {
    /// Real on-device model — skipped on machines without Apple Intelligence.
    func testSummarizeShortTranscriptProducesNotes() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26+") }
        try XCTSkipUnless(SystemLanguageModel.default.isAvailable,
                          "Apple Intelligence not available on this machine")

        let transcript = """
        We agreed the release ships Friday. Bob will write the release notes.
        Alice will confirm the pricing page copy with marketing by Wednesday.
        """
        let notes = try await AppleAnalysisEngine.summarize(
            transcript: transcript, title: "Release sync",
            participants: ["Alice", "Bob"], progress: { _ in })

        XCTAssertFalse(notes.summary.isEmpty)
        XCTAssertFalse(notes.actionItems.isEmpty)
        XCTAssertFalse(notes.emailSubject.isEmpty)
        XCTAssertFalse(notes.emailBody.isEmpty)
    }
}
