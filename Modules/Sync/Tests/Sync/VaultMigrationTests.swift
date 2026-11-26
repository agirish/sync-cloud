import Foundation
import Testing
@testable import Sync

/// The v1 files made into the v7.2 document (``VaultMigration``), as a pure function: every
/// committed format file, made-up UserDefaults values, and each way it refuses. Every number is
/// made up.
@Suite struct VaultMigrationTests {
    static let key = VaultFormatTests.key
    static let day = VaultFormatTests.day
    static let keyID = VaultDocument.keyID(for: key)

    static func plain(_ fixture: String, marker: Data) throws -> (plain: Data, digest: String) {
        let sealed = try VaultFormatTests.fixture(fixture)
        return (try VaultFile.openPlain(sealed, marker: marker, with: key), VaultMigration.digest(sealed))
    }

    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    static func entriesJSON(_ entries: [VaultEntry]) throws -> [[String: Any]] {
        try entries.map { try #require(JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(VaultLegacyFormat.Entry($0))) as? [String: Any]) }
    }

    @Test func aStoreMadeWithoutSayingFollowsTheGate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(VaultStore(fileURL: folder.appendingPathComponent("vault.sealed"), keychain: VaultFakeKeychain()).migrating == VaultMigration.enabled)
        #expect(VaultStore(fileURL: folder.appendingPathComponent("vault.sealed"), keychain: VaultFakeKeychain(), migrating: false).migrating == false)
    }

    /// The app's own preferences are the Vault's in Application Support alone: a store over any
    /// other file never takes their moved keys in, nor removes them (the app's test host runs with
    /// the owner's preferences).
    @Test func onlyTheRealVaultTakesTheAppsOwnPreferences() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = VaultStore(fileURL: folder.appendingPathComponent("vault.sealed"), keychain: VaultFakeKeychain(), migrating: true)
        let suite = "VaultMigrationTests.\(UUID().uuidString)"
        let scratch = try #require(UserDefaults(suiteName: suite))
        defer { scratch.removePersistentDomain(forName: suite) }
        #expect(store.ownsMovedKeys(in: scratch))
        #expect(!store.ownsMovedKeys(in: .standard))
        scratch.set(["ff00"], forKey: VaultSetAside.key)
        #expect(store.needsMigration(defaults: scratch))
        #expect(!store.needsMigration(defaults: .standard))
        let document = VaultDocument(entries: [], state: VaultReadingState(), setAside: .init(), kinds: [], savedAt: Self.day)
        #expect(store.setAsideLeftInDefaults(by: document, defaults: .standard).isEmpty)
    }

    // MARK: Every committed file

    @Test(arguments: ["vault-format-1", "vault-format-2", "vault-format-3", "vault-format-4", "vault-format-5", "vault-format-6"])
    func everyCommittedVaultFormatMigratesAndChecksItself(_ name: String) throws {
        let vault = try Self.plain(name, marker: VaultFile.marker)
        let loaded = try VaultFile.records(fromList: #require(JSONSerialization.jsonObject(with: vault.plain) as? [Any])).entries
        for readingName in [nil, "vault-reading-format-1", "vault-reading-format-2"] {
            let reading = try readingName.map { try Self.plain($0, marker: VaultFile.readingMarker) }
            let legacy = VaultMigration.Legacy(vaultPlain: vault.plain, vaultDigest: vault.digest,
                                               readingPlain: reading?.plain, readingDigest: reading?.digest,
                                               setAside: ["ff00", "aa11"], generation: 2,
                                               customKinds: try JSONEncoder().encode([VaultCustomKind(id: "kind-1", name: "Memberships", group: "home")]))
            let (document, cache, report) = try VaultMigration.migrate(legacy, keyID: Self.keyID, at: Self.day)
            #expect(report.saved == loaded.count && report.files == (reading == nil ? 1 : 2))
            #expect(try document.entries() == loaded)
            #expect(Set(try document.entries().map(\.id)) == Set(loaded.map(\.id)))
            if let reading {
                let state = try VaultFile.jsonDecoder().decode(VaultReadingState.self, from: reading.plain)
                #expect(try document.finds() == state.finds)
                #expect(VaultMigration.normalized(try document.readingState(cache: cache)) == VaultMigration.normalized(state))
                #expect(document.reading.readerVersion == state.version)
            } else {
                #expect(try document.finds().isEmpty)
            }
            #expect(document.setAside == .init(generation: 2, keyID: Self.keyID, fingerprints: ["aa11", "ff00"]))
            #expect(document.kinds.map(\.id) == ["kind-1"])
            #expect(document.migratedFrom == .init(vault: vault.digest, reading: reading?.digest, fingerprints: 2))
            #expect(document.format == VaultDocument.format)
            // And it seals and opens as this build's document.
            let reopened = try VaultDocument.open(plain: VaultFile.jsonEncoder().encode(document))
            #expect(reopened.document == document && !reopened.readOnly)
        }
    }

    @Test func theCommittedBackupsEntriesMigrateToo() throws {
        let contents = try VaultBackupFile.open(VaultFormatTests.fixture("vault-backup-format-1"),
                                                passphrase: VaultFormatTests.backupPassphrase)
        let plain = try Self.json(Self.entriesJSON(contents.entries))
        let (document, _, report) = try VaultMigration.migrate(.init(vaultPlain: plain), keyID: Self.keyID, at: Self.day)
        #expect(report.saved == 4)
        #expect(try document.entries() == contents.entries)
    }

    // MARK: Made-up data

    @Test func aReadingFileAloneOrTheDefaultsAloneMigrate() throws {
        let reading = try Self.plain("vault-reading-format-2", marker: VaultFile.readingMarker)
        let alone = try VaultMigration.migrate(.init(readingPlain: reading.plain, readingDigest: reading.digest),
                                               keyID: Self.keyID, at: Self.day)
        #expect(alone.report.saved == 0 && alone.report.waiting == 1)
        #expect(alone.document.migratedFrom?.vault == nil && alone.document.migratedFrom?.reading == reading.digest)
        #expect(alone.document.names == ["PATEXAMPIE": "Pat Example"])

        let defaults = try VaultMigration.migrate(.init(setAside: ["bb", "aa", "bb"], generation: 7), keyID: Self.keyID, at: Self.day)
        #expect(defaults.document.records.isEmpty)
        #expect(defaults.document.setAside.fingerprints == ["aa", "bb"], "sorted, once each")
        #expect(defaults.document.setAside.generation == 7)
        #expect(defaults.cache.generation == 7 && defaults.cache.readerVersion == VaultReading.version)
        #expect(defaults.report.files == 0 && defaults.report.fingerprints == 2)
    }

    @Test func aKindWithNoNameIsNoneAsTheV1LoadReadsIt() throws {
        let kinds = [VaultCustomKind(id: "a", name: "Memberships", group: "home"), VaultCustomKind(id: "b", name: "  ", group: "home")]
        let migrated = try VaultMigration.migrate(.init(customKinds: try JSONEncoder().encode(kinds)), keyID: Self.keyID, at: Self.day)
        #expect(migrated.document.kinds.map(\.id) == ["a"])
    }

    @Test func eachSavedIDsShapeFromOlderBuildsIsWhatItMeant() throws {
        // A bare kind and `older`, a person beside the household, a `dated`, and empty hand fields.
        let plain = Data("""
            [{"addedAt":"2027-01-15T08:00:00Z","id":"00000000-0000-0000-0000-000000000004","kind":"identity",\
            "note":"","older":true,"title":"Passport (old)","updatedAt":"2027-01-15T08:00:00Z","value":"Z0000002"},
            {"addedAt":"2027-01-15T08:00:00Z","id":"00000000-0000-0000-0000-000000000005","kind":"money","household":true,\
            "personID":"pat","dated":"2027-01-01T00:00:00Z","fields":[],"note":"","title":"Car loan","updatedAt":"2027-01-15T08:00:00Z","value":"CL000001"}]
            """.utf8)
        let entries = try VaultMigration.migrate(.init(vaultPlain: plain), keyID: Self.keyID, at: Self.day).document.entries()
        #expect(entries[0].category == .passport && entries[0].pin == .older)
        #expect(entries[1].category == .loans && entries[1].assignment == .household && entries[1].personID == nil)
        #expect(entries[1].facts?.dated == nil && entries[1].fields == nil)
    }

    // MARK: Refusals

    @Test func aRecordThatDoesNotDecodeStopsItAll() throws {
        var list = try Self.entriesJSON(VaultFormatTests.formatEntries6())
        var later = list[0]
        later["category"] = "bankAccount"
        later["id"] = UUID().uuidString
        list.append(later)
        #expect(throws: VaultMigration.Refusal.vault(undecodable: 1, unexpected: 0)) {
            try VaultMigration.migrate(.init(vaultPlain: Self.json(list)), keyID: Self.keyID, at: Self.day)
        }
        #expect(throws: VaultMigration.Refusal.vault(undecodable: 1, unexpected: 0)) {
            try VaultMigration.migrate(.init(vaultPlain: Data(#"{"entries":[]}"#.utf8)), keyID: Self.keyID, at: Self.day)
        }
    }

    @Test func aKeyAtAnyDepthThisBuildDoesNotReadStopsIt() throws {
        let list = try Self.entriesJSON(VaultFormatTests.formatEntries6())
        // On the record.
        var top = list
        top[1]["laterField"] = ["a": 1]
        #expect(throws: VaultMigration.Refusal.vault(undecodable: 0, unexpected: 1)) {
            try VaultMigration.migrate(.init(vaultPlain: Self.json(top)), keyID: Self.keyID, at: Self.day)
        }
        // In its facts, and in one of its sources.
        var nested = list
        var facts = try #require(nested[1]["facts"] as? [String: Any])
        facts["laterFact"] = true
        var sources = try #require(facts["sources"] as? [[String: Any]])
        sources[0]["laterSourceKey"] = "x"
        facts["sources"] = sources
        nested[1]["facts"] = facts
        #expect(throws: VaultMigration.Refusal.vault(undecodable: 0, unexpected: 2)) {
            try VaultMigration.migrate(.init(vaultPlain: Self.json(nested)), keyID: Self.keyID, at: Self.day)
        }
        // A stored null is no key.
        var null = list
        null[0]["holderName"] = NSNull()
        #expect(try VaultMigration.migrate(.init(vaultPlain: Self.json(null)), keyID: Self.keyID, at: Self.day).report.saved == 4)
    }

    @Test func aReadingFileWithWhatItsLenientDecodingDropsStopsIt() throws {
        let reading = try Self.plain("vault-reading-format-2", marker: VaultFile.readingMarker)
        var object = try #require(JSONSerialization.jsonObject(with: reading.plain) as? [String: Any])
        // A later build's top-level field.
        var later = object
        later["laterReading"] = 1
        #expect(throws: VaultMigration.Refusal.reading(undecodable: 0, unexpected: 1)) {
            try VaultMigration.migrate(.init(readingPlain: Self.json(later)), keyID: Self.keyID, at: Self.day)
        }
        // A name in a later shape, which the v1 load holds aside rather than reads.
        var names = object
        names["names"] = ["PATEXAMPIE": ["full": "Pat Example"]]
        #expect(throws: VaultMigration.Refusal.reading(undecodable: 0, unexpected: 1)) {
            try VaultMigration.migrate(.init(readingPlain: Self.json(names)), keyID: Self.keyID, at: Self.day)
        }
        // A lenient field of the wrong type.
        var stale = object
        stale["staleSources"] = "not a list"
        #expect(throws: VaultMigration.Refusal.reading(undecodable: 0, unexpected: 1)) {
            try VaultMigration.migrate(.init(readingPlain: Self.json(stale)), keyID: Self.keyID, at: Self.day)
        }
        // A key inside a waiting ID.
        var finds = try #require(object["finds"] as? [[String: Any]])
        finds[0]["laterFind"] = 1
        object["finds"] = finds
        #expect(throws: VaultMigration.Refusal.reading(undecodable: 0, unexpected: 1)) {
            try VaultMigration.migrate(.init(readingPlain: Self.json(object)), keyID: Self.keyID, at: Self.day)
        }
        #expect(throws: VaultMigration.Refusal.reading(undecodable: 1, unexpected: 0)) {
            try VaultMigration.migrate(.init(readingPlain: Data("[]".utf8)), keyID: Self.keyID, at: Self.day)
        }
    }

    @Test func aMovedDefaultsValueNotInItsShapeStopsIt() throws {
        let cases: [VaultMigration.Legacy] = [
            .init(setAside: "aa"), .init(setAside: [1, 2]), .init(generation: "3"), .init(generation: true),
            .init(customKinds: Data("[{\"id\":1}]".utf8)), .init(customKinds: "Memberships"),
            .init(customKinds: try Self.json([["id": "a", "name": "M", "group": "home", "later": 1]])),
        ]
        for legacy in cases {
            #expect(throws: VaultMigration.Refusal.defaults(1)) { try VaultMigration.migrate(legacy, keyID: Self.keyID, at: Self.day) }
        }
    }

    @Test func theSelfCheckRefusesADocumentThatDoesNotGiveTheV1FilesBack() throws {
        let vault = try Self.plain("vault-format-6", marker: VaultFile.marker)
        let reading = try Self.plain("vault-reading-format-2", marker: VaultFile.readingMarker)
        let legacy = VaultMigration.Legacy(vaultPlain: vault.plain, readingPlain: reading.plain)
        let (document, cache, _) = try VaultMigration.migrate(legacy, keyID: Self.keyID, at: Self.day)
        let entries = try VaultLegacyFormat.entries(fromPlain: vault.plain)
        let state = try VaultLegacyFormat.readingState(fromPlain: reading.plain)
        func check(_ document: VaultDocument, _ cache: VaultCache) throws {
            try VaultMigration.selfCheck(document, cache, against: legacy, entries: entries, state: state, fingerprints: [],
                                         generation: 0, kinds: [], people: [], folders: [], at: Self.day)
        }
        try check(document, cache)

        var dropped = document
        dropped.records.remove(at: 0)
        #expect(throws: VaultMigration.Refusal.selfCheck("the count of saved IDs")) { try check(dropped, cache) }
        var reissued = document
        reissued.records[0].id = UUID()
        #expect(throws: VaultMigration.Refusal.selfCheck("the saved IDs")) { try check(reissued, cache) }
        var retitled = document
        retitled.records[0].title += "!"
        #expect(throws: VaultMigration.Refusal.selfCheck("a saved ID")) { try check(retitled, cache) }
        var unwaited = document
        unwaited.records.removeLast()
        #expect(throws: VaultMigration.Refusal.selfCheck("the waiting IDs")) { try check(unwaited, cache) }
        var renamed = document
        renamed.names = [:]
        #expect(throws: VaultMigration.Refusal.selfCheck("the reading state")) { try check(renamed, cache) }
        var unread = cache
        unread.read = [:]
        #expect(throws: VaultMigration.Refusal.selfCheck("the reading state")) { try check(document, unread) }
        var fingerprinted = document
        fingerprinted.setAside.fingerprints = ["aa"]
        #expect(throws: VaultMigration.Refusal.selfCheck("the set-aside numbers or kinds")) { try check(fingerprinted, cache) }
    }

    @Test func theDigestIsTheBytesSHA256() {
        #expect(VaultMigration.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
