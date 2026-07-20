import Foundation

protocol TokenCounting {
    func tokenCount(for text: String) -> Int
}

/// Conservative heuristic (~3 chars/token for English). Used instead of the
/// FoundationModels tokenizer so chunking stays pure and unit-testable; the
/// budget below leaves ample headroom in the 4,096-token window (TN3193).
struct EstimatedTokenCounter: TokenCounting {
    func tokenCount(for text: String) -> Int { max(1, text.count / 3) }
}

/// Splits a transcript into chunks that each fit a token budget, preferring
/// paragraph boundaries, then word boundaries, then hard character splits.
struct TranscriptChunker {
    let counter: TokenCounting
    let budget: Int

    func chunk(_ text: String) -> [String] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : current + "\n" + paragraph
            if counter.tokenCount(for: candidate) <= budget {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current); current = "" }
                if counter.tokenCount(for: paragraph) <= budget {
                    current = paragraph
                } else {
                    chunks.append(contentsOf: splitOversized(paragraph))
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Word-boundary packing; falls back to fixed-size character slices for a
    /// single "word" longer than the budget.
    private func splitOversized(_ paragraph: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in paragraph.split(separator: " ").map(String.init) {
            if counter.tokenCount(for: word) > budget {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSlices(word))
                continue
            }
            let candidate = current.isEmpty ? word : current + " " + word
            if counter.tokenCount(for: candidate) <= budget {
                current = candidate
            } else {
                chunks.append(current)
                current = word
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func hardSlices(_ word: String) -> [String] {
        var slices: [String] = []
        var slice = ""
        for ch in word {
            if counter.tokenCount(for: slice + String(ch)) > budget {
                slices.append(slice)
                slice = String(ch)
            } else {
                slice.append(ch)
            }
        }
        if !slice.isEmpty { slices.append(slice) }
        return slices
    }
}
