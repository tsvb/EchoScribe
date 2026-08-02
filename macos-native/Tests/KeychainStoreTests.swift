import XCTest
import Security

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!

    override func setUpWithError() throws {
        store = KeychainStore(service: "com.echoscribe.EchoScribeTests",
                              account: "test_key_\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        store.delete()
    }

    func testReadMissingReturnsNil() throws {
        XCTAssertNil(try store.read())
    }

    func testSaveReadRoundtrip() throws {
        XCTAssertTrue(store.save("AQ.test-value-123"))
        XCTAssertEqual(try store.read(), "AQ.test-value-123")
    }

    func testSaveOverwrites() throws {
        store.save("first")
        XCTAssertTrue(store.save("second"))
        XCTAssertEqual(try store.read(), "second")
    }

    func testSaveEmptyDeletes() throws {
        store.save("something")
        XCTAssertTrue(store.save(""))
        XCTAssertNil(try store.read())
    }

    func testDeleteIsIdempotent() {
        XCTAssertTrue(store.delete())
        store.save("x")
        XCTAssertTrue(store.delete())
        XCTAssertTrue(store.delete())
    }

    // MARK: - interpretRead: pure mapping from a SecItemCopyMatching result.
    // "No item" must stay distinguishable from "read failed" — collapsing the
    // two is what once let a failed read turn into a key-deleting save("").

    func testInterpretReadSuccessWithDataReturnsValue() throws {
        let value = try KeychainStore.interpretRead(status: errSecSuccess,
                                                    item: Data("sk-abc".utf8) as CFTypeRef)
        XCTAssertEqual(value, "sk-abc")
    }

    func testInterpretReadNotFoundReturnsNilWithoutThrowing() throws {
        XCTAssertNil(try KeychainStore.interpretRead(status: errSecItemNotFound, item: nil))
    }

    func testInterpretReadFailureThrowsWithStatus() {
        XCTAssertThrowsError(try KeychainStore.interpretRead(status: errSecAuthFailed,
                                                             item: nil)) { error in
            XCTAssertEqual((error as? KeychainReadError)?.status, errSecAuthFailed)
        }
    }

    func testInterpretReadLockedKeychainThrowsPropagatingStatus() {
        XCTAssertThrowsError(try KeychainStore.interpretRead(status: errSecInteractionNotAllowed,
                                                             item: nil)) { error in
            XCTAssertEqual((error as? KeychainReadError)?.status, errSecInteractionNotAllowed)
        }
    }

    func testInterpretReadSuccessWithoutDataThrowsDecodeError() {
        XCTAssertThrowsError(try KeychainStore.interpretRead(status: errSecSuccess,
                                                             item: nil)) { error in
            XCTAssertEqual((error as? KeychainReadError)?.status, errSecDecode)
        }
    }

    func testInterpretReadNonUTF8DataThrowsDecodeError() {
        let bogus = Data([0xFF, 0xFE, 0xFF]) as CFTypeRef
        XCTAssertThrowsError(try KeychainStore.interpretRead(status: errSecSuccess,
                                                             item: bogus)) { error in
            XCTAssertEqual((error as? KeychainReadError)?.status, errSecDecode)
        }
    }

    // MARK: - shouldPersist: the delete-suppression decision for edited key fields

    func testShouldPersistSuppressesOnlyEmptyValueAfterFailedRead() {
        // Explicit new values always persist — user intent may overwrite.
        XCTAssertTrue(KeychainStore.shouldPersist(newValue: "sk-new", readFailed: false))
        XCTAssertTrue(KeychainStore.shouldPersist(newValue: "sk-new", readFailed: true))
        // A deliberate clear of a READ value is a real delete instruction.
        XCTAssertTrue(KeychainStore.shouldPersist(newValue: "", readFailed: false))
        // But a clear after a FAILED read must never delete: the empty field
        // was our invention, not the Keychain's contents.
        XCTAssertFalse(KeychainStore.shouldPersist(newValue: "", readFailed: true))
    }
}
