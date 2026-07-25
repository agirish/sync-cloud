import Foundation
import Security

/// Stores the user's Anthropic API key in the macOS Keychain (opt-in cloud Filing). The secret
/// never lives in UserDefaults or on disk in the clear. Shared by the app (which reads it to make
/// the API call) and Settings (which writes it).
public enum AnthropicKeychain {
    private static let service = "com.synccloud.anthropic-api-key"
    private static let account = "default"

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Stores (or replaces) the key. An empty string deletes it.
    /// - Returns: The `SecItemAdd` status — `errSecSuccess` on a real write. Returned rather than
    ///   discarded because a keychain write genuinely can fail (locked or denied keychain, an MDM
    ///   policy), and swallowing that left the user believing a key was saved that was not: the
    ///   next scan then found no key and quietly fell back to the on-device model with nothing
    ///   anywhere to explain it. Deleting an existing key by passing "" reports success.
    @discardableResult
    public static func store(_ key: String, in store: KeychainStore = SecItemKeychainStore()) -> OSStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(from: store); return errSecSuccess }
        let data = Data(trimmed.utf8)
        var query = baseQuery()
        store.delete(query)   // idempotent replace
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return store.add(query)
    }

    /// The stored key, or nil when none is set.
    public static func read(from store: KeychainStore = SecItemKeychainStore()) -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = store.copyMatching(query)
        guard status == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    public static func delete(from store: KeychainStore = SecItemKeychainStore()) {
        store.delete(baseQuery())
    }

    /// True when a non-empty key is stored.
    public static var hasKey: Bool { hasKey(in: SecItemKeychainStore()) }

    /// `hasKey` against an injected store (the testable spelling of the property above).
    public static func hasKey(in store: KeychainStore) -> Bool { read(from: store) != nil }
}
