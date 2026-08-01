import XCTest

private struct StubError: Error {}

final class RetryPolicyTests: XCTestCase {
    func testSuccessOnFirstBudgetCallsBodyOnce() async throws {
        var receivedBudgets: [Int] = []
        let result = try await withBudgetRetry(budgets: [2500, 1200], isRetryable: { _ in true }) { budget in
            receivedBudgets.append(budget)
            return budget
        }
        XCTAssertEqual(result, 2500)
        XCTAssertEqual(receivedBudgets, [2500])
    }

    func testRetryableErrorOnFirstBudgetRetriesWithSecond() async throws {
        var receivedBudgets: [Int] = []
        let result = try await withBudgetRetry(budgets: [2500, 1200], isRetryable: { _ in true }) { budget in
            receivedBudgets.append(budget)
            if budget == 2500 {
                throw StubError()
            }
            return budget
        }
        XCTAssertEqual(result, 1200)
        XCTAssertEqual(receivedBudgets, [2500, 1200])
    }

    func testNonRetryableErrorPropagatesImmediately() async throws {
        var receivedBudgets: [Int] = []
        do {
            _ = try await withBudgetRetry(budgets: [2500, 1200], isRetryable: { _ in false }) { budget in
                receivedBudgets.append(budget)
                throw StubError()
            }
            XCTFail("expected StubError to propagate")
        } catch is StubError {
            // expected
        }
        XCTAssertEqual(receivedBudgets, [2500])
    }

    func testRetryableErrorOnLastBudgetPropagates() async throws {
        var receivedBudgets: [Int] = []
        do {
            _ = try await withBudgetRetry(budgets: [2500, 1200], isRetryable: { _ in true }) { budget in
                receivedBudgets.append(budget)
                throw StubError()
            }
            XCTFail("expected StubError to propagate")
        } catch is StubError {
            // expected
        }
        XCTAssertEqual(receivedBudgets, [2500, 1200])
    }
}
