import CryptoKit
import Foundation
import Testing
@testable import Sync

/// Passphrase backups of the v7.2 document (version 2) beside the v1 ones: what each Vault writes,
/// what each version restores into a Vault kept in the v1 files and into one kept as the document,
/// a newer SyncCloud's backup refused, and Settings' Set Aside counted and forgotten through the
/// model. Scratch folders, the fake Keychain and scratch defaults only; every number is made up.
@MainActor
@Suite struct VaultBackupDocumentTests {
    typealias Rig = VaultModelTests.Rig
    static let key = VaultFormatTests.key
    static let phrase = VaultBackupTests.phrase
    static let rounds = VaultBackupTests.rounds
    static let mortgage = VaultModelTests.mortgage
    static let passport = VaultModelTests.passport
    static let t0 = VaultRig.t0

    static let library = VaultEntry(title: "Library card", value: "LIB0000001", addedAt: t0, category: .other)
    static let anna = ["anna": VaultContacts(phones: [VaultContacts.Typed("(408) 555-0142", added: t0)])]
    static let annaEmail = ["anna": VaultContacts(emails: [VaultContacts.Typed("anna@example.com", added: t0)])]
    static let memberships = VaultCustomKind(id: "kind-1", name: "Memberships", group: "home")

    // MARK: Rigs

    /// A Vault kept as the document, holding `document`, under the fixture key.
    static func documentVault(_ rig: Rig, _ document: VaultDocument) throws {
        rig.keychain.itemData = key.withUnsafeBytes { Data($0) }
        try VaultDocumentModelTests.documentStore(rig).saveDocument(document, expecting: .absent)
    }

    static func document(_ rig: Rig) throws -> VaultDocument { try VaultDocumentModelTests.document(rig) }

    static func backup(_ rig: Rig) -> (VaultBackup, URL) {
        let folder = VaultBackupTests.scratchFolder()
        return (VaultBackupTests.backup(rig, folder: folder), folder)
    }

    /// A document of made-up data: two saved IDs, one waiting, and some of each kind of the
    /// user's own data.
    static func sample(fingerprints: [String] = [], keyID: String = "") -> VaultDocument {
        var state = VaultReadingState(finds: [VaultRecordTests.fullFind()], names: ["pat": "Pat Doe"], contacts: anna)
        state.lessons = ["Home/Clubs": .custom("kind-1")]
        state.nameRoles = ["pat": VaultNameRoles(legal: "Patricia Doe")]
        return VaultDocument(entries: [mortgage, passport], state: state,
                             setAside: .init(generation: 3, keyID: keyID, fingerprints: fingerprints), kinds: [memberships],
                             savedAt: t0)
    }

    static func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// `plain` sealed as a backup is, under the test passphrase: for files this build would not write.
    static func sealedBackup(_ plain: Data) throws -> Data {
        let salt = VaultBackupTests.salt
        var head = VaultBackupFile.marker
        withUnsafeBytes(of: rounds.bigEndian) { head.append(contentsOf: $0) }
        head.append(salt)
        let key = try #require(VaultBackupFile.key(passphrase: phrase, salt: salt, rounds: rounds))
        return try VaultFile.sealPlain(plain, marker: head, with: key)
    }

    // MARK: The file

    @Test func aVersionOneBackupIsWrittenAsBeforeAndOpensTheSame() throws {
        let contents = VaultBackupContents(madeAt: Self.t0, entries: [Self.mortgage, Self.passport], contacts: Self.anna)
        let sealed = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: Self.rounds)
        let opened = try VaultBackupFile.open(sealed, passphrase: Self.phrase)
        #expect(opened == contents)
        #expect(opened.version == 1 && opened.document == nil)
        let plain = try JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(contents)) as? [String: Any]
        #expect(Set(plain?.keys.map { $0 } ?? []) == ["version", "madeAt", "entries", "contacts"], "no key a v1 build does not write")
    }

    @Test func aVersionTwoBackupHoldsTheWholeDocumentAndOpensTheSame() throws {
        let document = Self.sample(fingerprints: ["ab", "cd"], keyID: "0123456789abcdef")
        let contents = try VaultBackupContents(madeAt: Self.t0, document: document)
        #expect(contents.version == 2)
        #expect(contents.entries == [Self.mortgage, Self.passport], "its saved IDs, for counting")
        #expect(contents.contacts == Self.anna)
        let sealed = try VaultBackupFile.seal(contents, passphrase: Self.phrase, rounds: Self.rounds)
        #expect(sealed.prefix(8) == Data("SCVBACK1".utf8))
        let text = String(decoding: sealed, as: UTF8.self)
        #expect(!text.contains("0482917365") && !text.contains("XX000000001") && !text.contains("Pat Doe"))
        let opened = try VaultBackupFile.open(sealed, passphrase: Self.phrase)
        #expect(opened == contents)
        #expect(opened.document == document, "waiting IDs, user data, set-aside numbers and kinds, all of it")
        #expect(throws: VaultBackupError.wrongPassphrase) { try VaultBackupFile.open(sealed, passphrase: Self.phrase + "!") }
        let plain = try #require(JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(contents)) as? [String: Any])
        #expect(Set(plain.keys) == ["version", "madeAt", "document"])
    }

    @Test func aBackupFromANewerSyncCloudIsRefusedAsThat() throws {
        let contents = try VaultBackupContents(madeAt: Self.t0, document: Self.sample())
        var object = try #require(JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(contents)) as? [String: Any])
        // A later build's document format.
        var document = try #require(object["document"] as? [String: Any])
        document["format"] = VaultDocument.format + 1
        document["somethingNew"] = ["a": 1]
        object["document"] = document
        let newerDocument = try Self.sealedBackup(JSONSerialization.data(withJSONObject: object))
        #expect(throws: VaultBackupError.newerFormat) { try VaultBackupFile.open(newerDocument, passphrase: Self.phrase) }
        // A later backup version.
        var later = try #require(JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(contents)) as? [String: Any])
        later["version"] = VaultBackupContents.newestVersion + 1
        let newerVersion = try Self.sealedBackup(JSONSerialization.data(withJSONObject: later))
        #expect(throws: VaultBackupError.newerFormat) { try VaultBackupFile.open(newerVersion, passphrase: Self.phrase) }
        // Still a wrong passphrase first: nothing is said about a file that did not open.
        #expect(throws: VaultBackupError.wrongPassphrase) { try VaultBackupFile.open(newerDocument, passphrase: Self.phrase + "!") }
        // And this build's, damaged inside the seal, is not a backup.
        var broken = try #require(JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(contents)) as? [String: Any])
        broken["document"] = ["format": VaultDocument.format]
        #expect(throws: VaultBackupError.notABackup) {
            try VaultBackupFile.open(Self.sealedBackup(JSONSerialization.data(withJSONObject: broken)), passphrase: Self.phrase)
        }
    }

    // MARK: Writing

    @Test func aVaultInTheV1FilesStillWritesVersionOne() async throws {
        let rig = try Rig(v1: true); defer { rig.cleanUp() }
        try rig.seed([Self.mortgage])
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        try backup.setPassphrase(Self.phrase)
        let url = try (await backup.backUpNow()).get()
        let read = try await backup.read(url).get()
        #expect(read.version == 1 && read.document == nil && read.entries == [Self.mortgage])
        #expect(rig.store.fileFormat == .v1)
    }

    @Test func aVaultKeptAsTheDocumentWritesVersionTwoFromSettingsAndTheWeeklyBackup() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try Self.documentVault(rig, Self.sample())
        let held = try Self.document(rig)
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        try backup.setPassphrase(Self.phrase)

        // Back Up Now: the document as it is on disk.
        let url = try (await backup.backUpNow()).get()
        let read = try await backup.read(url).get()
        #expect(read.version == 2 && read.document == held)
        #expect(read.document?.setAside.keyID == VaultDocument.keyID(for: Self.key))

        // The weekly backup, from the open panel: the document as the model would seal it now.
        rig.defaults.removeObject(forKey: VaultBackup.lastKey)
        let weekly = VaultBackup(store: VaultDocumentModelTests.documentStore(rig), keychain: rig.keychain, authenticator: rig.auth,
                                 defaults: rig.defaults, clock: { [clock = rig.clock] in clock.now }, rounds: Self.rounds)
        let withBackup = VaultModel(store: VaultDocumentModelTests.documentStore(rig), authenticator: rig.auth, defaults: rig.defaults,
                                    clock: { [clock = rig.clock] in clock.now }, backup: weekly, copyToPasteboard: { _ in })
        await withBackup.opened()
        #expect(withBackup.contents == .loaded)
        await withBackup.backUpIfDue()?.value
        let made = Self.names(in: folder).filter { $0.hasSuffix(".scvault") }
        #expect(made.count == 2)
        let second = try await backup.read(folder.appendingPathComponent(try #require(made.last))).get()
        #expect(second.version == 2)
        #expect(second.document?.records.map(\.id) == held.records.map(\.id))
        #expect(second.document?.names == held.names && second.document?.kinds == held.kinds)
    }

    // MARK: Restoring into a Vault in the v1 files

    @Test func aVersionTwoBackupRestoresItsSavedIDsContactsAndKindsIntoAV1Vault() async throws {
        let rig = try Rig(v1: true); defer { rig.cleanUp() }
        try rig.seed([Self.library])
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        let contents = try VaultBackupContents(madeAt: Self.t0, document: Self.sample())
        #expect(backup.missing(from: contents) == 2)

        #expect(await backup.restore(contents, mode: .addMissing) == .success(3))
        #expect(rig.store.fileFormat == .v1, "a Vault in the v1 files stays in them")
        #expect(try rig.store.load() == [Self.library, Self.mortgage, Self.passport])
        #expect(rig.store.loadReading()?.contacts == Self.anna)
        #expect(VaultKinds.load(from: rig.defaults).custom == [Self.memberships])

        #expect(await backup.restore(contents, mode: .replace) == .success(2))
        #expect(rig.store.fileFormat == .v1)
        #expect(try rig.store.load() == [Self.mortgage, Self.passport])
        #expect(VaultKinds.load(from: rig.defaults).custom == [Self.memberships], "once")
    }

    // MARK: Restoring into a Vault kept as the document

    @Test func replaceWithAVersionTwoBackupWritesItsDocumentAndKeepsWhatIsSetAsideHere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let store = VaultDocumentModelTests.documentStore(rig)
        rig.keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let mine = try #require(store.fingerprint("ZZ0000000"))
        var here = VaultDocument(entries: [Self.library], state: VaultReadingState(names: ["lee": "Lee"]),
                                 setAside: .init(generation: 7, fingerprints: [mine]), kinds: [], savedAt: Self.t0)
        here.records[0].note = "kept aside"
        try store.saveDocument(here, expecting: .absent)
        let before = try Data(contentsOf: rig.scratch.fileURL)
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        let incoming = Self.sample(fingerprints: ["from-the-backup"])

        let contents = try VaultBackupContents(madeAt: Self.t0, document: incoming)
        #expect(await backup.restore(contents, mode: .replace) == .success(2))
        let now = try Self.document(rig)
        #expect(now.records == incoming.records, "the backup's saved and waiting IDs")
        #expect(now.names == incoming.names && now.nameRoles == incoming.nameRoles && now.lessons == incoming.lessons
                && now.contacts == incoming.contacts && now.kinds == incoming.kinds)
        #expect(now.setAside.fingerprints == [mine] && now.setAside.generation == 7, "this Vault's set-aside numbers")
        #expect(now.migratedFrom == nil)
        let aside = Self.names(in: rig.scratch.fileURL.deletingLastPathComponent()).filter { $0.hasPrefix("vault.sealed.set-aside-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: rig.scratch.fileURL.deletingLastPathComponent().appendingPathComponent(aside[0])) == before,
                "the Vault that was here, byte for byte")
    }

    /// A Vault file that does not open at all, replaced from a version 2 backup, becomes the
    /// backup's document whole: taken the v1 way, it kept only the saved IDs (the second review).
    @Test func replacingADamagedVaultWithAVersionTwoBackupKeepsEverythingItHolds() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(at: rig.scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: rig.scratch.fileURL)   // cut short to nothing
        let store = VaultDocumentModelTests.documentStore(rig)
        try #require(store.fileFormat == .unknown && !store.keepsDocument)
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        let incoming = Self.sample(fingerprints: ["from-the-backup"], keyID: store.keyID ?? "")
        let contents = try VaultBackupContents(madeAt: Self.t0, document: incoming)
        #expect(await backup.restore(contents, mode: .replace) == .success(2))
        #expect(store.fileFormat == .document)
        let now = try Self.document(rig)
        #expect(now.records == incoming.records, "the backup's saved and waiting IDs")
        #expect(now.names == incoming.names && now.nameRoles == incoming.nameRoles && now.lessons == incoming.lessons
                && now.contacts == incoming.contacts && now.kinds == incoming.kinds)
        #expect(now.setAside.fingerprints == ["from-the-backup"], "made under this key, they come back")
    }

    @Test func replaceWithAVersionOneBackupMakesADocumentOfItKeepingKindsAndSetAside() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let held = Self.sample(fingerprints: ["kept"])
        try Self.documentVault(rig, held)
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        // Through the file, so the restore reads it as the migration's reader does.
        try backup.setPassphrase(Self.phrase)
        let sealed = try VaultBackupFile.seal(VaultBackupContents(madeAt: Self.t0, entries: [Self.library], contacts: Self.annaEmail),
                                              passphrase: Self.phrase, rounds: Self.rounds)
        let url = folder.appendingPathComponent("old.scvault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sealed.write(to: url)
        let contents = try await backup.read(url).get()

        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(rig.store.fileFormat == .document, "a document Vault is never written back as v1")
        let now = try Self.document(rig)
        #expect(try now.entries() == [Self.library])
        #expect(try now.finds().isEmpty && now.names.isEmpty)
        #expect(now.contacts == Self.annaEmail)
        #expect(now.kinds == held.kinds, "this Vault's kinds, as UserDefaults kept them before 7.2")
        #expect(now.setAside.fingerprints == ["kept"] && now.setAside.generation == 3)
        #expect(!rig.store.hasReadingFile, "no v1 reading file beside it")
    }

    @Test func addMissingFromAVersionOneBackupAddsSavedIDsAndContactsToTheDocument() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        var corrected = Self.mortgage
        corrected.value = "0044918858"
        let held = VaultDocument(entries: [corrected], state: VaultReadingState(contacts: Self.anna),
                                 setAside: .init(), kinds: [], savedAt: Self.t0)
        try Self.documentVault(rig, held)
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        let contents = VaultBackupContents(madeAt: Self.t0, entries: [Self.mortgage, Self.passport], contacts: Self.annaEmail)
        #expect(backup.missing(from: contents) == 2)

        #expect(await backup.restore(contents, mode: .addMissing) == .success(3))
        let now = try Self.document(rig)
        let saved = try now.entries()
        #expect(saved.first == corrected, "the record here is untouched")
        #expect(Set(saved.map(\.id)).count == 3)
        let old = try #require(saved.first { $0.value == Self.mortgage.value })
        #expect(old.id != corrected.id, "the old number came back under an id of its own")
        #expect(saved.last == Self.passport)
        #expect(now.contacts["anna"]?.phones.count == 1 && now.contacts["anna"]?.emails.count == 1, "contacts merged")
    }

    @Test func addMissingFromAVersionTwoBackupTakesWhatThisDocumentLacks() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let store = VaultDocumentModelTests.documentStore(rig)
        rig.keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let keyID = VaultDocument.keyID(for: Self.key)
        // Here: the passport (renamed), the library card, one name and lesson of its own, and a
        // waiting number set aside since the backup was made.
        var renamed = Self.passport
        renamed.title = "My passport"
        var setAsideHere = VaultRecordTests.fullFind()
        setAsideHere = VaultFind(id: UUID(), title: "Member ID", value: "MM0000001", facts: setAsideHere.facts)
        let fingerprint = try #require(store.fingerprint(setAsideHere.value))
        let held = VaultDocument(entries: [renamed, Self.library],
                                 state: VaultReadingState(lessons: ["Home/Clubs": .builtIn(.utilities)], names: ["pat": "P. Doe"]),
                                 setAside: .init(generation: 1, fingerprints: [fingerprint]), kinds: [], savedAt: Self.t0)
        try store.saveDocument(held, expecting: .absent)
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }

        // The backup: the mortgage under the library card's id, the passport, a waiting ID, the
        // set-aside number waiting, and user data.
        var mortgage = VaultRecord(Self.mortgage)
        mortgage.id = Self.library.id
        var incoming = Self.sample(fingerprints: ["from-the-backup"], keyID: keyID)
        incoming.records = [mortgage, VaultRecord(Self.passport), VaultRecord(VaultRecordTests.fullFind()),
                            VaultRecord(setAsideHere)]
        incoming.names["sam"] = "Sam Doe"
        let contents = try VaultBackupContents(madeAt: Self.t0, document: incoming)
        #expect(backup.missing(from: contents) == 1)

        #expect(await backup.restore(contents, mode: .addMissing) == .success(3))
        let now = try Self.document(rig)
        let saved = try now.entries()
        #expect(saved.prefix(2).elementsEqual([renamed, Self.library]), "nothing here changed")
        let added = try #require(saved.last)
        #expect(added.value == Self.mortgage.value && added.id != Self.library.id, "a clashing id is reissued")
        #expect(try now.finds().map(\.id) == [VaultRecordTests.fullFind().id], "the waiting ID, not the one set aside here")
        #expect(now.names == ["pat": "P. Doe", "sam": "Sam Doe"], "a key here keeps its value")
        #expect(now.lessons == ["Home/Clubs": .builtIn(.utilities)])
        #expect(now.nameRoles == incoming.nameRoles && now.kinds == incoming.kinds)
        #expect(now.contacts == Self.anna)
        #expect(Set(now.setAside.fingerprints) == [fingerprint, "from-the-backup"], "made under this key: unioned")
        #expect(now.setAside.generation == 1)

        // Made under another key, its set-aside numbers mean nothing here.
        let rig2 = try Rig(); defer { rig2.cleanUp() }
        try Self.documentVault(rig2, held)
        let (other, folder2) = Self.backup(rig2); defer { try? FileManager.default.removeItem(at: folder2) }
        var elsewhere = incoming
        elsewhere.setAside.keyID = "ffffffffffffffff"
        #expect(await other.restore(try VaultBackupContents(madeAt: Self.t0, document: elsewhere), mode: .addMissing) == .success(3))
        #expect(try Self.document(rig2).setAside.fingerprints == [fingerprint])
    }

    @Test func waitingIDsReadUnderOtherRulesAreLeftForTheNextRead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try Self.documentVault(rig, VaultDocument(entries: [], state: VaultReadingState(), setAside: .init(), kinds: [], savedAt: Self.t0))
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        var incoming = Self.sample()
        incoming.reading.readerVersion -= 1
        #expect(await backup.restore(try VaultBackupContents(madeAt: Self.t0, document: incoming), mode: .addMissing) == .success(2))
        #expect(try Self.document(rig).finds().isEmpty)
    }

    @Test func aNewerSyncCloudsVaultIsNeverAddedToAndOnlyReplaced() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        rig.keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        var object = try #require(JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(Self.sample())) as? [String: Any])
        object["format"] = VaultDocument.format + 1
        let sealed = try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: object), marker: VaultDocument.marker, with: Self.key)
        try FileManager.default.createDirectory(at: rig.scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: rig.scratch.fileURL)
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        try backup.setPassphrase(Self.phrase)
        let contents = VaultBackupContents(madeAt: Self.t0, entries: [Self.library])
        #expect(backup.missing(from: contents) == nil, "only Replace is offered")
        #expect(await backup.restore(contents, mode: .addMissing) == .failure(.vaultUnreadable))
        #expect(try Data(contentsOf: rig.scratch.fileURL) == sealed)
        #expect(await backup.backUpNow() == .failure(.newerFormat), "a backup here would leave out what this build cannot read")

        #expect(await backup.restore(contents, mode: .replace) == .success(1))
        #expect(try Self.document(rig).entries() == [Self.library])
    }

    @Test func aReplaceThatCannotBeWrittenPutsTheDocumentBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try Self.documentVault(rig, Self.sample())
        let before = try Data(contentsOf: rig.scratch.fileURL)
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        rig.keychain.forcedCopyStatus = errSecAuthFailed
        #expect(await backup.restore(VaultBackupContents(madeAt: Self.t0, entries: [Self.library]), mode: .replace) == .failure(.notWritten))
        rig.keychain.forcedCopyStatus = nil
        #expect(try Data(contentsOf: rig.scratch.fileURL) == before)
        #expect(!Self.names(in: rig.scratch.fileURL.deletingLastPathComponent()).contains { $0.contains(".set-aside-") })
    }

    @Test func anOpenPanelLetsTheDocumentGoWhenARestoreLandsAndReadsTheNewOne() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try Self.documentVault(rig, VaultDocument(entries: [Self.library], state: VaultReadingState(), setAside: .init(),
                                                  kinds: [], savedAt: Self.t0))
        let model = VaultDocumentModelTests.model(rig)
        await model.opened()
        #expect(model.entries == [Self.library])
        let (backup, folder) = Self.backup(rig); defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await backup.restore(try VaultBackupContents(madeAt: Self.t0, document: Self.sample()), mode: .addMissing) == .success(3))
        await waitUntil("the restore's notice reached the panel") { model.contents != .loaded }
        #expect(model.contents == .notLoaded && model.entries.isEmpty, "what it held is no longer the Vault")
        #expect(await model.unlock())
        #expect(model.entries.count == 3 && model.finds.count == 1)
    }

    // MARK: Settings ▸ Set Aside, through the model

    @Test func setAsideIsCountedAndForgottenInTheDocumentOnlyWhileItIsOpen() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try Self.documentVault(rig, Self.sample(fingerprints: ["aa", "bb"]))
        let model = VaultDocumentModelTests.model(rig)
        #expect(model.setAsideCount == nil, "sealed in the document until it opens")
        #expect(!model.forgetSetAside())
        #expect(try Self.document(rig).setAside.fingerprints == ["aa", "bb"], "a locked Vault's numbers are not forgotten")

        await model.opened()
        #expect(model.setAsideCount == 2)
        #expect(model.forgetSetAside())
        #expect(model.setAsideCount == 0)
        let now = try Self.document(rig)
        #expect(now.setAside.fingerprints.isEmpty && now.setAside.generation == 4)
        #expect(rig.defaults.object(forKey: VaultSetAside.key) == nil, "nothing in UserDefaults")
    }

    @Test func setAsideInAV1VaultIsCountedAndForgottenInItsDefaults() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let store = VaultStore(fileURL: rig.scratch.fileURL, keychain: rig.keychain, migrating: false)
        try store.save([Self.library])
        rig.defaults.set(["aa", "bb", "cc"], forKey: VaultSetAside.key)
        let model = VaultModel(store: store, authenticator: rig.auth, defaults: rig.defaults, copyToPasteboard: { _ in })
        #expect(model.setAsideCount == 3, "counted locked too: UserDefaults holds them")
        #expect(model.forgetSetAside())
        #expect(model.setAsideCount == 0)
        #expect(VaultSetAside.generation(in: rig.defaults) == 1)
    }
}
