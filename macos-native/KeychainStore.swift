import Foundation
import Security

/// Minimal generic-password Keychain wrapper for the Gemini API key.
/// (The key previously lived in UserDefaults; ContentView migrates it once.)
struct KeychainStore {
    let service: String
    let account: String

    static let geminiAPIKey = KeychainStore(service: "com.echoscribe.EchoScribe",
                                            account: "gemini_api_key")

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
