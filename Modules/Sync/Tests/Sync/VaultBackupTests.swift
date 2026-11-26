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
        // A changed salt derives another key, so the file does not open even with
        // the passphrase. (The header is also the box's authenticated data, which no test can tell
        // apart from that: no change to it keeps the key.)
        sealed[20] ^= 1
        #expect(throws: VaultBackupError.wrongPassphrase) { try VaultBackupFile.open(sealed, passphrase: Self.phrase) }
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupFile.open(Data("not a backup at all, only words".utf8), passphrase: Self.phrase) }
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupFile.open(Data("SCVBACK1".utf8), passphrase: Self.phrase) }
    }

    @Test func aFileThatAsksForAlmostNoWorkIsNotOneOfOurs() throws {
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage])
        let weak = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: VaultBackupFile.leastRounds - 1, salt: Self.salt)
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupFile.open(weak, passphrase: Self.phrase) }
    }

    /// The header is read before anything is proved, and a backup folder may be a synced one.
    @Test func aFileThatAsksForAbsurdWorkIsRefusedBeforeAnyIsDone() throws {
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage])
        var file = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: Self.rounds, salt: Self.salt)
        // Its rounds, four bytes after the marker, rewritten to the most a header can say.
        // One round past the bound: the edge, not the far end, is what is refused.
        withUnsafeBytes(of: (VaultBackupFile.mostRounds + 1).bigEndian) { file.replaceSubrange(8..<12, with: $0) }
        let start = Date()
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupFile.open(file, passphrase: Self.phrase) }
        #expect(Date().timeIntervalSince(start) < 1, "refused on its header, with no key stretched")
        #expect(VaultBackupFile.rounds <= VaultBackupFile.mostRounds, "this build's own files stay inside the limit")
        #expect(VaultBackupFile.mostRounds < 10_000_000)
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
                           clock: { clock.now }, rounds: Self.rounds)
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
        #expect(try await backup.read(url).get().entries == [Self.mortgage, Self.passport], "it opens with the kept passphrase")
        #expect(backup.lastBackup == rig.clock.now)
    }

    /// A second backup the same day goes beside the first, never over it: the first may be the
    /// only copy that moves the Vault to another Mac (the 2026-11-23 review). Back Up Now carries
    /// the household's typed contacts, as the weekly backup does.
    @Test func aSecondBackupTheSameDayGoesBesideTheFirstWithItsContacts() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage, Self.passport])
        var state = VaultReadingState()
        state.contacts = ["anna": VaultContacts(phones: [VaultContacts.Typed("(408) 555-0142", added: VaultLockTests.t0)])]
        try rig.store.writeReadingOnDisk(state)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        try backup.setPassphrase(Self.phrase)
        let first = try (await backup.backUpNow()).get()
        try rig.seed([Self.mortgage])                                   // the day's second, smaller
        let second = try (await backup.backUpNow()).get()
        #expect(first != second)
        #expect(second.lastPathComponent == (first.deletingPathExtension().lastPathComponent + " 2.scvault"))
        #expect(try await backup.read(first).get().entries == [Self.mortgage, Self.passport], "the first was written over")
        #expect(try await backup.read(first).get().contacts?["anna"]?.phones.count == 1, "Back Up Now left the contacts out")
    }

    /// A passphrase change the Keychain refuses keeps the one before: the weekly backup goes on.
    @Test func aRefusedPassphraseChangeKeepsTheOldOne() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let backup = Self.backup(rig, folder: Self.scratchFolder())
        try backup.setPassphrase(Self.phrase)
        rig.keychain.forcedUpdateStatus = errSecInteractionNotAllowed
        #expect(throws: VaultBackupError.notWritten) { try backup.setPassphrase("another passphrase, later") }
        rig.keychain.forcedUpdateStatus = nil
        #expect(backup.hasPassphrase, "a refused change left no passphrase")
        #expect(backup.passphrase() == Self.phrase)
        try backup.setPassphrase("another passphrase, later")
        #expect(backup.passphrase() == "another passphrase, later", "a change that was allowed did not take")
    }

    /// The key is derived off the main actor (VT58): at full strength it takes most of a second,
    /// which held the panel as it opened for the weekly backup. Where sealing and opening run is
    /// recorded as they run.
    @Test func aBackupsKeyIsDerivedOffTheMainActor() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        rig.defaults.set(folder.path, forKey: VaultBackup.folderKey)
        final class Where: @unchecked Sendable { var onMain: [Bool] = [] }
        let seen = Where()
        let clock = rig.clock
        let backup = VaultBackup(store: rig.store, keychain: rig.keychain, authenticator: rig.auth, defaults: rig.defaults,
                                 fileManager: .default, clock: { clock.now }, rounds: Self.rounds,
                                 seal: { seen.onMain.append(Thread.isMainThread); return try VaultBackupFile.seal($0, passphrase: $1, rounds: $2) },
                                 open: { seen.onMain.append(Thread.isMainThread); return try VaultBackupFile.open($0, passphrase: $1) })
        try backup.setPassphrase(Self.phrase)
        let url = try await backup.write([Self.mortgage])
        #expect(try await backup.read(url).get().entries == [Self.mortgage])
        #expect(seen.onMain == [false, false], "a key was derived on the main actor")
    }

    @Test func theWeeklyBackupIsOwedOnceAWeekAndOnlyWithAPassphrase() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        #expect(!backup.isDue, "no passphrase: nothing is made, so nothing is owed")
        try backup.setPassphrase(Self.phrase)
        #expect(backup.isDue)
        try await backup.write([Self.mortgage])
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
        let model = rig.model(backup: backup)
        await model.opened()
        #expect(model.backUpIfDue() == nil)
        #expect(backup.lastBackup == nil, "a locked panel holds no IDs to back up")

        rig.auth.answer = .allowed
        #expect(await model.unlock())
        await model.backUpIfDue()?.value
        #expect(backup.lastBackup != nil)
        let made = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        #expect(try await backup.read(made).get().entries == [Self.mortgage])
    }

    /// A last backup dated ahead of now (a clock set ahead, then put right) does not hold the
    /// weekly backup off for that long (the second review).
    @Test func aLastBackupDatedAheadOfNowIsDue() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        try backup.setPassphrase(Self.phrase)
        rig.defaults.set(rig.clock.now.addingTimeInterval(365 * 86_400), forKey: VaultBackup.lastKey)
        #expect(backup.isDue)
        rig.defaults.set(rig.clock.now.addingTimeInterval(-86_400), forKey: VaultBackup.lastKey)
        #expect(!backup.isDue, "a day ago is not due")
    }

    /// VT114 (owner, 2026-11-26): "For every ID" loads the Vault with no proof; the weekly
    /// backup, every ID in it, waits for the first Touch ID, and is made then.
    @Test func underForEveryNumberTheWeeklyBackupWaitsForTouchID() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        try backup.setPassphrase(Self.phrase)
        rig.auth.answer = .allowed
        let model = rig.model(backup: backup)
        await model.opened()
        try #require(model.contents == .loaded && !model.isSealedShut, "loaded with no proof")
        #expect(rig.auth.reasons.isEmpty)
        #expect(model.backUpIfDue() == nil, "a backup with no Touch ID since the Vault loaded")
        #expect(backup.lastBackup == nil)

        #expect(await model.copy(Self.mortgage.id))
        // Started by the proof itself (the second review: calling it here proved nothing).
        let started = try #require(model.backingUp, "the first proof started no backup")
        await started.value
        #expect(backup.lastBackup != nil, "made after the first proof")
    }

    /// VT114: Settings asks Touch ID before a backup is opened; Restore then asks nothing more
    /// within ``VaultBackup/proofLasts``, and asks again after.
    @Test func aProofToOpenABackupStandsForItsRestoreAWhile() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage, Self.passport])
        rig.auth.answer = .cancelled
        #expect(await backup.prove("open a backup of your Vault") == false)
        rig.auth.answer = .allowed
        #expect(await backup.prove("open a backup of your Vault"))
        let provedAt = rig.clock.now
        let asked = rig.auth.reasons.count
        #expect(await backup.restore(contents, mode: .addMissing, provedAt: provedAt) == .success(2))
        #expect(rig.auth.reasons.count == asked, "asked again within the time")
        rig.clock.advance(VaultBackup.proofLasts + 1)
        rig.auth.answer = .cancelled
        #expect(await backup.restore(contents, mode: .addMissing, provedAt: provedAt) == .failure(.notProved))
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
        #expect(try rig.store.savedOnDisk() == [renamed], "a refused proof changes nothing")

        rig.auth.answer = .allowed
        #expect(await backup.restore(contents, mode: .addMissing) == .success(2))
        #expect(rig.auth.reasons.last == "restore your Vault from a backup")
        #expect(try rig.store.savedOnDisk() == [renamed, Self.passport], "the ID it already had keeps this Vault's name for it")
    }

    /// A backup made before a number was corrected holds the old number under the same id.
    @Test func whatIsAddedNeverSharesAnIDWithARecordAlreadyHere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        var corrected = Self.mortgage
        corrected.value = "0044918858"
        try rig.seed([corrected])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        // The backup's copy: the same record, id and all, with the number as it was.
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.mortgage, Self.passport])
        #expect(Self.mortgage.id == corrected.id && Self.mortgage.value != corrected.value)

        #expect(await backup.restore(contents, mode: .addMissing) == .success(3))
        let now = try rig.store.savedOnDisk()
        #expect(now.first == corrected, "the record here is untouched")
        #expect(Set(now.map(\.id)).count == 3, "three records, three ids: \(now.map(\.id))")
        let old = try #require(now.first { $0.value == Self.mortgage.value })
        #expect(old.id != corrected.id, "the old number came back as an ID of its own")
        #expect(old.title == Self.mortgage.title && old.addedAt == Self.mortgage.addedAt, "and is otherwise as the backup had it")
        #expect(now.last == Self.passport, "one whose id is free keeps it")
    }

    /// Replace sets the Vault aside before writing the new one: if that cannot be written, the
    /// Vault goes back where it was.
    @Test func aReplaceThatCannotBeWrittenLeavesTheVaultInPlace() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let before = try Data(contentsOf: rig.store.fileURL)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.passport])

        rig.keychain.forcedCopyStatus = errSecAuthFailed   // the Keychain refuses the key
        #expect(await backup.restore(contents, mode: .replace) == .failure(.notWritten))
        rig.keychain.forcedCopyStatus = nil
        #expect(try Data(contentsOf: rig.store.fileURL) == before, "byte for byte where it was")
        #expect(try rig.store.savedOnDisk() == [Self.mortgage])
        let aside = try FileManager.default.contentsOfDirectory(at: rig.store.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".set-aside-") }
        #expect(aside.isEmpty, "nothing is left set aside by a restore that did not happen: \(aside.map(\.lastPathComponent))")

        // And a Vault this Mac cannot open, whose new key the Keychain will not take, is still there.
        rig.keychain.itemData = nil
        rig.keychain.forcedAddStatus = errSecAuthFailed
        #expect(await backup.restore(contents, mode: .replace) == .failure(.notWritten))
        #expect(try Data(contentsOf: rig.store.fileURL) == before, "kept for the day its key turns up")
    }

    @Test func replaceSetsTheOldVaultAsideAndNeverDeletesIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let before = try Data(contentsOf: rig.store.fileURL)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.passport])

        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(try rig.store.savedOnDisk() == [Self.passport])
        let kept = try FileManager.default.contentsOfDirectory(at: rig.store.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("vault.sealed.set-aside-") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: try #require(kept.first)) == before, "byte for byte what was there")
    }

    /// A backup holding a record a later build wrote (a kind this one does not know) still puts
    /// back every record this build can read (VT30).
    @Test func aBackupWithALaterBuildsRecordRestoresTheRest() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        try backup.setPassphrase("correct horse battery")
        let url = try await backup.write([Self.mortgage, Self.passport])
        // Rewrite it as a later build would: one more record, of a kind this build has never seen.
        let passphrase = "correct horse battery"
        let sealed = try Data(contentsOf: url)
        let head = Data(sealed.prefix(28))
        let key = try #require(VaultBackupFile.key(passphrase: passphrase, salt: Data(head.suffix(16)),
                                                   rounds: Self.rounds))
        var object = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(sealed, marker: head, with: key)) as? [String: Any])
        var list = try #require(object["entries"] as? [[String: Any]])
        var later = list[0]
        later["id"] = UUID().uuidString
        later["value"] = "LATER000001"
        later["category"] = "bankAccount"
        list.append(later)
        object["entries"] = list
        try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), marker: head, with: key)
            .write(to: url)

        let contents = try await backup.read(url).get()
        #expect(contents.laterRecords == 1)
        #expect(await backup.restore(contents, mode: .addMissing) == .success(2))
        #expect(try rig.store.savedOnDisk().map(\.title).sorted() == [Self.mortgage.title, Self.passport.title].sorted())
    }

    /// Replace keeps what the activity list held, and the backups kept before each save: under
    /// the same key they are still this Mac's.
    @Test func replaceKeepsTheActivityListAndTheBackups() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        try rig.seed([Self.mortgage, Self.passport])
        let backups = rig.store.backups
        #expect(!backups.isEmpty)
        VaultActivityStore.beside(rig.store, keychain: rig.keychain)
            .append([VaultActivityEvent(at: VaultLockTests.t0, kind: .copied, what: "Passport")], now: VaultLockTests.t0)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.passport])
        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(VaultActivityStore.beside(rig.store, keychain: rig.keychain).load().contains { $0.kind == .copied },
                "the activity list went with the Replace")
        #expect(Set(backups).isSubset(of: Set(rig.store.backups)), "the backups went with the Replace")
        let key = SymmetricKey(data: try #require(rig.keychain.itemData))
        let newest = try #require(rig.store.backups.first)
        #expect(try savedIDs(Data(contentsOf: newest), key: key) == [Self.mortgage, Self.passport],
                "the Vault as it was just before the Replace is not among the backups")
    }

    /// A backup made here carries the records a later build wrote, after this build's, so a
    /// later build restoring it gets them back.
    @Test func aBackupCarriesALaterBuildsRecords() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.keychain.itemData = VaultFormatTests.key.withUnsafeBytes { Data($0) }
        let entries = Array(try VaultFormatTests.formatEntries().prefix(2))
        try FileManager.default.createDirectory(at: rig.scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VaultFormatTests.sealed(entries, plus: [["category": "bankAccount"]]).write(to: rig.scratch.fileURL)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        try backup.setPassphrase(Self.phrase)
        let url = try await backup.write(entries)
        let contents = try await backup.read(url).get()
        #expect(contents.entries == entries)
        #expect(contents.laterRecords == 1, "the later build's record was not carried")
    }

    /// A later build's records in a backup come back with a restore made here, Replace and Add
    /// Missing alike, so a backup made from the result still has them.
    @Test func aRestoreKeepsALaterBuildsRecords() async throws {
        for mode in [VaultRestoreMode.replace, .addMissing] {
            let rig = try Rig(); defer { rig.cleanUp() }
            rig.keychain.itemData = VaultFormatTests.key.withUnsafeBytes { Data($0) }
            let entries = Array(try VaultFormatTests.formatEntries().prefix(2))
            try FileManager.default.createDirectory(at: rig.scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try VaultFormatTests.sealed(entries, plus: [["category": "bankAccount"]]).write(to: rig.scratch.fileURL)
            let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
            let backup = Self.backup(rig, folder: folder)
            try backup.setPassphrase(Self.phrase)
            let contents = try await backup.read(try await backup.write(entries)).get()
            #expect(contents.newer.count == 1)
            // A Vault that lacks it now: one ID removed and the later record gone.
            try VaultFormatTests.sealed([entries[0]], plus: []).write(to: rig.scratch.fileURL)
            #expect(await backup.restore(contents, mode: mode) == .success(2))
            #expect(try rig.store.loadRecords().newer.count == 1, "\(mode): the later build's record was dropped")
        }
    }

    /// Add Missing never brings back beside it an ID this Vault holds only as a later build's
    /// record; and a restore keeps a later build's fields on the records this build reads.
    @Test func aRestoreRespectsWhatALaterBuildHolds() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.keychain.itemData = VaultFormatTests.key.withUnsafeBytes { Data($0) }
        let entries = Array(try VaultFormatTests.formatEntries().prefix(2))
        try FileManager.default.createDirectory(at: rig.scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VaultFormatTests.sealed(entries, plus: [], laterOnFirst: ["expiresReminder": ["days": 30]]).write(to: rig.scratch.fileURL)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        try backup.setPassphrase(Self.phrase)
        let contents = try await backup.read(try await backup.write(entries)).get()

        // Replace: the later field comes back on the record it was on.
        #expect(await backup.restore(contents, mode: .replace) == .success(2))
        #expect(try rig.store.loadRecords().laterFields[entries[0].id] != nil, "a later build's field was dropped by a restore")

        // The second record is now only a later build's (a kind this build does not know).
        var list = try entries.map { try #require(JSONSerialization.jsonObject(with: JSONEncoder.vaultBackupTests.encode(VaultLegacyFormat.Entry($0))) as? [String: Any]) }
        list[1]["category"] = "bankAccount"
        try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
                                marker: VaultFile.marker, with: VaultFormatTests.key).write(to: rig.scratch.fileURL)
        #expect(await backup.restore(contents, mode: .addMissing) == .success(1))
        let after = try rig.store.loadRecords()
        #expect(after.entries.count == 1 && after.newer.count == 1, "the later build's record came back twice")
    }

    /// Round trips (VT10): a weekly backup made days ago asks the Keychain nothing to know it is
    /// not due, and an activity entry reads the Vault's key once.
    @Test func fewerKeychainReads() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        try backup.setPassphrase(Self.phrase)
        _ = try await backup.write([Self.mortgage])
        rig.clock.advance(3 * 86_400)
        let before = rig.keychain.reads.count
        #expect(!backup.isDue)
        #expect(rig.keychain.reads.count == before, "a backup three days old asked the Keychain whether one is due")

        let activity = VaultActivityStore.beside(rig.store, keychain: rig.keychain)
        activity.append([VaultActivityEvent(at: VaultLockTests.t0, kind: .unlocked)], now: VaultLockTests.t0)
        let reading = rig.keychain.reads.count
        activity.append([VaultActivityEvent(at: VaultLockTests.t0, kind: .copied, what: "Passport")], now: VaultLockTests.t0)
        #expect(rig.keychain.reads.count - reading == 1, "an activity entry read the key more than once")
    }

    /// What a backup is for (VT96): opened on another Mac, with its own Keychain and no passphrase
    /// kept, it asks for one, refuses the wrong one, opens with the right one, and replaces that
    /// Mac's Vault with this one's IDs. An old backup keeps its old passphrase.
    @Test func aBackupOpensOnAnotherMacWithItsPassphraseOnly() async throws {
        let here = try Rig(); defer { here.cleanUp() }
        try here.seed([Self.mortgage, Self.passport])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let made = Self.backup(here, folder: folder)
        try made.setPassphrase(Self.phrase)
        let url = try await made.write([Self.mortgage, Self.passport])
        try made.setPassphrase("another passphrase, later")
        #expect(try await made.read(url, passphrase: Self.phrase).get().entries == [Self.mortgage, Self.passport],
                "a backup does not keep the passphrase it was made with")

        let there = try Rig(); defer { there.cleanUp() }
        try there.seed([VaultEntry(title: "Library card", value: "LIB0000009", addedAt: VaultLockTests.t0)])
        let other = Self.backup(there, folder: folder)
        #expect(await other.read(url) == .failure(.noPassphrase))
        #expect(await other.read(url, passphrase: Self.phrase + "?") == .failure(.wrongPassphrase))
        let contents = try await other.read(url, passphrase: Self.phrase).get()
        #expect(await other.restore(contents, mode: .replace) == .success(2))
        #expect(try there.store.savedOnDisk() == [Self.mortgage, Self.passport])
    }

    /// The weekly backup is made once, though the panel asks twice as it opens unlocked.
    @Test func theWeeklyBackupIsMadeOnceWhenAskedTwice() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        final class Seals: @unchecked Sendable { var count = 0 }
        let seals = Seals()
        rig.defaults.set(folder.path, forKey: VaultBackup.folderKey)
        let clock = rig.clock
        let backup = VaultBackup(store: rig.store, keychain: rig.keychain, authenticator: rig.auth, defaults: rig.defaults,
                                 fileManager: .default, clock: { clock.now }, rounds: Self.rounds,
                                 seal: { seals.count += 1; return try VaultBackupFile.seal($0, passphrase: $1, rounds: $2) },
                                 open: { try VaultBackupFile.open($0, passphrase: $1) })
        try backup.setPassphrase(Self.phrase)
        let model = rig.model(backup: backup)
        rig.auth.answer = .allowed
        await model.opened()
        #expect(await model.unlock())
        let first = model.backUpIfDue()
        let second = model.backUpIfDue()
        await first?.value
        await second?.value
        #expect(seals.count == 1, "two backups were made")
        #expect(model.backUpIfDue() == nil, "made, it is no longer due")
    }

    /// The short-list guard (VT20) stops a save that drops several records at once. Replace is
    /// the one act that does, on purpose, and it saves onto no file: what was there is set aside.
    @Test func theShortListGuardNeverStopsAReplace() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let library = VaultEntry(title: "Library card", value: "LIB0000001", addedAt: VaultLockTests.t0)
        let gym = VaultEntry(title: "Gym membership", value: "GYM0000001", addedAt: VaultLockTests.t0)
        try rig.seed([Self.mortgage, library, gym])
        #expect(throws: VaultError.wouldDrop(3)) { try rig.store.writeSavedOnDisk([Self.passport]) }
        let before = try Data(contentsOf: rig.store.fileURL)
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)

        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.passport])
        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(try rig.store.savedOnDisk() == [Self.passport])
        let vaultFolder = rig.store.fileURL.deletingLastPathComponent()
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: vaultFolder.path)
            .first { $0.hasPrefix("vault.sealed.set-aside-") }, "the old Vault was not set aside")
        #expect(try Data(contentsOf: vaultFolder.appendingPathComponent(aside)) == before)
    }

    @Test func aVaultThisMacCannotOpenCanBeReplacedFromABackup() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        rig.keychain.itemData = nil   // its key is gone
        #expect(throws: VaultError.keyMissing) { try rig.store.savedOnDisk() }
        let folder = Self.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = Self.backup(rig, folder: folder)
        let contents = VaultBackupContents(madeAt: VaultLockTests.t0, entries: [Self.passport])
        #expect(backup.missing(from: contents) == nil, "there is nothing readable to add to")
        #expect(await backup.restore(contents, mode: .addMissing) == .failure(.vaultUnreadable))

        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(try rig.store.savedOnDisk() == [Self.passport], "sealed under a new key")
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
        await waitUntil("the restore's notice reached the panel") { model.contents != .loaded }
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


private extension JSONEncoder {
    static var vaultBackupTests: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// The saved IDs in a sealed Vault file of either format: a v1 file, or the v7.2 document.
private func savedIDs(_ sealed: Data, key: SymmetricKey) throws -> [VaultEntry] {
    if let v1 = try? VaultFile.open(sealed, with: key) { return v1 }
    return try VaultDocument.open(plain: VaultFile.openPlain(sealed, marker: VaultDocument.marker, with: key)).document.entries()
}
