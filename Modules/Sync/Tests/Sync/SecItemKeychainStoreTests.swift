import Testing
import Foundation
import Security
@testable import Sync

/// The login keychain store sends every call to the login keychain alone. Unpinned, the installed
/// copy (which holds the keychain permission) reached the data-protection keychain too, and the
/// Vault's move behind Touch ID deleted the key it had just moved (2026-11-26). No real keychain
/// is touched: the store is given recording calls.
@Suite struct SecItemKeychainStoreTests {
    private final class Sent: @unchecked Sendable {
        var queries: [String: [String: Any]] = [:]
        var updateAttributes: [String: Any]?
    }

    private func recording() -> (SecItemKeychainStore, Sent) {
        let sent = Sent()
        var calls = SecItemKeychainStore.Calls()
        calls.delete = { sent.queries["delete"] = $0 as? [String: Any]; return errSecSuccess }
        calls.add = { sent.queries["add"] = $0 as? [String: Any]; return errSecSuccess }
        calls.copyMatching = { query, _ in sent.queries["copy"] = query as? [String: Any]; return errSecItemNotFound }
        calls.update = { query, attributes in
            sent.queries["update"] = query as? [String: Any]
            sent.updateAttributes = attributes as? [String: Any]
            return errSecSuccess
        }
        return (SecItemKeychainStore(calls: calls), sent)
    }

    /// The Vault key's own query, as the move removes the login keychain's copy with it.
    private let vaultKey: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: "com.synccloud.vault-key",
                                           kSecAttrAccount as String: "default"]

    @Test func everyCallIsPinnedToTheLoginKeychain() {
        let (store, sent) = recording()
        store.delete(vaultKey)
        store.add(vaultKey.merging([kSecValueData as String: Data([1])]) { $1 })
        _ = store.copyMatching(vaultKey)
        store.update(vaultKey, attributes: [kSecValueData as String: Data([2])])
        #expect(Set(sent.queries.keys) == ["delete", "add", "copy", "update"])
        for (call, query) in sent.queries {
            #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false, "\(call) reaches the data-protection keychain")
            #expect(query[kSecAttrService as String] as? String == "com.synccloud.vault-key", "\(call) lost the caller's query")
        }
        #expect(sent.updateAttributes?[kSecUseDataProtectionKeychain as String] == nil, "the pin is a query term, not an attribute to write")
    }

    @Test func aCallersOwnChoiceOfKeychainIsKept() {
        let (store, sent) = recording()
        store.delete(vaultKey.merging([kSecUseDataProtectionKeychain as String: true]) { $1 })
        #expect(sent.queries["delete"]?[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }
}
