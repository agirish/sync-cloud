import Foundation
import Security

/// Minimal seam over the three SecItem calls ``AnthropicKeychain`` makes, so its
/// delete-then-add replace, read, and delete semantics are testable without ever touching the
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
}

/// The real macOS Keychain, via the SecItem C API. Stateless — every call is a 1:1 pass-through,
/// so all testable logic lives above the seam (in ``AnthropicKeychain``).
public struct SecItemKeychainStore: KeychainStore {
    public init() {}

    @discardableResult
    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    @discardableResult
    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
}
