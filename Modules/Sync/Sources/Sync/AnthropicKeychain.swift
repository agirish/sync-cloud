import Events
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

    /// What a read of the stored key found — the difference `read(from:)`'s `nil` cannot express.
    ///
    /// "No key was ever configured" and "a key exists but the keychain would not hand it over
    /// right now" (a locked keychain returns `errSecInteractionNotAllowed`, a denied prompt
    /// `errSecAuthFailed`, an MDM policy its own status) are the same `nil` to a caller, so the
    /// app silently fell back to the on-device model as though the user had never opted in —
    /// exactly the invisible failure ``store(_:in:)`` returns its status to avoid.
    public enum ReadOutcome: Equatable, Sendable {
        /// A usable key is stored.
        case found(String)
        /// Nothing is stored (or what is stored is empty) — the user has not configured a key.
        case notConfigured
        /// The keychain refused or could not decode the item. A key may well be there; this
        /// says only that it cannot be used right now, so callers can say so instead of
        /// reporting "no key". Carries the raw `OSStatus` for the log/diagnostics.
        case unreadable(OSStatus)

        /// The key when one was readable, matching ``AnthropicKeychain/read(from:)``.
        public var key: String? {
            if case .found(let key) = self { return key }
            return nil
        }
    }

    /// The stored key, or nil when none is set — kept as the simple spelling every existing
    /// caller uses. Callers that must distinguish "never configured" from "temporarily
    /// unreadable" use ``readOutcome(from:)``.
    public static func read(from store: KeychainStore = SecItemKeychainStore()) -> String? {
        readOutcome(from: store).key
    }

    /// ``read(from:)`` with the reason attached. A non-success status is also logged here (once,
    /// at the seam every read goes through) so the failure is on the record even for callers that
    /// only take the `String?`.
    public static func readOutcome(from store: KeychainStore = SecItemKeychainStore()) -> ReadOutcome {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = store.copyMatching(query)
        if status == errSecItemNotFound { return .notConfigured }
        guard status == errSecSuccess else {
            log("Anthropic API key: the Keychain returned status \(status) — a stored key may exist but cannot be read right now (locked Keychain, denied prompt, or policy)")
            return .unreadable(status)
        }
        guard let data = result as? Data, !data.isEmpty else { return .notConfigured }
        guard let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            // The item is there but its bytes are not a key — corrupt, or written by something
            // else under this service/account. Reporting "not configured" would invite the user
            // to "re-enter" a key that is already present and would keep failing.
            log("Anthropic API key: the stored Keychain item is not decodable text (\(data.count) byte(s)) — it cannot be used; re-save the key to replace it")
            return .unreadable(errSecDecode)
        }
        return .found(key)
    }

    /// Hops the (nonisolated, static) reads onto the MainActor logger, the same way the
    /// nonisolated file primitives do.
    private static func log(_ message: String) {
        Task { @MainActor in Logger.shared.warning(message) }
    }

    public static func delete(from store: KeychainStore = SecItemKeychainStore()) {
        store.delete(baseQuery())
    }

    /// True when a non-empty key is stored.
    public static var hasKey: Bool { hasKey(in: SecItemKeychainStore()) }

    /// `hasKey` against an injected store (the testable spelling of the property above).
    public static func hasKey(in store: KeychainStore) -> Bool { read(from: store) != nil }
}
