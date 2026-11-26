import CryptoKit
import Foundation
import Testing
@testable import Sync

/// The v7.2 document on disk (``VaultStore``): its writes and their guards, the cache, the lock,
/// and the gated migration's steps. Scratch folders and a fake Keychain only; every number is made up.
@Suite struct VaultDocumentStoreTests {
    static let key = VaultFormatTests.key
    static let day = VaultFormatTests.day

    struct Setup {
        let scratch: VaultScratch
        let keychain = VaultFakeKeychain()
        let defaults = vaultScratchDefaults("vault-document-store")
        let clock = VaultTestClock()
        var otherCopy = false

        init(withKey: Bool = true) throws {
            scratch = try VaultScratch()
            if withKey { keychain.itemData = VaultDocumentStoreTests.key.withUnsafeBytes { Data($0) } }
            try FileManager.default.createDirectory(at: scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        func store(migrating: Bool = true, otherCopy: Bool = false) -> VaultStore {
            let clock = clock
            return VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: { clock.now }, migrating: migrating,
                              anotherCopyRunning: { otherCopy })
        }

        var folder: URL { scratch.fileURL.deletingLastPathComponent() }
        func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        func bytes(_ name: String) -> Data? { FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) }
        func write(_ data: Data, _ name: String) throws { try data.write(to: folder.appendingPathComponent(name)) }
    }

    static func document(_ entries: [VaultEntry], finds: [VaultFind] = []) -> VaultDocument {
        VaultDocument(entries: entries, state: VaultReadingState(finds: finds), setAside: .init(), kinds: [], savedAt: day)
    }

    static func entry(_ n: Int) -> VaultEntry {
        VaultEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, title: "Card \(n)",
                   value: "LIB\(10_000 + n)", addedAt: day, category: .other)
    }

    // MARK: The gate

    @Test func aStoreMadeAsTheAppMakesItMigratesAndBeginsADocument() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = VaultStore(fileURL: setup.scratch.fileURL, keychain: setup.keychain)
        #expect(store.migrating == VaultMigration.enabled)
        #expect(store.keepsDocument == VaultMigration.enabled, "a Vault begun with the gate on is a document")
    }

    @Test func withTheGateOffAStoreNeverMigratesOrBeginsADocument() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = VaultStore(fileURL: setup.scratch.fileURL, keychain: setup.keychain, migrating: false)
        #expect(!store.migrating)
        #expect(!store.keepsDocument, "a Vault begun with the gate off is a v1 Vault")
        try store.save([Self.entry(1)])
        #expect(store.fileFormat == .v1)
        setup.defaults.set(["aa"], forKey: VaultSetAside.key)
        #expect(!store.needsMigration(defaults: setup.defaults))
        #expect(store.migrate(defaults: setup.defaults) == .notNeeded)
        #expect(store.fileFormat == .v1 && setup.defaults.stringArray(forKey: VaultSetAside.key) == ["aa"])
        #expect(!setup.names().contains { $0.contains("premigration") || $0 == "vault-cache.sealed" || $0 == "vault.lock" })
    }

    // MARK: Writing and reading

    @Test func aDocumentSealsOpensAndIsStampedAsThisBuilds() throws {
        let setup = try Setup(withKey: false); defer { setup.scratch.remove() }
        let store = setup.store()
        #expect(try store.loadDocument() == nil)
        let written = try store.saveDocument(Self.document([Self.entry(1)], finds: [VaultRecordTests.fullFind()]), expecting: .absent)
        #expect(setup.keychain.itemData != nil, "the first save makes the key")
        #expect(store.fileFormat == .document)
        let key = SymmetricKey(data: try #require(setup.keychain.itemData))
        #expect(written.document.setAside.keyID == VaultDocument.keyID(for: key))
        #expect(written.document.savedAt == setup.clock.now && written.document.savedBy == VaultDocument.thisBuild)
        let loaded = try #require(try store.loadDocument())
        #expect(loaded.document == written.document && loaded.onDisk == written.onDisk && !loaded.readOnly)
        #expect(try loaded.document.entries() == [Self.entry(1)])
        // A v1 build's load and save both refuse it.
        #expect(throws: VaultError.unreadableFile) { try store.loadRecords() }
        #expect(throws: VaultError.unreadableFile) { try store.save([Self.entry(2)]) }
        #expect(store.fileFormat == .document)
    }

    @Test func aDocumentIsNeverWrittenOverAV1FileOrALaterBuildsDocument() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = setup.store()
        try store.save([Self.entry(1)])
        #expect(throws: VaultError.unreadableFile) { try store.saveDocument(Self.document([Self.entry(1)]), expecting: nil) }
        #expect(store.fileFormat == .v1)

        try FileManager.default.removeItem(at: setup.scratch.fileURL)
        var later = try #require(JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(Self.document([Self.entry(1)]))) as? [String: Any])
        later["format"] = VaultDocument.format + 1
        later["laterField"] = true
        let sealed = try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: later), marker: VaultDocument.marker, with: Self.key)
        try setup.write(sealed, "vault.sealed")
        let loaded = try #require(try store.loadDocument())
        #expect(loaded.readOnly)
        #expect(try loaded.document.entries() == [Self.entry(1)])
        #expect(throws: VaultError.unreadableFile) { try store.saveDocument(loaded.document, expecting: loaded.onDisk) }
        #expect(setup.bytes("vault.sealed") == sealed)
    }

    @Test func aSaveOverAnotherCopysIsRefused() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = setup.store()
        let first = try store.saveDocument(Self.document([Self.entry(1)]), expecting: .absent)
        let second = try store.saveDocument(Self.document([Self.entry(1), Self.entry(2)]), expecting: first.onDisk)
        #expect(throws: VaultError.changedElsewhere) {
            try store.saveDocument(Self.document([Self.entry(1), Self.entry(3)]), expecting: first.onDisk)
        }
        #expect(try store.loadDocument()?.onDisk == second.onDisk)
        try FileManager.default.removeItem(at: setup.scratch.fileURL)
        #expect(throws: VaultError.changedElsewhere) { try store.saveDocument(Self.document([]), expecting: second.onDisk) }
    }

    @Test func theShortListGuardCountsSavedRecordsOnly() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = setup.store()
        let finds = (1...3).map { n in
            VaultFind(title: "Plan", value: "XX00000\(n)", facts: VaultReadFacts(category: .health,
                      sources: [VaultSource(path: "Health/\(n).pdf", role: "Card", rank: 30)]))
        }
        var state = try store.saveDocument(Self.document((1...4).map(Self.entry), finds: finds), expecting: .absent).onDisk
        // Every waiting record gone at once: not the user's to lose.
        state = try store.saveDocument(Self.document((1...4).map(Self.entry)), expecting: state).onDisk
        // One saved record gone: Delete.
        state = try store.saveDocument(Self.document((1...3).map(Self.entry)), expecting: state).onDisk
        #expect(throws: VaultError.wouldDrop(2)) { try store.saveDocument(Self.document([Self.entry(1)]), expecting: state) }
        #expect(try store.loadDocument()?.document.savedIDs.count == 3)
    }

    @Test func aBackupIsKeptOnlyWhenSavedRecordsOrTheUsersOwnDataChange() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = setup.store()
        var document = Self.document([Self.entry(1)])
        var state = try store.saveDocument(document, expecting: .absent).onDisk
        #expect(store.backups.isEmpty)
        // A waiting record and the reading rules: no backup.
        document.records.append(VaultRecord(VaultRecordTests.fullFind()))
        document.reading.needsReadAgain = true
        setup.clock.advance(1)
        state = try store.saveDocument(document, expecting: state).onDisk
        #expect(store.backups.isEmpty)
        // A name corrected everywhere: a backup of the file before.
        let before = try #require(setup.bytes("vault.sealed"))
        document.names["PATEXAMPIE"] = "Pat Example"
        setup.clock.advance(1)
        state = try store.saveDocument(document, expecting: state).onDisk
        #expect(store.backups.count == 1)
        #expect(FileManager.default.contents(atPath: store.backups[0].path) == before)
        // A saved record: another.
        document.records.insert(VaultRecord(Self.entry(2)), at: 1)
        setup.clock.advance(1)
        _ = try store.saveDocument(document, expecting: state)
        #expect(store.backups.count == 2)
    }

    @Test func theLockIsHeldAroundTheSwapAndLetGo() async throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = setup.store()
        _ = try store.saveDocument(Self.document([Self.entry(1)]), expecting: .absent)
        #expect(setup.names().contains("vault.lock"))
        let descriptor = open(store.lockURL.path, O_RDWR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "free once the save is done")
        // Held by another: the save waits for it.
        let url = setup.scratch.fileURL, keychain = setup.keychain
        let saving = Task.detached { () -> Bool in
            let other = VaultStore(fileURL: url, keychain: keychain, migrating: true, anotherCopyRunning: { false })
            return (try? other.saveDocument(Self.document([Self.entry(1), Self.entry(2)]), expecting: nil)) != nil
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try store.loadDocument()?.document.savedIDs.count == 1, "not swapped while the lock is held")
        flock(descriptor, LOCK_UN)
        #expect(await saving.value)
        #expect(try store.loadDocument()?.document.savedIDs.count == 2)
    }

    // MARK: The cache

    @Test func theCacheSealsApartAndOneThatDoesNotOpenIsSetAsideAndStartedFresh() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = setup.store()
        _ = try store.saveDocument(Self.document([Self.entry(1)]), expecting: .absent)
        let cache = VaultCache(try VaultRecordTests.fullState())
        try store.saveCache(cache)
        #expect(try store.loadDocument()?.cache == cache)

        try setup.write(Data("SCVCACH1 not sealed".utf8), "vault-cache.sealed")
        #expect(try store.loadDocument()?.cache == nil)
        #expect(!setup.names().contains("vault-cache.sealed"))
        #expect(setup.names().contains { $0.hasPrefix("vault-cache.sealed.unreadable-") })
    }

    @Test func aCacheIsNeverMadeWithoutAKey() throws {
        let setup = try Setup(withKey: false); defer { setup.scratch.remove() }
        #expect(throws: VaultError.notWritten) { try setup.store().saveCache(VaultCache(readerVersion: 1, generation: 0)) }
        #expect(setup.keychain.itemData == nil)
    }

    @Test func setAsideAndAKeyMadeAnewMoveTheCacheToo() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let store = setup.store()
        _ = try store.saveDocument(Self.document([Self.entry(1)]), expecting: .absent)
        try store.saveCache(VaultCache(readerVersion: 1, generation: 0))
        #expect(store.setAside(at: Self.day))
        #expect(setup.names().contains { $0.hasPrefix("vault-cache.sealed.set-aside-") })
        #expect(!setup.names().contains("vault-cache.sealed"))
        #expect(store.moveAsideForReplace(at: Self.day) == [])

        // A lost key: the cache it sealed is set aside before a new key is made.
        try setup.write(Data("SCVCACH1 old".utf8), "vault-cache.sealed")
        try? FileManager.default.removeItem(at: setup.scratch.fileURL)
        for name in setup.names() where name.contains("set-aside") { try FileManager.default.removeItem(at: setup.folder.appendingPathComponent(name)) }
        setup.keychain.itemData = nil
        _ = try store.saveDocument(Self.document([Self.entry(1)]), expecting: .absent)
        #expect(setup.names().contains { $0.hasPrefix("vault-cache.sealed.set-aside-") })
    }

    // MARK: Migrating

    /// The committed v1 files and made-up defaults, on a scratch disk.
    static func v1(_ setup: Setup) throws -> (vault: Data, reading: Data) {
        let vault = try VaultFormatTests.fixture("vault-format-6")
        let reading = try VaultFormatTests.fixture("vault-reading-format-2")
        try setup.write(vault, "vault.sealed")
        try setup.write(reading, "vault-reading.sealed")
        setup.defaults.set(["ff00", "aa11"], forKey: VaultSetAside.key)
        setup.defaults.set(2, forKey: VaultSetAside.generationKey)
        setup.defaults.set(try JSONEncoder().encode([VaultCustomKind(id: "kind-1", name: "Memberships", group: "home")]),
                           forKey: VaultKinds.key)
        return (vault, reading)
    }

    @Test func aMigrationTakesEveryStepInOrderAndNeedsDoingOnce() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let (vault, reading) = try Self.v1(setup)
        let store = setup.store()
        #expect(store.needsMigration(defaults: setup.defaults))
        guard case .migrated(let report) = store.migrate(defaults: setup.defaults) else { Issue.record("not migrated"); return }
        #expect(report.saved == 4 && report.waiting == 1 && report.fingerprints == 2 && report.kinds == 1 && report.files == 2)

        let stamp = Int(setup.clock.now.timeIntervalSince1970)
        // 1. The copy of its own, outside the rotation, and the newest backup.
        #expect(setup.bytes("vault.sealed.v1-premigration-\(stamp)") == vault)
        #expect(store.backups.count == 1 && FileManager.default.contents(atPath: store.backups[0].path) == vault)
        // 2. The document.
        let loaded = try #require(try store.loadDocument())
        #expect(store.fileFormat == .document && !loaded.readOnly)
        #expect(try loaded.document.entries() == (try VaultFormatTests.formatEntries6()))
        #expect(loaded.document.migratedFrom == .init(vault: VaultMigration.digest(vault), reading: VaultMigration.digest(reading),
                                                      fingerprints: 2))
        #expect(loaded.document.setAside.fingerprints == ["aa11", "ff00"] && loaded.document.setAside.generation == 2)
        // 3. The cache.
        let state = try VaultFile.open(VaultReadingState.self, reading, marker: VaultFile.readingMarker, with: Self.key)
        #expect(loaded.cache == VaultCache(state))
        // 4. The reading file, renamed and kept.
        #expect(!store.hasReadingFile)
        #expect(setup.bytes("vault-reading.sealed.migrated-\(stamp)") == reading)
        // 5. The moved keys.
        for key in VaultMigration.movedKeys { #expect(setup.defaults.object(forKey: key) == nil) }

        #expect(!store.needsMigration(defaults: setup.defaults))
        #expect(store.migrate(defaults: setup.defaults) == .notNeeded)
        #expect(store.backups.count == 1, "nothing written again")
    }

    @Test func eachOpenFinishesStepsFourAndFive() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let (_, reading) = try Self.v1(setup)
        let store = setup.store()
        guard case .migrated = store.migrate(defaults: setup.defaults) else { Issue.record("not migrated"); return }
        let document = try #require(try store.loadDocument()).document
        // As if stopped after step 3: the reading file and the keys back.
        try setup.write(reading, "vault-reading.sealed")
        setup.defaults.set(["ff00", "aa11"], forKey: VaultSetAside.key)
        setup.defaults.set(2, forKey: VaultSetAside.generationKey)
        setup.clock.advance(10)
        store.finishMigration(of: document, defaults: setup.defaults)
        #expect(!store.hasReadingFile)
        #expect(setup.bytes("vault-reading.sealed.migrated-\(Int(setup.clock.now.timeIntervalSince1970))") == reading)
        #expect(setup.defaults.object(forKey: VaultSetAside.key) == nil && setup.defaults.object(forKey: VaultSetAside.generationKey) == nil)

        // A reading file it was not made from: set aside unmerged.
        let other = try VaultFile.seal(VaultReadingState(), marker: VaultFile.readingMarker, with: Self.key)
        try setup.write(other, "vault-reading.sealed")
        store.finishMigration(of: document, defaults: setup.defaults)
        #expect(!store.hasReadingFile)
        #expect(setup.names().contains { $0.hasPrefix("vault-reading.sealed.set-aside-") })

        // Fingerprints the document lacks are the caller's to take in; the key stays until then.
        setup.defaults.set(["ff00", "cc22"], forKey: VaultSetAside.key)
        store.finishMigration(of: document, defaults: setup.defaults)
        #expect(store.setAsideLeftInDefaults(by: document, defaults: setup.defaults) == ["cc22"])
        #expect(setup.defaults.stringArray(forKey: VaultSetAside.key) == ["ff00", "cc22"])
        // With the gate off, none of it.
        #expect(setup.store(migrating: false).setAsideLeftInDefaults(by: document, defaults: setup.defaults).isEmpty)
    }

    @Test func aMigrationRefusedChangesNothing() throws {
        for refusal in ["another copy", "undecodable", "no key", "damaged"] {
            let setup = try Setup(); defer { setup.scratch.remove() }
            var (vault, _) = try Self.v1(setup)
            if refusal == "undecodable" {
                var list = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(vault, marker: VaultFile.marker, with: Self.key)) as? [[String: Any]])
                list[0]["category"] = "bankAccount"
                vault = try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: list), marker: VaultFile.marker, with: Self.key)
                try setup.write(vault, "vault.sealed")
            }
            if refusal == "damaged" {
                vault = Data("SCVAULT1".utf8) + Data(repeating: 7, count: 64)
                try setup.write(vault, "vault.sealed")
            }
            if refusal == "no key" { setup.keychain.itemData = nil }
            let before = setup.names()
            let readingBefore = setup.bytes("vault-reading.sealed")
            let outcome = setup.store(otherCopy: refusal == "another copy").migrate(defaults: setup.defaults)
            guard case .refused(let why) = outcome else { Issue.record("\(refusal): \(outcome)"); continue }
            switch refusal {
            case "another copy": #expect(why == .anotherCopyRunning)
            case "undecodable": #expect(why == .vault(undecodable: 1, unexpected: 0))
            case "no key": #expect(why == .unopened("the Vault’s key"))
            default: #expect(why == .unopened("the Vault’s file"))
            }
            // The lock file aside: it holds nothing, and is there for the next try.
            #expect(setup.names().filter { $0 != "vault.lock" } == before, "\(refusal): a file added or removed")
            #expect(setup.bytes("vault.sealed") == vault && setup.bytes("vault-reading.sealed") == readingBefore)
            #expect(setup.defaults.stringArray(forKey: VaultSetAside.key) == ["ff00", "aa11"])
        }
    }

    /// Refused at its write, after step 1: the copy it made goes again, so a migration refused at
    /// every open does not leave one more full copy each time (the final review).
    @Test func aMigrationRefusedAtItsWriteTakesItsCopyBack() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        let (vault, _) = try Self.v1(setup)
        let disk = VaultChoosingTests.Disk(vault: setup.scratch.fileURL.lastPathComponent)
        disk.refusing = true
        let clock = setup.clock
        let store = VaultStore(fileURL: setup.scratch.fileURL, keychain: setup.keychain, fileManager: disk,
                               clock: { clock.now }, migrating: true, anotherCopyRunning: { false })
        #expect(store.migrate(defaults: setup.defaults) == .refused(.unopened("the write")))
        #expect(!setup.names().contains { $0.contains("premigration") }, "the copy was left behind")
        #expect(setup.bytes("vault.sealed") == vault)
        disk.refusing = false
        guard case .migrated = store.migrate(defaults: setup.defaults) else { Issue.record("not migrated"); return }
        #expect(setup.names().filter { $0.contains("premigration") }.count == 1, "kept once it migrated")
    }

    @Test func aMissingVaultWithAReadingFileOrMovedKeysMigrates() throws {
        let setup = try Setup(); defer { setup.scratch.remove() }
        _ = try Self.v1(setup)
        try FileManager.default.removeItem(at: setup.scratch.fileURL)
        let store = setup.store()
        #expect(store.needsMigration(defaults: setup.defaults))
        guard case .migrated(let report) = store.migrate(defaults: setup.defaults) else { Issue.record("not migrated"); return }
        #expect(report.saved == 0 && report.waiting == 1 && report.files == 1)
        #expect(!setup.names().contains { $0.contains("premigration") }, "no v1 Vault to copy")
        #expect(try store.loadDocument()?.document.migratedFrom?.vault == nil)
    }
}
