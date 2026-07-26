import Testing
import Foundation
import Security
import Events
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

    /// `read`'s `String?` collapses "the user never configured a key" and "the Keychain refused to
    /// hand the key over right now" (locked keychain, denied prompt, MDM policy) into one `nil`, so
    /// the app fell back to the on-device model as though cloud Filing had never been opted into —
    /// the same invisible failure `store` returns its status to avoid. `readOutcome` separates them.
    @Test func readOutcomeTellsAMissingKeyApartFromAnUnreadableOne() {
        let empty = FakeKeychainStore()
        #expect(AnthropicKeychain.readOutcome(from: empty) == .notConfigured)

        let locked = FakeKeychainStore()
        locked.itemData = Data("sk-ant-test".utf8)          // a key IS stored…
        locked.forcedCopyStatus = errSecInteractionNotAllowed  // …but the keychain is locked
        #expect(AnthropicKeychain.readOutcome(from: locked) == .unreadable(errSecInteractionNotAllowed))

        // An item that is present but not decodable text is likewise "there but unusable", not
        // "never configured" — telling the user to re-enter a key that is already there is wrong.
        let garbage = FakeKeychainStore()
        garbage.itemData = Data([0xFF, 0xFE, 0xFD])
        #expect(AnthropicKeychain.readOutcome(from: garbage) == .unreadable(errSecDecode))

        // A stored EMPTY item genuinely means unconfigured (`store("")` deletes).
        let blank = FakeKeychainStore()
        blank.itemData = Data()
        #expect(AnthropicKeychain.readOutcome(from: blank) == .notConfigured)

        let configured = FakeKeychainStore()
        AnthropicKeychain.store("sk-ant-test", in: configured)
        #expect(AnthropicKeychain.readOutcome(from: configured) == .found("sk-ant-test"))

        // The change is additive: every existing caller's `String?` spelling is unchanged.
        #expect(AnthropicKeychain.read(from: empty) == nil)
        #expect(AnthropicKeychain.read(from: locked) == nil)
        #expect(AnthropicKeychain.read(from: garbage) == nil)
        #expect(AnthropicKeychain.read(from: configured) == "sk-ant-test")
        #expect(AnthropicKeychain.hasKey(in: locked) == false)
    }

    /// A refusing keychain must also reach the log, so callers that keep the plain `String?`
    /// spelling (the app's `readAPIKey` seam) still leave a trace of WHY cloud Filing went quiet.
    @MainActor
    @Test func anUnreadableKeychainIsLogged() async {
        let locked = FakeKeychainStore()
        locked.itemData = Data("sk-ant-test".utf8)
        locked.forcedCopyStatus = errSecInteractionNotAllowed

        _ = AnthropicKeychain.read(from: locked)

        await waitUntil("the refusing keychain is logged") {
            Logger.shared.entries.contains {
                $0.level == .warning && $0.message.contains("a stored key may exist but cannot be read right now")
            }
        }
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
