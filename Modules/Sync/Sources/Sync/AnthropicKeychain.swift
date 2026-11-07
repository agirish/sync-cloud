import Events
import Foundation
import Security

/// Stores the user's Anthropic API key in the macOS Keychain (opt-in cloud Filing). The secret
/// never lives in UserDefaults or on disk in the clear. Shared by the app (which reads it to make
/// the API call) and Settings (which writes it).
public enum AnthropicKeychain {
    private static let service = "com.synccloud.anthropic-api-key"
    /// Posted after the key is stored, replaced or deleted, so a reader holding a copy (Ask
    /// Claude reads it once per chat) lets it go.
    public static let didChange = Notification.Name("AnthropicKeychainDidChange")
    private static let account = "default"

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Stores (or replaces) the key. An empty string deletes it.
    /// - Returns: The write's status: `SecItemUpdate`'s over an existing item, `SecItemAdd`'s when
    ///   there was none. A keychain write can fail (locked or denied keychain, an MDM policy), and
    ///   swallowing that would let the user believe a key was saved while scans quietly fall back
    ///   to the on-device model. Deleting by passing "" reports success.
    ///
    /// Replaced in place, **never deleted first**: a delete then a refused add would leave no key
    /// at all. A refused update leaves the old key exactly as it was.
    @discardableResult
    public static func store(_ key: String, in store: KeychainStore = SecItemKeychainStore()) -> OSStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(from: store); return errSecSuccess }
        let secret: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        // The update changes the secret and nothing else. Without
        // `kSecUseDataProtectionKeychain` the item lives in the file-based keychain, which uses
        // ACLs, not the data-protection classes `kSecAttrAccessible` names (TN3137). Changing that
        // attribute there via `SecItemUpdate` is undocumented and may fail with `errSecParam`, so
        // only the add sets it. Checked against a fake only; the tests never touch the real
        // login keychain.
        defer { NotificationCenter.default.post(name: didChange, object: nil) }
        let updated = store.update(baseQuery(), attributes: secret)
        let status = updated != errSecItemNotFound ? updated
            : store.add(baseQuery().merging(secret) { _, new in new }
                .merging([kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { _, new in new })
        // A refusal was only on screen. The status and which write it was; never the key.
        if status != errSecSuccess {
            log("Anthropic API key: the Keychain refused to save it (\(updated == errSecItemNotFound ? "add" : "update"), "
                + "status \(status)); the key in use is unchanged")
        }
        return status
    }

    /// What a read of the stored key found, which `read(from:)`'s `nil` can't express: "no key
    /// configured" versus "a key exists but the keychain won't hand it over now" (locked,
    /// `errSecInteractionNotAllowed`; denied, `errSecAuthFailed`; or an MDM policy). Without it the
    /// app would fall back to the on-device model as though the user had never opted in.
    public enum ReadOutcome: Equatable, Sendable {
        /// A usable key is stored.
        case found(String)
        /// Nothing is stored, or it is empty: the user has not configured a key.
        case notConfigured
        /// The keychain refused or couldn't decode the item. A key may be there but can't be used
        /// now, so callers say that instead of "no key". Carries the raw `OSStatus` for the log.
        case unreadable(OSStatus)

        /// The key when one was readable, matching ``AnthropicKeychain/read(from:)``.
        public var key: String? {
            if case .found(let key) = self { return key }
            return nil
        }
    }

    /// The stored key, or nil when none is set. Callers that must tell "never configured" from
    /// "unreadable right now" use ``readOutcome(from:)``.
    public static func read(from store: KeychainStore = SecItemKeychainStore()) -> String? {
        readOutcome(from: store).key
    }

    /// ``read(from:)`` with the reason attached. A failure is logged here, the seam every read goes
    /// through, so it is on record even for callers that only take the `String?`.
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
            // The item is there but its bytes are not a key (corrupt, or written by something
            // else). "Not configured" would have the user re-enter a key that is already present.
            log("Anthropic API key: the stored Keychain item is not decodable text (\(data.count) byte(s)) — it cannot be used; re-save the key to replace it")
            return .unreadable(errSecDecode)
        }
        return .found(key)
    }

    /// Logs synchronously: `Logger.warning` is `nonisolated` and enqueues before it returns. A
    /// `Task { @MainActor in … }` hop would enqueue it after the call returned, where a
    /// `LogCapture` read could miss it (`docs/flaky-tests.md`).
    private static func log(_ message: String) {
        Logger.shared.warning(message)
    }

    /// Removes the stored key.
    /// - Returns: The `SecItemDelete` status. `errSecItemNotFound` means there was nothing to
    ///   remove, which is success to any caller.
    ///
    /// A delete can be refused like a write, and a UI that says "no key" after an unverified delete
    /// tells the user the key is gone while it is still in the Keychain and still usable. Callers
    /// that act on the outcome confirm with ``isConfigured``, which never asks for the secret.
    @discardableResult
    public static func delete(from store: KeychainStore = SecItemKeychainStore()) -> OSStatus {
        let status = store.delete(baseQuery())
        NotificationCenter.default.post(name: didChange, object: nil)
        if status != errSecSuccess, status != errSecItemNotFound {
            log("Anthropic API key: the Keychain refused to delete the stored item (status \(status)) — the key is still there")
        }
        return status
    }

    /// True when a non-empty, *readable* key is stored. It reads the secret, so it can raise the
    /// Keychain prompt: right for callers about to use the key, wrong for anything that only wants
    /// to say "a key is saved". Those use ``isConfigured``.
    public static var hasKey: Bool { hasKey(in: SecItemKeychainStore()) }

    /// `hasKey` against an injected store (the testable spelling of the property above).
    public static func hasKey(in store: KeychainStore) -> Bool { read(from: store) != nil }

    /// Whether a key item exists at all, **without decrypting it**, so it never raises the
    /// Keychain password prompt. `kSecReturnData` is what makes the Keychain check the ACL and ask;
    /// an attributes-only match reads metadata only. Use it to show "Key saved".
    ///
    /// It can't tell a usable key from a refused or corrupt one. **Never** route a cloud call on
    /// it: `hasKey` is the question there, gated behind the cloud toggle so it asks only when
    /// the key is wanted.
    public static var isConfigured: Bool { isConfigured(in: SecItemKeychainStore()) }

    /// ``isConfigured`` against an injected store.
    public static func isConfigured(in store: KeychainStore) -> Bool {
        var query = baseQuery()
        // Attributes, not data: `kSecReturnData` here would raise the prompt this avoids.
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return store.copyMatching(query).status == errSecSuccess
    }
}
