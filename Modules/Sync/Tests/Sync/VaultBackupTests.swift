import CryptoKit
import Foundation
import Testing
@testable import Sync

/// Backups: sealed under a passphrase so they open on another Mac, and put back without ever
/// deleting what was there. Every number is made up.
@MainActor
@Suite struct VaultBackupTests {
    typealias Rig = VaultModelTests.Rig
    static let mortgage = VaultModelTests.mortgage
    static let passport = VaultModelTests.passport
    static let phrase = "correct horse battery staple"
    /// The least a file may claim, so the suite does not spend its time stretching keys.
    static let rounds: UInt32 = VaultBackupFile.leastRounds
    static let salt = Data(repeating: 7, count: 16)

    // MARK: The file

    @Test func aBackupOpensWithItsPassphraseAndHoldsNothingInTheClear() throws {
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage, Self.passport])
        let sealed = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: Self.rounds)
        #expect(try VaultBackupFile.open(sealed, passphrase: Self.phrase) == contents)
        let text = String(decoding: sealed, as: UTF8.self)
        #expect(sealed.prefix(8) == Data("SCVBACK1".utf8))
        #expect(!text.contains("0482917365") && !text.contains("A38291647") && !text.contains("Mortgage"))
    }

    @Test func theWrongPassphraseOrAnAlteredFileDoesNotOpen() throws {
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage])
        var sealed = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: Self.rounds, salt: Self.salt)
        #expect(throws: VaultBackupError.wrongPassphrase) { try VaultBackupFile.open(sealed, passphrase: Self.phrase + "!") }
        // The header is part of what is sealed: a changed salt does not open even with the passphrase.
        sealed[20] ^= 1
        #expect(throws: VaultBackupError.wrongPassphrase) { try VaultBackupFile.open(sealed, passphrase: Self.phrase) }
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupFile.open(Data("not a backup at all, only words".utf8), passphrase: Self.phrase) }
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupFile.open(Data("SCVBACK1".utf8), passphrase: Self.phrase) }
    }

    @Test func aFileThatAsksForAlmostNoWorkIsNotOneOfOurs() throws {
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage])
        let weak = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: 10, salt: Self.salt)
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupFile.open(weak, passphrase: Self.phrase) }
    }

    @Test func aShortPassphraseIsRefusedAndTwoBackupsOfTheSameVaultDiffer() throws {
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage])
        #expect(throws: VaultBackupError.passphraseTooShort) { try VaultBackupFile.seal(contents, passphrase: "short", rounds: Self.rounds) }
        let a = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: Self.rounds)
        let b = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: Self.rounds)
        #expect(a != b, "a fresh salt each time")
    }

    @Test func theKeyIsPBKDF2OfThePassphraseAsThePublishedVectorGivesIt() throws {
        // RFC 7914 §11: PBKDF2-HMAC-SHA-256, P = "passwd", S = "salt", c = 1, dkLen = 64; its first 32 bytes.
        let key = try #require(VaultBackupFile.key(passphrase: "passwd", salt: Data("salt".utf8), rounds: 1))
        let hex = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }

    // MARK: Making one

    static func backup(_ rig: Rig, folder: URL) -> VaultBackup {
        rig.defaults.set(folder.path, forKey: VaultBackup.folderKey)
        let clock = rig.clock
        return VaultBackup(store: rig.store, keychain: rig.keychain, authenticator: rig.auth, defaults: rig.defaults,
                           clock: { clock.now })
    }

    static func scratchFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vault-backup-tests-\(UUID().uuidString)")
    }

    @Test func backUpNowAsksForAProofAndWritesADatedFileOwnerOnly() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        #expect(await backup.backUpNow() == .failure(.noPassphrase), "nothing to seal with yet")
        #expect(rig.auth.reasons.isEmpty, "and no proof is asked for a backup that cannot be made")

        try backup.setPassphrase(Self.phrase)
        rig.auth.answer = .cancelled
        #expect(await backup.backUpNow() == .failure(.notProved))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty ?? true)

        rig.auth.answer = .allowed
        let url = try (await backup.backUpNow()).get()
        #expect(rig.auth.reasons.last == "back up your Vault")
        #expect(url.lastPathComponent.hasPrefix("Vault Backup ") && url.pathExtension == "scvault")
        let mode = try #require((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber)
        #expect(mode.int16Value == 0o600)
        #expect(try backup.read(url).get().entries == [Self.mortgage, Self.passport], "it opens with the kept passphrase")
        #expect(backup.lastBackup == rig.clock.now)
    }

    @Test func theWeeklyBackupIsOwedOnceAWeekAndOnlyWithAPassphrase() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        #expect(!backup.isDue, "no passphrase: nothing is made, so nothing is owed")
        try backup.setPassphrase(Self.phrase)
        #expect(backup.isDue)
        try backup.write([Self.mortgage])
        #expect(!backup.isDue)
        rig.clock.advance(6 * 86_400)
        #expect(!backup.isDue)
        rig.clock.advance(86_400)
        #expect(backup.isDue)
        rig.defaults.set(false, forKey: VaultBackup.weeklyKey)
        #expect(!backup.isDue, "weekly turned off")
    }

    @Test func theModelMakesTheWeeklyBackupOnceItIsOpenAndNeverBehindTheLock() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        try backup.setPassphrase(Self.phrase)

        rig.auth.answer = .cancelled
        let model = rig.model()
        await model.opened()
        model.backUpIfDue(using: backup)
        #expect(backup.lastBackup == nil, "a locked panel holds no IDs to back up")

        rig.auth.answer = .allowed
        #expect(await model.unlock())
        model.backUpIfDue(using: backup)
        #expect(backup.lastBackup != nil)
        let made = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        #expect(try backup.read(made).get().entries == [Self.mortgage])
    }

    // MARK: Putting one back

    @Test func addWhatIsMissingAddsOnlyWhatThisVaultLacksAndChangesNothingElse() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        var renamed = Self.mortgage
        renamed.title = "Home loan"
        try rig.seed([renamed])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage, Self.passport])
        #expect(backup.missing(from: contents) == 1)

        rig.auth.answer = .cancelled
        #expect(await backup.restore(contents, mode: .addMissing) == .failure(.notProved))
        #expect(try rig.store.load() == [renamed], "a refused proof changes nothing")

        rig.auth.answer = .allowed
        #expect(await backup.restore(contents, mode: .addMissing) == .success(2))
        #expect(rig.auth.reasons.last == "restore your Vault from a backup")
        #expect(try rig.store.load() == [renamed, Self.passport], "the ID it already had keeps this Vault's name for it")
    }

    @Test func replaceSetsTheOldVaultAsideAndNeverDeletesIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let before = try Data(contentsOf: rig.store.fileURL)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.passport])

        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(try rig.store.load() == [Self.passport])
        let kept = try FileManager.default.contentsOfDirectory(at: rig.store.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("vault.sealed.set-aside-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: try #require(kept.first)) == before, "byte for byte what was there")
    }

    @Test func aVaultThisMacCannotOpenCanBeReplacedFromABackup() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.keychain.itemData = nil   // its key is gone
        #expect(throws: VaultError.keyMissing) { try rig.store.load() }
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.passport])
        #expect(backup.missing(from: contents) == nil, "there is nothing readable to add to")
        #expect(await backup.restore(contents, mode: .addMissing) == .failure(.vaultUnreadable))

        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(try rig.store.load() == [Self.passport], "sealed under a new key")
    }

    @Test func aPanelHoldingTheOldIDsLetsThemGoWhenARestoreLands() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let model = rig.model()
        await model.opened()
        #expect(model.entries == [Self.mortgage])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        #expect(await backup.restore(VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.passport]), mode: .replace) == .success(1))
        // The notice arrives on the main queue.
        for _ in 0..<20 where model.contents == .loaded { await Task.yield() }
        #expect(model.contents == .notLoaded && model.entries.isEmpty, "what it held is no longer the Vault")
        #expect(await model.unlock())
        #expect(model.entries == [Self.passport])
    }
}

/// A Vault this Mac cannot open is set aside, never deleted, and a new one starts.
@MainActor
@Suite struct VaultSetAsideTests {
    typealias Rig = VaultModelTests.Rig

    @Test func aVaultWhoseKeyIsGoneIsKeptAsideAndANewOneStartsEmpty() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        let sealed = try Data(contentsOf: rig.store.fileURL)
        rig.keychain.itemData = nil
        let model = rig.model()
        await model.opened()
        #expect(model.contents == .unreadable(.keyMissing))

        #expect(model.setAsideAndStartNew())
        #expect(model.contents == .loaded && model.entries.isEmpty)
        #expect(!rig.store.hasFile, "nothing sealed is in the way of a new Vault")
        let kept = try FileManager.default.contentsOfDirectory(at: rig.store.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("vault.sealed.set-aside-") }
        #expect(try kept.map { try Data(contentsOf: $0) } == [sealed], "the old file, byte for byte")
        #expect(model.add(VaultModel.Draft(title: "Passport", value: "A38291647", category: .passport)) != nil, "and the new Vault takes an ID")
    }

    @Test func aVaultThatOpensOrAKeychainOnlyRefusingIsNeverSetAside() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        let model = rig.model()
        await model.opened()
        #expect(!model.setAsideAndStartNew(), "a Vault that opened has nothing to set aside")
        #expect(rig.store.hasFile)

        model.systemLocked()
        rig.keychain.forcedCopyStatus = errSecInteractionNotAllowed
        let refused = rig.model()
        await refused.opened()
        if case .unreadable(.keyUnreadable) = refused.contents {
            #expect(!refused.setAsideAndStartNew(), "the Keychain may answer in a moment: that Vault is fine")
            #expect(rig.store.hasFile)
        } else {
            Issue.record("expected the Keychain's refusal to read as keyUnreadable, got \(refused.contents)")
        }
    }
}
