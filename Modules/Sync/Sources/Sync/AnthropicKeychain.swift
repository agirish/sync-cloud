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
    public static func store(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(); return }
        let data = Data(trimmed.utf8)
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)   // idempotent replace
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    /// The stored key, or nil when none is set.
    public static func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    public static func delete() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// True when a non-empty key is stored.
    public static var hasKey: Bool { read() != nil }
}
