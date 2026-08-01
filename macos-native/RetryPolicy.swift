import Foundation

/// Runs `body` once per budget, moving to the next budget only when
/// `isRetryable` matches the thrown error. Non-retryable errors and the
/// final attempt's error propagate. (Used for the on-device model's
/// context-window overflow: TN3193 prescribes retrying at a smaller chunk budget.)
func withBudgetRetry<T>(budgets: [Int],
                        isRetryable: (Error) -> Bool,
                        _ body: (Int) async throws -> T) async throws -> T {
    precondition(!budgets.isEmpty)
    for (index, budget) in budgets.enumerated() {
        do {
            return try await body(budget)
        } catch where index < budgets.count - 1 && isRetryable(error) {
            continue
        }
    }
    fatalError("unreachable: loop always returns or throws")
}
