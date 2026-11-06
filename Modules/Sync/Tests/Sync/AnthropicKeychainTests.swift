import Testing
import Foundation
import Security
import Events
import EventsTestSupport
@testable import Sync

/// An in-memory ``KeychainStore`` holding the single item slot the helper manages, recording the
/// operation sequence — tests must NEVER touch the real login keychain.
private final class FakeKeychainStore: KeychainStore, @unchecked Sendable {
    enum Op: Equatable { case delete, add, copy, update }

    private(set) var ops: [Op] = []
    /// The attribute dictionary of the last `add`, so tests can pin the item's identity.
    private(set) var lastAddedAttributes: [String: Any]?
    /// The attributes of the last successful `update`.
    private(set) var lastUpdatedAttributes: [String: Any]?
    /// The query of the last `copyMatching`. What a lookup asks for is the difference between a
    /// silent existence check and one that raises the Keychain password prompt.
    private(set) var lastCopyQuery: [String: Any]?
    /// The one item slot. Settable directly to pre-populate.
    var itemData: Data?
    /// When set, `copyMatching` returns this status regardless of the slot.
    var forcedCopyStatus: OSStatus?
    /// When set, `delete` refuses with this status and leaves the item in place, as a locked
    /// keychain, a denied prompt or an MDM policy does; a fake that cleared it couldn't tell a
    /// reported failure from a silent one.
    var forcedDeleteStatus: OSStatus?
    /// When set, `update` and `add` refuse with this status and write nothing — a locked keychain
    /// refusing the write, which it can do after allowing a delete.
    var forcedWriteStatus: OSStatus?

    func delete(_ query: [String: Any]) -> OSStatus {
        ops.append(.delete)
        if let forced = forcedDeleteStatus { return forced }
        let had = itemData != nil
        itemData = nil
        return had ? errSecSuccess : errSecItemNotFound
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        ops.append(.add)
        if let forced = forcedWriteStatus { return forced }
        if itemData != nil { return errSecDuplicateItem }
        lastAddedAttributes = attributes
        itemData = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        ops.append(.update)
        if let forced = forcedWriteStatus { return forced }
        guard itemData != nil else { return errSecItemNotFound }
        lastUpdatedAttributes = attributes
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

    @Test func storeTrimsTheKeyAndAddsWhenNothingIsStored() throws {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("  sk-ant-test \n", in: store)

        // Nothing to update, so the add, and never a delete.
        #expect(store.ops == [.update, .add])
        #expect(AnthropicKeychain.read(from: store) == "sk-ant-test")

        // Pin the item's identity + protection class: a drifted service/account string would
        // silently orphan the user's already-stored key.
        let attrs = try #require(store.lastAddedAttributes)
        #expect(attrs[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(attrs[kSecAttrService as String] as? String == "com.synccloud.anthropic-api-key")
        #expect(attrs[kSecAttrAccount as String] as? String == "default")
        #expect(attrs[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
    }

    @Test func storeAgainReplacesThePreviousKey() throws {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("first-key", in: store)
        AnthropicKeychain.store("second-key", in: store)

        // Replaced in place: one update, no delete.
        #expect(store.ops == [.update, .add, .update])
        #expect(AnthropicKeychain.read(from: store) == "second-key")
        // The update carries the secret and nothing else. Changing `kSecAttrAccessible` in
        // `SecItemUpdate` on the file-based keychain is undocumented and could be refused, so
        // accessibility stays as the add set it, which the test above pins.
        let attrs = try #require(store.lastUpdatedAttributes)
        #expect(Set(attrs.keys) == [kSecValueData as String],
                "the update asks to change more than the key: \(attrs.keys.sorted())")
        #expect(attrs[kSecValueData as String] as? Data == Data("second-key".utf8))
    }

    /// A refused write keeps the key that was stored: a replace that deleted first could leave no
    /// key at all. The status must come back non-success and the old key must still read back.
    @Test func aRefusedReplaceLeavesTheOldKeyInPlace() {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("old-key", in: store)
        store.forcedWriteStatus = errSecInteractionNotAllowed

        #expect(AnthropicKeychain.store("new-key", in: store) == errSecInteractionNotAllowed)
        #expect(!store.ops.contains(.delete), "the replace deleted the stored key: \(store.ops)")
        store.forcedWriteStatus = nil
        #expect(AnthropicKeychain.read(from: store) == "old-key", "a refused replace lost the stored key")
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

    /// `read`'s `String?` folds "never configured" and "the Keychain refused right now" into one
    /// `nil`, which would silently drop cloud Filing to the on-device model. `readOutcome` keeps
    /// them apart.
    @Test func readOutcomeTellsAMissingKeyApartFromAnUnreadableOne() {
        let empty = FakeKeychainStore()
        #expect(AnthropicKeychain.readOutcome(from: empty) == .notConfigured)

        let locked = FakeKeychainStore()
        locked.itemData = Data("sk-ant-test".utf8)          // a key IS stored…
        locked.forcedCopyStatus = errSecInteractionNotAllowed  // …but the keychain is locked
        #expect(AnthropicKeychain.readOutcome(from: locked) == .unreadable(errSecInteractionNotAllowed))

        // Present but not decodable text is likewise "there but unusable", not "never configured":
        // the user shouldn't be told to re-enter a key that is already there.
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

    /// A refusing keychain must also reach the log, so callers of the plain `String?` spelling
    /// (the app's `readAPIKey` seam) still leave a trace of why cloud Filing went quiet.
    ///
    /// Captured, not read from the shared buffer: `Logger.shared.entries` keeps only the newest
    /// lines for the whole process, and in a full package run other suites log past this one.
    /// `LogCapture`, opened before the read, keeps each line as it is published.
    @MainActor
    @Test func anUnreadableKeychainIsLogged() async {
        let log = LogCapture()
        let locked = FakeKeychainStore()
        locked.itemData = Data("sk-ant-test".utf8)
        locked.forcedCopyStatus = errSecInteractionNotAllowed

        // Imitates a parallel suite's logging: a flush already queued ahead of the call. The
        // capture's marker joins it, so this passes only if the warning is enqueued by the time the
        // call returns; a `Task { @MainActor in … }` hop would land it late.
        Logger.shared.debug("a sibling suite's line, its flush still queued")
        _ = AnthropicKeychain.read(from: locked)

        #expect(await log.holds(.warning, containing: "a stored key may exist but cannot be read right now"),
                "a refusing keychain left no warning in the log")
    }

    // MARK: - Existence without the prompt

    /// Asking whether a key is stored must never ask the Keychain for the secret: `kSecReturnData`
    /// makes it evaluate the item's ACL and show a password prompt, so merely opening Settings
    /// would demand the password. Pinned on the query, since a fake can't show a prompt.
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

    /// The counterpart, and why `isConfigured` is a second question rather than a rewrite of
    /// `hasKey`: callers about to use the key still read it, and the scan's "key is unusable"
    /// downgrade rests on that read failing.
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

    /// A key the Keychain refuses to hand over is still configured: the item is there. Right for
    /// a status line, so this must not route a cloud call; `hasKey` reports the same item as
    /// unusable, which the downgrade warning needs.
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

    /// Deleting nothing is success: the item is gone, as asked. Pinned so the status check can't
    /// be tightened into treating an already-absent key as a refusal.
    @Test func deletingAnAbsentKeyIsNotAFailure() {
        let store = FakeKeychainStore()

        #expect(AnthropicKeychain.delete(from: store) == errSecItemNotFound)
        #expect(AnthropicKeychain.isConfigured(in: store) == false)
    }

    /// A delete can be refused like a write (locked keychain, denied prompt, MDM policy), and the
    /// Settings row must not then say "No key yet" while the key is still stored and used. So the
    /// status comes back non-success and the item is still findable, which the row re-reads via
    /// `isConfigured`.
    @Test func aRefusedDeleteReportsFailureAndLeavesTheKeyInPlace() {
        let store = FakeKeychainStore()
        AnthropicKeychain.store("sk-ant-test", in: store)
        store.forcedDeleteStatus = errSecInteractionNotAllowed

        let status = AnthropicKeychain.delete(from: store)

        #expect(status == errSecInteractionNotAllowed)
        #expect(AnthropicKeychain.isConfigured(in: store),
                "the key is still stored, so anything reporting 'no key' after this is lying")
    }

    /// A refused delete must reach the log too: the app's key-clearing paths discard the result,
    /// and would otherwise leave no trace of why the key kept coming back.
    ///
    /// Captured for the same reason as ``anUnreadableKeychainIsLogged``.
    @MainActor
    @Test func aRefusedDeleteIsLogged() async {
        let log = LogCapture()
        let store = FakeKeychainStore()
        AnthropicKeychain.store("sk-ant-test", in: store)
        store.forcedDeleteStatus = errSecInteractionNotAllowed

        // Imitates a parallel suite's logging: a flush already queued ahead of the call. The
        // capture's marker joins it, so this passes only if the warning is enqueued by the time the
        // call returns; a `Task { @MainActor in … }` hop would land it late.
        Logger.shared.debug("a sibling suite's line, its flush still queued")
        AnthropicKeychain.delete(from: store)

        #expect(await log.holds(.warning, containing: "refused to delete the stored item"),
                "a refused delete left no warning in the log")
    }
}
