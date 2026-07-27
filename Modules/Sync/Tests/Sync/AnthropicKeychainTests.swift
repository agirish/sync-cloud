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
    /// The query of the last `copyMatching`. What a lookup ASKS FOR is the whole difference
    /// between a silent existence check and one that raises the Keychain password prompt.
    private(set) var lastCopyQuery: [String: Any]?
    /// The one item slot. Settable directly to pre-populate.
    var itemData: Data?
    /// When set, `copyMatching` returns this status regardless of the slot.
    var forcedCopyStatus: OSStatus?
    /// When set, `delete` refuses with this status and LEAVES the item in place — what a locked
    /// keychain, a denied prompt or an MDM policy actually does. The slot surviving is the point:
    /// a fake that cleared it anyway could not tell a reported failure from a silent one.
    var forcedDeleteStatus: OSStatus?

    func delete(_ query: [String: Any]) -> OSStatus {
        ops.append(.delete)
        if let forced = forcedDeleteStatus { return forced }
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
        lastCopyQuery = query
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

    // MARK: - Existence without the prompt

    /// The property the Settings tab depends on: asking whether a key is stored must never ask
    /// the Keychain for the secret, because `kSecReturnData` is exactly what makes it evaluate
    /// the item's ACL and put a password prompt on screen. Opening the Tidy tab used to run
    /// `hasKey`, so merely *looking at* Settings demanded the password.
    ///
    /// Pinned on the QUERY rather than on a return value: a fake cannot show a prompt, so the
    /// only honest way to assert "this can't prompt" is to assert what it asked for.
    @Test func isConfiguredNeverAsksForTheSecret() {
        let store = FakeKeychainStore()
        store.itemData = Data("sk-ant-test".utf8)

        #expect(AnthropicKeychain.isConfigured(in: store))

        let query = store.lastCopyQuery
        #expect(query?[kSecReturnData as String] == nil,
                "an existence check that requests the data can raise the Keychain prompt")
        #expect(query?[kSecReturnAttributes as String] as? Bool == true)
        #expect(query?[kSecAttrService as String] as? String == "com.synccloud.anthropic-api-key")
    }

    /// The counterpart, and the reason `isConfigured` had to be a second question rather than a
    /// rewrite of `hasKey`: callers about to USE the key still read it, and the scan path's
    /// "cloud is on but the key is unusable" downgrade rests on that read failing.
    @Test func hasKeyStillReadsTheSecret() {
        let store = FakeKeychainStore()
        store.itemData = Data("sk-ant-test".utf8)

        #expect(AnthropicKeychain.hasKey(in: store))
        #expect(store.lastCopyQuery?[kSecReturnData as String] as? Bool == true)
    }

    @Test func isConfiguredIsFalseWithNothingStored() {
        let store = FakeKeychainStore()
        #expect(AnthropicKeychain.isConfigured(in: store) == false)
    }

    /// A key the Keychain refuses to hand over is still *configured* — the item is there. That
    /// is the honest answer for a status line, and it is why this must not route a cloud call:
    /// `hasKey` reports the same item as unusable, which is what the downgrade warning needs.
    @Test func isConfiguredAndHasKeyDisagreeOnAnUnreadableItem() {
        let locked = FakeKeychainStore()
        locked.itemData = Data("sk-ant-test".utf8)
        // The realistic locked case: attributes come back, the secret does not.
        #expect(AnthropicKeychain.isConfigured(in: locked))

        locked.forcedCopyStatus = errSecInteractionNotAllowed
        #expect(AnthropicKeychain.hasKey(in: locked) == false)
    }

    @Test func deleteRemovesTheStoredKey() {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("sk-ant-test", in: store)
        #expect(AnthropicKeychain.hasKey(in: store))

        #expect(AnthropicKeychain.delete(from: store) == errSecSuccess)

        #expect(AnthropicKeychain.read(from: store) == nil)
        #expect(AnthropicKeychain.hasKey(in: store) == false)
    }

    /// Deleting nothing is success from every caller's point of view — the item is gone, which is
    /// what was asked for. Pinned so the status check above can't be tightened into treating an
    /// already-absent key as a refusal.
    @Test func deletingAnAbsentKeyIsNotAFailure() {
        let store = FakeKeychainStore()

        #expect(AnthropicKeychain.delete(from: store) == errSecItemNotFound)
        #expect(AnthropicKeychain.isConfigured(in: store) == false)
    }

    /// The failure the returned status exists for. A delete can be refused exactly as a write can
    /// — locked keychain, denied prompt, MDM policy — and the Settings row used to flip to "No key
    /// yet" regardless, telling the user their API key was gone while it was still in the Keychain,
    /// still used by every scan, and back on screen at the next launch.
    ///
    /// Two assertions, because either alone would pass against the broken version: the status must
    /// come back non-success, AND the item must still be findable — which is what the row now
    /// re-reads (via `isConfigured`) instead of assuming.
    @Test func aRefusedDeleteReportsFailureAndLeavesTheKeyInPlace() {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("sk-ant-test", in: store)
        store.forcedDeleteStatus = errSecInteractionNotAllowed

        let status = AnthropicKeychain.delete(from: store)

        #expect(status == errSecInteractionNotAllowed)
        #expect(AnthropicKeychain.isConfigured(in: store),
                "the key is still stored, so anything reporting 'no key' after this is lying")
    }

    /// A refused delete must reach the log too, for the same reason a refused read does: the app's
    /// own key-clearing paths take the `@discardableResult` spelling and would otherwise leave no
    /// trace of why the key kept coming back.
    @MainActor
    @Test func aRefusedDeleteIsLogged() async {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("sk-ant-test", in: store)
        store.forcedDeleteStatus = errSecInteractionNotAllowed

        AnthropicKeychain.delete(from: store)

        await waitUntil("the refused delete is logged") {
            Logger.shared.entries.contains {
                $0.level == .warning && $0.message.contains("refused to delete the stored item")
            }
        }
    }
}
