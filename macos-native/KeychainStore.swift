import Foundation
import Security

/// A Keychain read that failed for a reason other than "no such item" — the
/// stored value may exist but be unreadable (locked keychain, denied access
/// prompt). Callers must never treat this as "no key stored": acting on it
/// (e.g. saving "" back) could delete a key that is really there.
struct KeychainReadError: Error, Equatable {
    let status: OSStatus
}

/// Minimal generic-password Keychain wrapper for the cloud API keys.
/// (The Gemini key previously lived in UserDefaults; ContentView migrates it once.)
struct KeychainStore {
    let service: String
    let account: String

    static let geminiAPIKey = KeychainStore(service: "com.echoscribe.EchoScribe",
                                            account: "gemini_api_key")
    static let openaiAPIKey = KeychainStore(service: "com.echoscribe.EchoScribe",
                                            account: "openai_api_key")

    /// nil means "no item stored"; any other failure throws KeychainReadError.
    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return try KeychainStore.interpretRead(status: status, item: item)
    }

    /// Whether an edited key-field value may be written back. A cleared field
    /// is only a delete instruction when the previous read SUCCEEDED — after a
    /// failed read the empty field was the app's invention, and saving it would
    /// delete a key that may really be stored. (Unit-tested; ContentView
    /// consults this before persisting an edit.)
    static func shouldPersist(newValue: String, readFailed: Bool) -> Bool {
        !(newValue.isEmpty && readFailed)
    }

    /// Pure mapping from a SecItemCopyMatching result (unit-tested): the value,
    /// nil for "no item", or a throw for everything else — including a success
    /// payload that isn't decodable UTF-8 text, which must not masquerade as
    /// "missing".
    static func interpretRead(status: OSStatus, item: CFTypeRef?) throws -> String? {
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainReadError(status: errSecDecode)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainReadError(status: status)
        }
    }

    /// Saves the value, overwriting any existing item. Empty string deletes.
    @discardableResult
    func save(_ value: String) -> Bool {
        if value.isEmpty { return delete() }
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Idempotent: deleting a missing item counts as success.
    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
