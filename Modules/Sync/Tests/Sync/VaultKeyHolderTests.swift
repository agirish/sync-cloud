import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Sync

/// VT31 and VT10's rest: the Vault's key behind Touch ID, moved there once, held from a proof to
/// the Vault letting go. A fake data-protection keychain, the fake login keychain and scratch
/// defaults only; every key is made up.
@Suite struct VaultKeyHolderTests {
    /// The data-protection keychain as macOS answers: nothing without a proof, everything with one.
    final class FakeProtected: VaultProtectedKeys, @unchecked Sendable {
        var data: Data?
        var entitled = true
        /// What a read gives back in place of what was added, as a keychain that kept something else.
        var readsBack: Data?
        private(set) var prompts = 0
        private(set) var adds = 0
        func read(with context: LAContext?) -> (status: OSStatus, data: Data?) {
            guard entitled else { return (errSecMissingEntitlement, nil) }
            guard let data else { return (errSecItemNotFound, nil) }
            guard context != nil else { return (errSecInteractionNotAllowed, nil) }
            prompts += 1
            return (errSecSuccess, readsBack ?? data)
        }
        func add(_ data: Data) -> OSStatus {
            adds += 1
            guard entitled else { return errSecMissingEntitlement }
            if self.data != nil { return errSecDuplicateItem }
            self.data = data
            return errSecSuccess
        }
        func delete() -> OSStatus {
            guard entitled else { return errSecMissingEntitlement }
            let had = data != nil
            data = nil
            return had ? errSecSuccess : errSecItemNotFound
        }
    }

    struct Rig {
        let login = VaultFakeKeychain()
        let protected = FakeProtected()
        let defaults = vaultScratchDefaults("vault-key-holder")
        let holder: VaultKeyHolder
        let key = Data(repeating: 7, count: 32)
        init() {
            holder = VaultKeyHolder(inner: login, protected: protected, defaults: defaults)
            login.itemData = key   // a Vault made before VT31: its key in the login keychain
        }
        func read() -> VaultKeychain.ReadOutcome { VaultKeychain.read(from: holder) }
    }

    @Test func untilAProofTheLoginKeyIsReadAsBeforeAndNothingMoves() {
        let rig = Rig()
        #expect(rig.read() == .found(SymmetricKey(data: rig.key)))
        #expect(rig.protected.data == nil && rig.login.itemData == rig.key && !rig.holder.isBehindTouchID)
        #expect(!rig.holder.isHeld, "held before any proof")
        #expect(rig.protected.adds == 0, "a move tried with no proof to read it back by")
    }

    @Test func aProofMovesTheKeyOnceReadBackTheSameAndHoldsIt() {
        let rig = Rig()
        rig.holder.authorise(with: LAContext())
        #expect(rig.read() == .found(SymmetricKey(data: rig.key)))
        #expect(rig.protected.data == rig.key, "behind Touch ID")
        #expect(rig.login.itemData == nil, "gone from the login keychain")
        #expect(rig.holder.isBehindTouchID && rig.holder.isHeld)
        // Held: the next read asks the keychain nothing.
        let prompts = rig.protected.prompts
        #expect(rig.read() == .found(SymmetricKey(data: rig.key)))
        #expect(rig.protected.prompts == prompts)
        // Let go with the numbers: the next read needs a proof, and is never "no key".
        rig.holder.release()
        #expect(!rig.holder.isHeld)
        #expect(rig.read() == .unreadable(errSecInteractionNotAllowed))
        rig.holder.authorise(with: LAContext())
        #expect(rig.read() == .found(SymmetricKey(data: rig.key)))
    }

    @Test func aKeyThatDoesNotReadBackTheSameStaysInTheLoginKeychain() {
        let rig = Rig()
        rig.protected.readsBack = Data(repeating: 9, count: 32)
        rig.holder.authorise(with: LAContext())
        #expect(rig.read() == .found(SymmetricKey(data: rig.key)), "the login key in use still")
        #expect(rig.login.itemData == rig.key, "taken out of the login keychain with no good copy")
        #expect(rig.protected.data == nil, "the bad copy stayed")
        #expect(!rig.holder.isBehindTouchID)
    }

    @Test func aBuildThatCannotReachTheProtectedKeychainKeepsToTheLoginOneUntilTheKeyHasMoved() {
        let rig = Rig()
        rig.protected.entitled = false
        rig.holder.authorise(with: LAContext())
        #expect(rig.read() == .found(SymmetricKey(data: rig.key)), "CI, tests, an install without its profile")
        #expect(rig.login.itemData == rig.key)
        // Moved by the installed copy: this build says it cannot read the key, never that there is none.
        rig.defaults.set(true, forKey: VaultKeyHolder.movedKey)
        rig.login.itemData = nil
        rig.holder.release()
        #expect(rig.read() == .unreadable(errSecMissingEntitlement))
    }

    @Test func aNewVaultsKeyIsMadeBehindTouchIDWhereItCanBe() throws {
        let rig = Rig()
        rig.login.itemData = nil
        let made = try VaultKeychain.create(in: rig.holder).get()
        #expect(rig.protected.data == made.withUnsafeBytes { Data($0) } && rig.login.itemData == nil)
        #expect(rig.holder.isBehindTouchID)
        let plain = Rig()
        plain.login.itemData = nil
        plain.protected.entitled = false
        _ = try VaultKeychain.create(in: plain.holder).get()
        #expect(plain.login.itemData != nil && plain.protected.data == nil, "the login keychain where it cannot")
    }

    @Test func otherItemsPassToTheLoginKeychain() {
        let rig = Rig()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.synccloud.vault-backup",
                                   kSecAttrAccount as String: "default", kSecValueData as String: Data("phrase".utf8)]
        #expect(rig.holder.add(item) == errSecSuccess)
        #expect(rig.login.others["com.synccloud.vault-backup"] == Data("phrase".utf8))
        #expect(rig.protected.data == nil)
    }

    /// The store tells a key behind Touch ID from no key at all, without a prompt.
    @Test func theStoreSaysWhenTheKeyNeedsAProof() throws {
        let rig = Rig()
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: rig.holder)
        #expect(!store.keyNeedsProof, "not moved: read as before")
        rig.holder.authorise(with: LAContext())
        _ = rig.read()
        rig.holder.release()
        #expect(store.keyNeedsProof)
        store.letGoOfKey()
        #expect(!rig.holder.isHeld)
    }
}

/// The model with the key behind Touch ID (the owner, 2026-11-26: ask Touch ID, keep the lines).
@MainActor
@Suite struct VaultKeyBehindTouchIDModelTests {
    /// Answers yes, and hands the holder the proof as the real one does.
    final class Proves: VaultAuthenticating, @unchecked Sendable {
        let holder: VaultKeyHolder
        var touchID: VaultTouchID = .ready
        private(set) var reasons: [String] = []
        init(_ holder: VaultKeyHolder) { self.holder = holder }
        func prove(reason: String) async -> VaultProof {
            reasons.append(reason)
            holder.authorise(with: LAContext())
            return .allowed
        }
    }

    /// A Vault whose key has moved behind Touch ID, holding one saved ID, under `ask`.
    static func rig(_ ask: VaultLockSettings.Ask) throws
        -> (rig: VaultRig, model: VaultModel, proof: Proves, holder: VaultKeyHolder, protected: VaultKeyHolderTests.FakeProtected) {
        let rig = try VaultRig()
        try rig.seed([VaultEntry(title: "Passport", value: "Z0000009", addedAt: VaultRig.t0)])
        let protected = VaultKeyHolderTests.FakeProtected()
        protected.data = rig.keychain.itemData
        rig.keychain.itemData = nil
        let holder = VaultKeyHolder(inner: rig.keychain, protected: protected, defaults: rig.defaults)
        rig.defaults.set(true, forKey: VaultKeyHolder.movedKey)
        rig.defaults.set(ask.rawValue, forKey: VaultLockSettings.askKey)
        let store = VaultStore(fileURL: rig.scratch.fileURL, keychain: holder)
        let proof = Proves(holder)
        let clock = rig.clock
        let model = VaultModel(store: store, authenticator: proof, defaults: rig.defaults, clock: { clock.now },
                               activity: VaultActivityStore.beside(store), copyToPasteboard: { _ in })
        return (rig, model, proof, holder, protected)
    }

    @Test func forEveryIDTheOpenAsksOneTouchForTheKeyAndOpensNothingElse() async throws {
        let (rig, model, proof, holder, _) = try Self.rig(.everyNumber); defer { rig.cleanUp() }
        await model.opened()
        #expect(proof.reasons == ["open the Vault"])
        #expect(model.contents == .loaded && model.entries.count == 1)
        #expect(!model.isOpen, "a touch for the key opened the Vault")
        #expect(holder.isHeld)
        model.closed()
        #expect(!holder.isHeld, "the key outlived the numbers")
    }

    @Test func addingAndReadingWithTheVaultLockedAskOneTouch() async throws {
        let (rig, model, proof, _, _) = try Self.rig(.whenOpened); defer { rig.cleanUp() }
        #expect(await model.keyReady("add an ID to the Vault"))
        #expect(proof.reasons == ["add an ID to the Vault"])
        #expect(!model.isOpen)
        #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) != nil)
        model.systemLocked()
        await model.readDocuments(with: VaultFakeDocuments(pages: ["/docs/letter.pdf": ["Nothing to see here"]]))
        #expect(proof.reasons.last == "read your documents into the Vault")
    }

    @Test func aLineWrittenWhileTheKeyNeedsATouchWaitsForIt() async throws {
        let (rig, model, _, holder, _) = try Self.rig(.whenOpened); defer { rig.cleanUp() }
        let store = VaultStore(fileURL: rig.scratch.fileURL, keychain: holder)
        let activity = VaultActivityStore.beside(store)
        activity.append([VaultActivityEvent(at: VaultRig.t0, kind: .proofRefused, what: "open the Vault")], now: VaultRig.t0)
        #expect(activity.waitingCount == 1)
        #expect(!FileManager.default.fileExists(atPath: store.activityURL.path), "sealed without the key")
        await model.opened()   // the unlock's proof seals what waited
        #expect(activity.waitingCount == 0)
        #expect(activity.load().contains { $0.line.hasPrefix("Proof refused") })
    }
}
