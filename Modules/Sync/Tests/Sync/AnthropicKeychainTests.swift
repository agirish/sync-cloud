import Testing
import Foundation
import Security
@testable import Sync

/// An in-memory ``KeychainStore`` holding the single item slot the helper manages, recording the
/// operation sequence — tests must NEVER touch the real login keychain.
private final class FakeKeychainStore: KeychainStore, @unchecked Sendable {
    enum Op: Equatable { case delete, add, copy }

    private(set) var ops: [Op] = []
    /// The attribute dictionary of the last `add`, so tests can pin the item's identity.
    private(set) var lastAddedAttributes: [String: Any]?
    /// The one item slot. Settable directly to pre-populate.
    var itemData: Data?
    /// When set, `copyMatching` returns this status regardless of the slot.
    var forcedCopyStatus: OSStatus?

    func delete(_ query: [String: Any]) -> OSStatus {
        ops.append(.delete)
        let had = itemData != nil
        itemData = nil
        return had ? errSecSuccess : errSecItemNotFound
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        ops.append(.add)
        lastAddedAttributes = attributes
        itemData = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        ops.append(.copy)
        if let forced = forcedCopyStatus { return (forced, nil) }
        guard let data = itemData else { return (errSecItemNotFound, nil) }
        guard query[kSecReturnData as String] as? Bool == true else { return (errSecSuccess, nil) }
        return (errSecSuccess, data as AnyObject)
    }
}

@Suite struct AnthropicKeychainTests {

    @Test func storeTrimsTheKeyAndReplacesViaDeleteThenAdd() throws {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("  sk-ant-test \n", in: store)

        // The idempotent-replace shape: always a delete FIRST, then the add.
        #expect(store.ops == [.delete, .add])
        #expect(AnthropicKeychain.read(from: store) == "sk-ant-test")

        // Pin the item's identity + protection class: a drifted service/account string would
        // silently orphan the user's already-stored key.
        let attrs = try #require(store.lastAddedAttributes)
        #expect(attrs[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attrs[kSecAttrService as String] as? String == "com.synccloud.anthropic-api-key")
        #expect(attrs[kSecAttrAccount as String] as? String == "default")
        #expect(attrs[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
    }

    @Test func storeAgainReplacesThePreviousKey() {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("first-key", in: store)
        AnthropicKeychain.store("second-key", in: store)

        #expect(store.ops == [.delete, .add, .delete, .add])
        #expect(AnthropicKeychain.read(from: store) == "second-key")
    }

    @Test func storeEmptyOrWhitespaceStringDeletesTheKey() {
        for empty in ["", "   ", " \n\t "] {
            let store = FakeKeychainStore()
            store.itemData = Data("old-key".utf8)

            AnthropicKeychain.store(empty, in: store)

            #expect(store.ops == [.delete], "an effectively-empty key must delete, never add: \(empty.debugDescription)")
            #expect(AnthropicKeychain.read(from: store) == nil)
        }
    }

    @Test func readReturnsNilWhenNoItemIsStored() {
        let store = FakeKeychainStore()
        #expect(AnthropicKeychain.read(from: store) == nil)
        #expect(AnthropicKeychain.hasKey(in: store) == false)
    }

    @Test func readMapsANonSuccessStatusToNil() {
        let store = FakeKeychainStore()
        store.itemData = Data("sk-ant-test".utf8)
        store.forcedCopyStatus = errSecAuthFailed
        #expect(AnthropicKeychain.read(from: store) == nil)
    }

    @Test func readTreatsEmptyOrUndecodableDataAsNoKey() {
        let store = FakeKeychainStore()
        store.itemData = Data()
        #expect(AnthropicKeychain.read(from: store) == nil)

        store.itemData = Data([0xFF, 0xFE, 0xFD])   // not valid UTF-8
        #expect(AnthropicKeychain.read(from: store) == nil)
    }

    @Test func deleteRemovesTheStoredKey() {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("sk-ant-test", in: store)
        #expect(AnthropicKeychain.hasKey(in: store))

        AnthropicKeychain.delete(from: store)

        #expect(AnthropicKeychain.read(from: store) == nil)
        #expect(AnthropicKeychain.hasKey(in: store) == false)
    }
}
