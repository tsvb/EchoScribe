import XCTest

/// Counts 1 token per character — makes budgets exact in tests.
private struct CharCounter: TokenCounting {
    func tokenCount(for text: String) -> Int { text.count }
}

final class TranscriptChunkerTests: XCTestCase {
    func testShortInputIsSingleChunk() {
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 100)
        XCTAssertEqual(chunker.chunk("hello world"), ["hello world"])
    }

    func testEmptyInputYieldsNoChunks() {
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 100)
        XCTAssertTrue(chunker.chunk("   \n  ").isEmpty)
    }

    func testParagraphsPackGreedilyUnderBudget() {
        let text = "aaaa\nbbbb\ncccc\ndddd"   // 4-char paragraphs
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 9)
        let chunks = chunker.chunk(text)
        // "aaaa\nbbbb" = 9 tokens fits; "cccc\ndddd" = 9 fits.
        XCTAssertEqual(chunks, ["aaaa\nbbbb", "cccc\ndddd"])
    }

    func testEveryChunkRespectsBudgetAndCoversAllText() {
        let words = (0..<200).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let counter = CharCounter()
        let chunker = TranscriptChunker(counter: counter, budget: 50)
        let chunks = chunker.chunk(text)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(counter.tokenCount(for: chunk), 50, chunk)
            XCTAssertFalse(chunk.isEmpty)
        }
        // Every word survives, in order.
        let rejoined = chunks.joined(separator: " ").split(separator: " ").map(String.init)
        let expected = text.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ").map(String.init)
        XCTAssertEqual(rejoined, expected)
    }

    func testOversizedSingleParagraphIsHardSplit() {
        let text = String(repeating: "x", count: 30) // no spaces or newlines
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 10)
        let chunks = chunker.chunk(text)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 10) }
        XCTAssertEqual(chunks.joined(), text)
    }

    func testCRLFInputCarriesNoCarriageReturns() {
        let chunker = TranscriptChunker(counter: CharCounter(), budget: 100)
        let chunks = chunker.chunk("alpha\r\nbeta\r\ngamma")
        XCTAssertEqual(chunks.count, 1)
        for chunk in chunks {
            XCTAssertFalse(chunk.contains("\r"), chunk)
        }
    }
}
