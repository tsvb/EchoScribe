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

    /// `budget` guarded against degenerate (<=0) values so a misconfigured
    /// caller can't make every slicing loop below spin forever on empty output.
    private var safeBudget: Int { max(1, budget) }

    func chunk(_ text: String) -> [String] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""

        for paragraph in paragraphs {
            let candidate = current.isEmpty ? paragraph : current + "\n" + paragraph
            if counter.tokenCount(for: candidate) <= safeBudget {
                current = candidate
            } else {
                if !current.isEmpty { chunks.append(current); current = "" }
                if counter.tokenCount(for: paragraph) <= safeBudget {
                    current = paragraph
                } else {
                    chunks.append(contentsOf: splitOversized(paragraph))
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // NOTE: splitOversized/hardSlices are O(n^2) in the worst case (a single
    // token run longer than the budget forces repeated tokenCount() calls
    // over a growing slice). Accepted: production budgets are 1200+ tokens,
    // so pathological single-token runs long enough for this to matter don't
    // occur in practice.

    /// Word-boundary packing; falls back to fixed-size character slices for a
    /// single "word" longer than the budget.
    private func splitOversized(_ paragraph: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for word in paragraph.split(separator: " ").map(String.init) {
            if counter.tokenCount(for: word) > safeBudget {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: hardSlices(word))
                continue
            }
            let candidate = current.isEmpty ? word : current + " " + word
            if counter.tokenCount(for: candidate) <= safeBudget {
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
            if !slice.isEmpty && counter.tokenCount(for: slice + String(ch)) > safeBudget {
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
