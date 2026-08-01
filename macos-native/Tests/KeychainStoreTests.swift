import XCTest

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!

    override func setUpWithError() throws {
        store = KeychainStore(service: "com.echoscribe.EchoScribeTests",
                              account: "test_key_\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        store.delete()
    }

    func testReadMissingReturnsNil() {
        XCTAssertNil(store.read())
    }

    func testSaveReadRoundtrip() {
        XCTAssertTrue(store.save("AQ.test-value-123"))
        XCTAssertEqual(store.read(), "AQ.test-value-123")
    }

    func testSaveOverwrites() {
        store.save("first")
        XCTAssertTrue(store.save("second"))
        XCTAssertEqual(store.read(), "second")
    }

    func testSaveEmptyDeletes() {
        store.save("something")
        XCTAssertTrue(store.save(""))
        XCTAssertNil(store.read())
    }

    func testDeleteIsIdempotent() {
        XCTAssertTrue(store.delete())
        store.save("x")
        XCTAssertTrue(store.delete())
        XCTAssertTrue(store.delete())
    }
}
