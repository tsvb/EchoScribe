import XCTest

@available(macOS 26.0, *)
final class AppleEngineSegmentationTests: XCTestCase {

    func testOversizedParagraphIsSplit() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26+") }

        // Create a single 1200-char paragraph with repeated "word " tokens
        let word = "word "
        let oversizedParagraph = String(repeating: word, count: 240) // 240 * 5 = 1200 chars

        let segments = AppleAnalysisEngine.transcriptSegments(from: oversizedParagraph)

        // Verify all segments are ≤ 500 chars
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.text.count, 500,
                                      "Segment exceeds 500 chars: \(segment.text.count)")
        }

        // Verify at least 3 segments (1200 chars split into ≤500 chunks)
        XCTAssertGreaterThanOrEqual(segments.count, 3,
                                     "Expected at least 3 segments, got \(segments.count)")

        // Verify all speakers are "Speaker"
        for segment in segments {
            XCTAssertEqual(segment.speaker, "Speaker")
        }

        // Verify text coverage: join segments and check all words are present in order
        let joined = segments.map { $0.text }.joined(separator: " ")
        let normalizedJoined = joined.split(separator: " ").map(String.init).joined(separator: " ")
        let normalizedOriginal = oversizedParagraph.split(separator: " ").map(String.init).joined(separator: " ")

        XCTAssertEqual(normalizedJoined, normalizedOriginal,
                       "Concatenated segments don't match original text")
    }

    func testShortParagraphsGroupIntoTurns() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("macOS 26+") }

        let input = "a\nb\nc"
        let segments = AppleAnalysisEngine.transcriptSegments(from: input)

        // Short lines should group into exactly 1 segment
        XCTAssertEqual(segments.count, 1,
                       "Expected 1 segment for short paragraphs, got \(segments.count)")

        // The segment should contain all three
        XCTAssertTrue(segments[0].text.contains("a") &&
                     segments[0].text.contains("b") &&
                     segments[0].text.contains("c"),
                     "Segment doesn't contain all input text: \(segments[0].text)")
    }
}
