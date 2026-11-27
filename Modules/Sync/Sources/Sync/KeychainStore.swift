import Foundation
import Security

/// Minimal seam over the four SecItem calls ``AnthropicKeychain`` makes, so its
/// update-in-place replace, read, and delete semantics are testable without ever touching the
/// real login keychain. The only conformance outside tests is the SecItem-backed default.
public protocol KeychainStore {
    /// `SecItemDelete`.
    @discardableResult
    func delete(_ query: [String: Any]) -> OSStatus
    /// `SecItemAdd` (no returned item — every caller here ignores it).
    @discardableResult
    func add(_ attributes: [String: Any]) -> OSStatus
    /// `SecItemCopyMatching`.
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?)
    /// `SecItemUpdate` — `errSecItemNotFound` when nothing matches `query`.
    @discardableResult
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
}

/// The real macOS login keychain, via the SecItem C API. Stateless: every call is a pass-through,
/// so all testable logic lives above the seam (in ``AnthropicKeychain``).
///
/// Every call is pinned to the login keychain (``loginOnly(_:)``). Unpinned, a copy that carries
/// the keychain permission (the installed one, VT31) reaches the data-protection keychain too: a
/// delete removes the match from both, and a read returns the data-protection item first. So the
/// Vault's move behind Touch ID, removing the login keychain's copy, deleted the key it had just
/// moved (2026-11-26).
public struct SecItemKeychainStore: KeychainStore {
    /// The four SecItem calls, the real ones but in a test, which sees what each is sent.
    struct Calls {
        var delete: @Sendable (CFDictionary) -> OSStatus = { SecItemDelete($0) }
        var add: @Sendable (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
        var copyMatching: @Sendable (CFDictionary, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus = { SecItemCopyMatching($0, $1) }
        var update: @Sendable (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) }
    }

    private let calls: Calls

    public init() { calls = Calls() }

    init(calls: Calls) { self.calls = calls }

    /// `query` for the login keychain alone. A caller's own choice of keychain is kept.
    static func loginOnly(_ query: [String: Any]) -> [String: Any] {
        var pinned = query
        if pinned[kSecUseDataProtectionKeychain as String] == nil {
            pinned[kSecUseDataProtectionKeychain as String] = false
        }
        return pinned
    }

    @discardableResult
    public func delete(_ query: [String: Any]) -> OSStatus {
        calls.delete(Self.loginOnly(query) as CFDictionary)
    }

    @discardableResult
    public func add(_ attributes: [String: Any]) -> OSStatus {
        calls.add(Self.loginOnly(attributes) as CFDictionary)
    }

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        var result: CFTypeRef?
        let status = calls.copyMatching(Self.loginOnly(query) as CFDictionary, &result)
        return (status, result)
    }

    @discardableResult
    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        calls.update(Self.loginOnly(query) as CFDictionary, attributes as CFDictionary)
    }
}
