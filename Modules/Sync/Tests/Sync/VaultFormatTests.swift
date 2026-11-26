import CryptoKit
import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// What is on disk and how it survives: the committed format files (VT21), records a later build
/// wrote (VT30), backups and the short-list guard (VT20), and files that do not open (VT24).
/// Every number in them is made up.
@Suite struct VaultFormatTests {
    /// The key the committed files are sealed with. Never a real Vault's.
    static let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    static let day = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: The committed files (VT21)

    /// Each committed file's SHA-256, so a deleted one made again by today's build (which would
    /// pin nothing) is caught.
    static let fixtureDigests = [
        "vault-format-1": "395698fe0a1221661a3ef299c63cafb1056199e4253f4d31e96d3d61ab9a0b54",
        "vault-format-2": "aea993a8c3a1cd21082df06d4699e95b6eafa41471ef6819d77b8a179b91429f",
        "vault-format-3": "e2e8d9e15b4adcaca37e933dce570e16534c552bef2e11e71784fc66b1213087",
        "vault-format-4": "0627c70c3f49fb757de21e766d7e48257ab4863ec609012763bf813b00ea0907",
        "vault-format-5": "4b3ef709c521bbeb34fbd01a90465cbf5a212555719f24ccc82385a3f890c53b",
        "vault-format-6": "9bd4934791f065fac32adc82dd8557b9dacfad3f948709a5d2344416ec678a32",
        "vault-reading-format-1": "dfea3a1d18ce338ad86da7357d860940c0916df3be5c7d675ac6c586563b2e01",
        "vault-reading-format-2": "d9d2f4c085a4949f0aa6f911897b9602d7ab1132afd5e1e964dc118b349a5aba",
        "vault-backup-format-1": "e8804f03ce79d39910a34e70e60fedb212c86ce50019c09aaa9ddbd36633735b",
        "vault-activity-format-1": "f71977411a8302757bc866c370ae41786dbc1d76ec1d818f525d1bd445eb1232",
        "vault-document-format-1": "54747d5f9c74d3bfd12ad4409d22f7a2b818b316cbd1df75b34a6909f6f3a574",
        "vault-cache-format-1": "1aa44b8e93806ce9d71ff0bacc8ca88657611e40c5550cd7bb821cba0546e860",
    ]

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "sealed",
                                                 subdirectory: "Fixtures/Vault"))
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == fixtureDigests[name], "\(name) is not the committed file: a format file is never made again")
        return data
    }

    /// Every field a record can store, set: a typed number, a read one, a household one on another
    /// kind's card, and one from a build before pins and categories.
    static func formatEntries() throws -> [VaultEntry] {
        var loan = VaultEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                              title: "Mortgage loan number", value: "0000-1111-22", personID: "pat",
                              note: "Home loan servicer", addedAt: day,
                              updatedAt: day.addingTimeInterval(60), category: .loans)
        loan.pin = .current
        loan.geo = .us
        loan.card = .custom("kind-1")

        let facts = VaultReadFacts(
            category: .passport, holder: "PAT EXAMPLE", born: day.addingTimeInterval(-900_000_000),
            issuer: "USA", form: "Passport", dated: day, validUntil: day.addingTimeInterval(300_000_000),
            pending: true, inPassport: "Z0000000",
            details: [VaultDetail("Expires", .date(day.addingTimeInterval(300_000_000))),
                      VaultDetail("Issued by", .text("United States")),
                      VaultDetail("Book", .number("B000000"))],
            sources: [VaultSource(path: "Immigration/Passport/Pat/Passport 2030.pdf", role: "Passport photo page", rank: 50),
                      VaultSource(path: "Immigration/Copies/Passport.pdf", role: "Copy", rank: 10)])
        var passport = VaultEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                  title: "Passport", value: "Z0000001", savedFrom: "Immigration/Passport/Pat/Passport 2030.pdf",
                                  addedAt: day, facts: facts)
        passport.assignment = .household
        passport.pin = .older
        passport.geo = .india

        var plan = VaultEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                              title: "Health plan member ID", value: "XX000000000", addedAt: day, category: .health)
        plan.assignment = .person("sam")
        plan.card = .builtIn(.utilities)

        // `older` and a bare `kind`, as a build before pins and categories stored them, read as
        // every v1 file is (``VaultLegacyFormat/Entry``).
        let legacy = try JSONDecoder.vault.decode(VaultLegacyFormat.Entry.self, from: Data("""
            {"addedAt":"2027-01-15T08:00:00Z","id":"00000000-0000-0000-0000-000000000004","kind":"identity",\
            "note":"","older":true,"title":"Passport (old)","updatedAt":"2027-01-15T08:00:00Z","value":"Z0000002"}
            """.utf8)).entry
        return [loan, passport, plan, legacy]
    }

    static func formatReading() throws -> VaultReadingState {
        let entries = try formatEntries()
        let source = VaultSource(path: "Health/Plan/Card.pdf", role: "Member card", rank: 30)
        let find = VaultFind(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                             title: "Health plan member ID", value: "XX000000001", note: "Pat",
                             facts: VaultReadFacts(category: .health, holder: "Pat", details: [VaultDetail("Group", .text("G-1"))],
                                                   sources: [source]),
                             pin: .current, assignment: .person("pat"), geo: .us, card: .custom("kind-1"))
        return VaultReadingState(
            version: 13, generation: 2, finds: [find], read: ["Health/Plan/Card.pdf": "1024 1800000000"],
            mentions: ["Z0000001": [source]], copies: ["XX000000001": ["Health/Plan/Card.pdf": find]],
            choices: ["Z0000002": VaultChoice(id: entries[3].id, pin: .older, assignment: .household, geo: .anywhere,
                                              card: .builtIn(.passport))],
            needsReadAgain: true, lessons: ["Health/Plan": .custom("kind-1")])
    }

    /// Writes the format files into the source tree. Run once per format change, on purpose:
    /// `VAULT_WRITE_FORMAT_FILES=1 swift test --filter VaultFormatTests`, then commit the files
    /// under a new number beside the old ones, which stay.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAULT_WRITE_FORMAT_FILES"] != nil))
    func writeFormatFiles() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only files not there yet: a committed one is what an older build wrote, and making it
        // again with this build would test nothing.
        func write(_ name: String, _ sealed: () throws -> Data) throws {
            let url = folder.appendingPathComponent(name + ".sealed")
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try sealed().write(to: url, options: .withoutOverwriting)
        }
        try write("vault-format-1") { try VaultFile.seal(Self.formatEntries(), with: Self.key) }
        try write("vault-reading-format-1") {
            try VaultFile.seal(Self.formatReading(), marker: VaultFile.readingMarker, with: Self.key)
        }
        try write("vault-format-2") { try VaultFile.seal(Self.formatEntries2(), with: Self.key) }
        try write("vault-reading-format-2") {
            try VaultFile.seal(Self.formatReading2(), marker: VaultFile.readingMarker, with: Self.key)
        }
        try write("vault-format-3") { try VaultFile.seal(Self.formatEntries3(), with: Self.key) }
        try write("vault-format-4") { try VaultFile.seal(Self.formatEntries4(), with: Self.key) }
        try write("vault-format-5") { try VaultFile.seal(Self.formatEntries5(), with: Self.key) }
        try write("vault-format-6") { try VaultFile.seal(Self.formatEntries6(), with: Self.key) }
        try write("vault-backup-format-1") {
            try VaultBackupFile.seal(Self.formatBackup(), passphrase: Self.backupPassphrase,
                                     rounds: VaultBackupFile.leastRounds, salt: Self.backupSalt)
        }
        try write("vault-activity-format-1") {
            try VaultFile.sealPlain(Self.formatActivity(), marker: VaultActivityStore.marker, with: Self.key)
        }
        try write("vault-document-format-1") {
            try VaultFile.sealPlain(VaultFile.jsonEncoder().encode(Self.formatDocument()), marker: VaultDocument.marker, with: Self.key)
        }
        try write("vault-cache-format-1") {
            try VaultFile.sealPlain(VaultFile.jsonEncoder().encode(Self.formatCache()), marker: VaultCache.marker, with: Self.key)
        }
    }

    @Test func theFirstVaultFormatStillOpensAndMigrates() throws {
        let sealed = try Self.fixture("vault-format-1")
        let plain = try VaultFile.openPlain(sealed, marker: VaultFile.marker, with: Self.key)
        let records = try VaultFile.openRecords(sealed, with: Self.key)

        #expect(records.newer.isEmpty, "a record this build wrote reads as a later build's")
        #expect(records.entries == (try Self.formatEntries()))
        // While the migration is off, a v1 Vault still saves: what was opened seals back the same.
        let resealed = try VaultFile.seal(records, with: Self.key)
        #expect(try VaultFile.openPlain(resealed, marker: VaultFile.marker, with: Self.key) == plain,
                "sealing what was opened changed the stored JSON")

        // What the oldest shape means: an old pin from `older`, the card from its kind and title.
        let legacy = try #require(records.entries.last)
        #expect(legacy.pin == .older)
        #expect(legacy.category == .passport)
        #expect(records.entries[1].assignment == .household)
        #expect(records.entries[1].facts?.details.count == 3)
        #expect(records.entries[0].card == .custom("kind-1"))

        // Migrated, the document holds what each meant, and keeps it.
        let entries = try Self.migrated("vault-format-1").entries()
        #expect(entries == records.entries)
        #expect(entries[3].pin == .older && entries[3].category == .passport)
        #expect(entries[1].assignment == .household && entries[1].facts?.details.count == 3)
        #expect(entries[0].card == .custom("kind-1"))
    }

    @Test func theFirstReadingFormatStillOpensAndMigrates() throws {
        let sealed = try Self.fixture("vault-reading-format-1")
        let state = try VaultFile.open(VaultReadingState.self, sealed, marker: VaultFile.readingMarker, with: Self.key)
        #expect(state == (try Self.formatReading()))
        // It holds no `names`, which every later build writes.
        let first = try #require(JSONSerialization.jsonObject(
            with: VaultFile.openPlain(sealed, marker: VaultFile.readingMarker, with: Self.key)) as? [String: Any])
        #expect(first["names"] == nil)

        let document = try Self.migrated("vault-format-1", reading: "vault-reading-format-1")
        #expect(try document.finds() == state.finds)
        #expect(document.names.isEmpty && document.lessons == state.lessons && document.choices == state.choices)
        #expect(document.reading == .init(readerVersion: 13, needsReadAgain: true, staleSources: []))
    }

    /// Format 2 (2026-11-21): what Read from This Copy, name corrections, name roles and Refresh
    /// added, every one set.
    static func formatEntries2() throws -> [VaultEntry] {
        var entries = try formatEntries()
        entries[1].chosenSource = "Immigration/Copies/Passport.pdf"
        entries[1].facts?.spokenBy = "Immigration/Passport/Pat/Passport 2030.pdf"
        return entries
    }

    /// The third: a saved ID corrected by hand, with what its card reads for it (``VaultReadAs``).
    static func formatEntries3() throws -> [VaultEntry] {
        var entries = try formatEntries2()
        entries[1].readAs = [VaultReadAs(contents: "2048-" + String(repeating: "ab", count: 32), reads: "Z0000007"),
                             VaultReadAs(contents: "4096-" + String(repeating: "cd", count: 32), reads: "Z000000I")]
        return entries
    }

    /// The fourth: a saved ID with files taken off it (Not for This ID).
    static func formatEntries4() throws -> [VaultEntry] {
        var entries = try formatEntries3()
        entries[2].notOn = ["1024-" + String(repeating: "ef", count: 32)]
        return entries
    }

    /// The fifth: fields added by hand, one hidden like an ID.
    static func formatEntries5() throws -> [VaultEntry] {
        var entries = try formatEntries4()
        entries[1].fields = [VaultDetail("RxBIN", .text("610502")), VaultDetail("Payer ID", .number("60054"))]
        return entries
    }

    static func formatEntries6() throws -> [VaultEntry] {
        var entries = try formatEntries5()
        entries[1].notFields = ["111111111", "9416925"]
        return entries
    }

    static func formatReading2() throws -> VaultReadingState {
        var state = try formatReading()
        state.version = 17
        state.finds[0].chosenSource = "Health/Plan/Card.pdf"
        state.staleSources = ["Health/Plan/Old card.pdf"]
        state.notFound = ["Health/Plan/Gone.pdf"]
        state.needsDiscover = true
        state.lastRefreshed = day
        state.lastDiscovered = day.addingTimeInterval(-86_400)
        state.names = ["PATEXAMPIE": "Pat Example"]
        state.nameRoles = ["pat": VaultNameRoles(legal: "Pat Example", goesBy: "Pat", kept: ["P. Example"])]
        return state
    }

    /// A passphrase backup at the least work a file may ask for, with a fixed salt: the one
    /// format that must open in a later build on another Mac.
    static let backupPassphrase = "correct horse battery"
    static let backupSalt = Data((0..<16).map { UInt8(0xA0 + $0) })

    static func formatBackup() throws -> VaultBackupContents {
        VaultBackupContents(madeAt: day, entries: try formatEntries2())
    }

    /// The activity list, a kind a later build wrote among them.
    static func formatActivity() -> Data {
        Data(("[" + [
            #"{"at":"2027-01-15T08:00:00Z","id":"00000000-0000-0000-0000-000000000021","kind":"copied","what":"Passport","whose":"Pat"}"#,
            #"{"at":"2027-01-15T07:00:00Z","id":"00000000-0000-0000-0000-000000000022","kind":"printed","what":"Health plan member ID"}"#,
            #"{"at":"2027-01-15T06:00:00Z","id":"00000000-0000-0000-0000-000000000023","kind":"unlocked","what":""}"#,
        ].joined(separator: ",") + "]").utf8)
    }

    // MARK: The v7.2 document (VT6)

    /// The committed v1 Vault `vault` (and reading file `reading`) migrated: the migration checks
    /// the document against them itself (``VaultMigration/migrate(_:keyID:people:folders:at:)``
    /// throws when it does not give them back), and the document and cache seal and open again
    /// byte for byte.
    static func migrated(_ vault: String?, reading: String? = nil) throws -> VaultDocument {
        let vaultSealed = try vault.map { try fixture($0) }
        let readingSealed = try reading.map { try fixture($0) }
        let legacy = VaultMigration.Legacy(
            vaultPlain: try vaultSealed.map { try VaultFile.openPlain($0, marker: VaultFile.marker, with: key) },
            vaultDigest: vaultSealed.map(VaultMigration.digest),
            readingPlain: try readingSealed.map { try VaultFile.openPlain($0, marker: VaultFile.readingMarker, with: key) },
            readingDigest: readingSealed.map(VaultMigration.digest))
        let (document, cache, report) = try VaultMigration.migrate(legacy, keyID: VaultDocument.keyID(for: key), at: day)
        #expect(report.files == [vault, reading].compactMap { $0 }.count)
        #expect(document.migratedFrom == .init(vault: legacy.vaultDigest, reading: legacy.readingDigest, fingerprints: 0))

        let plain = try VaultFile.jsonEncoder().encode(document)
        let sealed = try VaultFile.sealPlain(plain, marker: VaultDocument.marker, with: key)
        let reopened = try VaultDocument.open(plain: VaultFile.openPlain(sealed, marker: VaultDocument.marker, with: key))
        #expect(!reopened.readOnly && reopened.unread == 0 && reopened.document == document)
        #expect(try VaultFile.jsonEncoder().encode(reopened.document) == plain, "the document did not seal back to the same JSON")

        let cachePlain = try VaultFile.jsonEncoder().encode(cache)
        let cacheAgain = try VaultFile.jsonDecoder().decode(VaultCache.self, from: cachePlain)
        #expect(cacheAgain == cache)
        #expect(try VaultFile.jsonEncoder().encode(cacheAgain) == cachePlain, "the cache did not seal back to the same JSON")
        return document
    }

    /// The document's first format (2026-11-25): the sixth Vault format's saved IDs and the second
    /// reading format's waiting one, with every part of the user's own data set, as a migration
    /// from both would leave it.
    static func formatDocument() throws -> VaultDocument {
        var state = try formatReading2()
        state.contacts = ["pat": VaultContacts(
            phones: [.init("+1 555 0100", label: "Mobile", added: day)],
            emails: [.init("pat@example.com", added: day.addingTimeInterval(60))],
            addresses: [.init(VaultAddress(street: "1 Example Way", unit: "Apt 2", city: "Springfield", state: "CA", zip: "90000"),
                              added: day)],
            notTheirs: ["9 Other Road|Springfield|CA|90001"], notTheirPhones: ["5550199"])]
        var document = VaultDocument(
            entries: try formatEntries6(), state: state,
            setAside: .init(generation: 2, keyID: VaultDocument.keyID(for: key), fingerprints: ["aa11", "ff00"]),
            kinds: [VaultCustomKind(id: "kind-1", name: "Memberships", group: "home")], savedAt: day,
            migratedFrom: .init(vault: String(repeating: "a", count: 64), reading: String(repeating: "b", count: 64),
                                fingerprints: 2))
        document.savedBy = "7.2 (702)"
        return document
    }

    /// The cache's first format (2026-11-25): what the second reading format can find again, with
    /// a copy's numbers and a changed copy set.
    static func formatCache() throws -> VaultCache {
        var state = try formatReading2()
        state.copyNumbers = ["Immigration/Copies/Packet.pdf": VaultCopyNumbers(stamp: "4096 1800000000", numbers: ["Z0000001"])]
        state.copiesChanged = true
        return VaultCache(state)
    }

    @Test func theFirstDocumentFormatOpensAsThisBuildsAndSealsBackToTheSameJSON() throws {
        let sealed = try Self.fixture("vault-document-format-1")
        let plain = try VaultFile.openPlain(sealed, marker: VaultDocument.marker, with: Self.key)
        let opened = try VaultDocument.open(plain: plain)
        #expect(!opened.readOnly && opened.unread == 0)
        #expect(opened.document == (try Self.formatDocument()))
        #expect(try VaultFile.jsonEncoder().encode(opened.document) == plain, "sealing what was opened changed the stored JSON")

        let document = opened.document
        #expect(document.format == 1 && document.savedBy == "7.2 (702)" && document.savedAt == Self.day)
        #expect(try document.entries() == Self.formatEntries6())
        #expect(try document.finds() == Self.formatReading2().finds)
        #expect(document.records.map(\.state) == [.saved, .saved, .saved, .saved, .toConfirm])
        #expect(document.setAside == .init(generation: 2, keyID: VaultDocument.keyID(for: Self.key), fingerprints: ["aa11", "ff00"]))
        #expect(document.contacts["pat"]?.addresses.first?.address.unit == "Apt 2")
        #expect(document.nameRoles["pat"]?.goesBy == "Pat")
        #expect(document.kinds.map(\.name) == ["Memberships"])
        // Under any other key, it does not open.
        #expect(throws: VaultError.wrongKeyOrDamaged) {
            try VaultFile.openPlain(sealed, marker: VaultDocument.marker, with: SymmetricKey(size: .bits256))
        }
    }

    @Test func theFirstCacheFormatOpensAndFitsItsDocument() throws {
        let sealed = try Self.fixture("vault-cache-format-1")
        let plain = try VaultFile.openPlain(sealed, marker: VaultCache.marker, with: Self.key)
        let cache = try VaultFile.jsonDecoder().decode(VaultCache.self, from: plain)
        #expect(cache == (try Self.formatCache()))
        #expect(try VaultFile.jsonEncoder().encode(cache) == plain, "sealing what was opened changed the stored JSON")

        // With its document, the reading state the v1 reading file held, the copy's numbers added.
        let document = try VaultDocument.open(plain: VaultFile.openPlain(
            Self.fixture("vault-document-format-1"), marker: VaultDocument.marker, with: Self.key)).document
        var expected = try Self.formatReading2()
        expected.copyNumbers = cache.copyNumbers
        expected.copiesChanged = true
        expected.contacts = document.contacts
        #expect(VaultMigration.normalized(try document.readingState(cache: cache)) == VaultMigration.normalized(expected))
    }

    @Test func theFirstDocumentAndCacheFormatsOpenThroughTheStore() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let folder = scratch.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.fixture("vault-document-format-1").write(to: scratch.fileURL)
        try Self.fixture("vault-cache-format-1").write(to: folder.appendingPathComponent("vault-cache.sealed"))
        let keychain = VaultFakeKeychain()
        keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, migrating: true, anotherCopyRunning: { false })
        #expect(store.fileFormat == .document && store.keepsDocument)
        let loaded = try #require(try store.loadDocument())
        #expect(loaded.document == (try Self.formatDocument()) && !loaded.readOnly)
        #expect(loaded.cache == (try Self.formatCache()))
        #expect(loaded.onDisk == .of(try Self.fixture("vault-document-format-1")))
        #expect(keychain.adds == 0)
    }

    @Test func theSecondFormatsStillOpenAndMigrate() throws {
        let vault = try Self.fixture("vault-format-2")
        let records = try VaultFile.openRecords(vault, with: Self.key)
        #expect(records.newer.isEmpty)
        #expect(records.entries == (try Self.formatEntries2()))
        #expect(try VaultFile.openPlain(VaultFile.seal(records, with: Self.key), marker: VaultFile.marker, with: Self.key)
                == VaultFile.openPlain(vault, marker: VaultFile.marker, with: Self.key))

        let reading = try Self.fixture("vault-reading-format-2")
        let state = try VaultFile.open(VaultReadingState.self, reading, marker: VaultFile.readingMarker, with: Self.key)
        #expect(state == (try Self.formatReading2()))

        let document = try Self.migrated("vault-format-2", reading: "vault-reading-format-2")
        #expect(try document.entries() == records.entries)
        #expect(try document.entries()[1].chosenSource == "Immigration/Copies/Passport.pdf")
        #expect(try document.entries()[1].facts?.spokenBy == "Immigration/Passport/Pat/Passport 2030.pdf")
        #expect(try document.finds() == state.finds)
        #expect(document.names == state.names && document.nameRoles == state.nameRoles)
        #expect(document.reading == .init(readerVersion: 17, needsReadAgain: true, staleSources: ["Health/Plan/Old card.pdf"]))
    }

    @Test func theThirdFormatStillOpensAndMigrates() throws {
        let vault = try Self.fixture("vault-format-3")
        let records = try VaultFile.openRecords(vault, with: Self.key)
        #expect(records.newer.isEmpty && records.laterFields.isEmpty)
        #expect(records.entries == (try Self.formatEntries3()))
        #expect(try VaultFile.openPlain(VaultFile.seal(records, with: Self.key), marker: VaultFile.marker, with: Self.key)
                == VaultFile.openPlain(vault, marker: VaultFile.marker, with: Self.key))

        let entries = try Self.migrated("vault-format-3", reading: "vault-reading-format-2").entries()
        #expect(entries == records.entries)
        #expect(entries[1].readAs?.map(\.reads) == ["Z0000007", "Z000000I"])
        #expect(entries[1].readAs?.first?.size == 2048)
    }

    @Test func theFourthFormatStillOpensAndMigrates() throws {
        let vault = try Self.fixture("vault-format-4")
        let records = try VaultFile.openRecords(vault, with: Self.key)
        #expect(records.newer.isEmpty && records.laterFields.isEmpty)
        #expect(records.entries == (try Self.formatEntries4()))
        #expect(try VaultFile.openPlain(VaultFile.seal(records, with: Self.key), marker: VaultFile.marker, with: Self.key)
                == VaultFile.openPlain(vault, marker: VaultFile.marker, with: Self.key))

        let entries = try Self.migrated("vault-format-4", reading: "vault-reading-format-2").entries()
        #expect(entries == records.entries)
        #expect(entries[2].notOn?.count == 1)
    }

    @Test func theSixthFormatStillOpensAndMigrates() throws {
        let vault = try Self.fixture("vault-format-6")
        let records = try VaultFile.openRecords(vault, with: Self.key)
        #expect(records.newer.isEmpty && records.laterFields.isEmpty)
        #expect(records.entries == (try Self.formatEntries6()))
        #expect(try VaultFile.openPlain(VaultFile.seal(records, with: Self.key), marker: VaultFile.marker, with: Self.key)
                == VaultFile.openPlain(vault, marker: VaultFile.marker, with: Self.key))

        let entries = try Self.migrated("vault-format-6", reading: "vault-reading-format-2").entries()
        #expect(entries == records.entries)
        #expect(entries[1].notFields == ["111111111", "9416925"])
    }

    @Test func theFifthFormatStillOpensAndMigrates() throws {
        let vault = try Self.fixture("vault-format-5")
        let records = try VaultFile.openRecords(vault, with: Self.key)
        #expect(records.newer.isEmpty && records.laterFields.isEmpty)
        #expect(records.entries == (try Self.formatEntries5()))
        #expect(try VaultFile.openPlain(VaultFile.seal(records, with: Self.key), marker: VaultFile.marker, with: Self.key)
                == VaultFile.openPlain(vault, marker: VaultFile.marker, with: Self.key))

        let entries = try Self.migrated("vault-format-5", reading: "vault-reading-format-2").entries()
        #expect(entries == records.entries)
        #expect(entries[1].fields?.map(\.label) == ["RxBIN", "Payer ID"])
    }

    @Test func theFirstBackupFormatOpensWithItsPassphraseOnly() throws {
        let sealed = try Self.fixture("vault-backup-format-1")
        let contents = try VaultBackupFile.open(sealed, passphrase: Self.backupPassphrase)
        #expect(contents == (try Self.formatBackup()))
        #expect(contents.entries.map(\.title) == ["Mortgage loan number", "Passport", "Health plan member ID", "Passport (old)"])
        #expect(contents.madeAt == Self.day)
        #expect(throws: VaultBackupError.wrongPassphrase) {
            try VaultBackupFile.open(sealed, passphrase: Self.backupPassphrase + "!")
        }
        // Sealed again with the same salt and work, it holds the same JSON (the nonce differs).
        let again = try VaultBackupFile.seal(contents, passphrase: Self.backupPassphrase,
                                             rounds: VaultBackupFile.leastRounds, salt: Self.backupSalt)
        let backupKey = try #require(VaultBackupFile.key(passphrase: Self.backupPassphrase, salt: Self.backupSalt,
                                                         rounds: VaultBackupFile.leastRounds))
        #expect(try VaultFile.openPlain(again, marker: Data(again.prefix(28)), with: backupKey)
                == VaultFile.openPlain(sealed, marker: Data(sealed.prefix(28)), with: backupKey),
                "what a backup writes changed")
        #expect(again.prefix(28) == sealed.prefix(28), "the header changed")
        #expect(try VaultBackupFile.open(again, passphrase: Self.backupPassphrase) == contents)
    }

    @Test func theFirstActivityFormatOpensAndKeepsALaterBuildsKind() throws {
        let sealed = try Self.fixture("vault-activity-format-1")
        let events = try VaultFile.open([VaultActivityEvent].self, sealed, marker: VaultActivityStore.marker, with: Self.key)
        #expect(events.map(\.kind) == [.copied, .other, .unlocked])
        #expect(events[0].line == "Copied Passport · Pat")
        let resealed = try VaultFile.seal(events, marker: VaultActivityStore.marker, with: Self.key)
        let plain = try VaultFile.openPlain(sealed, marker: VaultActivityStore.marker, with: Self.key)
        let again = try VaultFile.openPlain(resealed, marker: VaultActivityStore.marker, with: Self.key)
        #expect(String(decoding: again, as: UTF8.self) == String(decoding: plain, as: UTF8.self),
                "a later build's kind did not go back to disk as it came")
    }

    @Test func aBackupWithALaterBuildsRecordRestoresTheRest() throws {
        let entries = try Self.formatEntries2()
        var list = try entries.map { try JSONSerialization.jsonObject(with: JSONEncoder.vault.encode(VaultLegacyFormat.Entry($0))) }
        var later = try #require(list[0] as? [String: Any])
        later["category"] = "bankAccount"
        list.insert(later, at: 1)
        let plain = try JSONSerialization.data(withJSONObject: ["version": 1, "madeAt": "2027-01-15T08:00:00Z",
                                                                "entries": list], options: [.sortedKeys])
        let key = try #require(VaultBackupFile.key(passphrase: Self.backupPassphrase, salt: Self.backupSalt,
                                                   rounds: VaultBackupFile.leastRounds))
        var head = VaultBackupFile.marker
        withUnsafeBytes(of: VaultBackupFile.leastRounds.bigEndian) { head.append(contentsOf: $0) }
        head.append(Self.backupSalt)
        let sealed = try VaultFile.sealPlain(plain, marker: head, with: key)

        let contents = try VaultBackupFile.open(sealed, passphrase: Self.backupPassphrase)
        #expect(contents.entries == entries)
        #expect(contents.laterRecords == 1)
    }

    // MARK: Records from a later build (VT30)

    /// A sealed file holding `entries`, then one record per `changes`, each a copy of the first
    /// entry with those fields set as a later build might.
    static func sealed(_ entries: [VaultEntry], plus changes: [[String: Any]],
                       laterOnFirst: [String: Any] = [:]) throws -> Data {
        let encoder = JSONEncoder.vault
        var list = try entries.map { try JSONSerialization.jsonObject(with: encoder.encode(VaultLegacyFormat.Entry($0))) }
        if !laterOnFirst.isEmpty, var first = list.first as? [String: Any] {
            first.merge(laterOnFirst) { _, new in new }
            list[0] = first
        }
        for (index, change) in changes.enumerated() {
            var record = try #require(list.first as? [String: Any])
            record["id"] = UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000001%02d", index))!.uuidString
            record.merge(change) { _, new in new }
            list.append(record)
        }
        let plain = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys])
        return try VaultFile.sealPlain(plain, marker: VaultFile.marker, with: key)
    }

    @Test func aRecordFromALaterBuildIsKeptAsideNotAClosedVault() throws {
        let entries = Array(try Self.formatEntries().prefix(2))
        let sealed = try Self.sealed(entries, plus: [["category": "bankAccount"], ["geo": "uk"], ["pin": "archived"]])

        let records = try VaultFile.openRecords(sealed, with: Self.key)
        #expect(records.entries == entries)
        #expect(records.newer.count == 3)
        // The JSON as it was: a field this build has never heard of included.
        let first = try #require(JSONSerialization.jsonObject(with: records.newer[0]) as? [String: Any])
        #expect(first["category"] as? String == "bankAccount")

        let resealed = try VaultFile.openRecords(VaultFile.seal(records, with: Self.key), with: Self.key)
        #expect(resealed == records)
    }

    @Test func aFileThatIsNoListOfRecordsStillDoesNotOpen() throws {
        for plain in ["{\"entries\":[]}", "[1, 2", "\"text\""] {
            let sealed = try VaultFile.sealPlain(Data(plain.utf8), marker: VaultFile.marker, with: Self.key)
            #expect(throws: VaultError.unreadableFile) { try VaultFile.openRecords(sealed, with: Self.key) }
        }
    }

    @Test @MainActor func aSaveWritesALaterBuildsRecordsBackUntouchedAndThePanelCountsThem() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        rig.keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let entries = Array(try Self.formatEntries().prefix(2))
        try FileManager.default.createDirectory(at: rig.scratch.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // A later build's record, and a later build's field on a record this one reads: decoded
        // one by one, the field is still kept.
        try Self.sealed(entries, plus: [["category": "bankAccount", "extra": ["a": 1]]],
                        laterOnFirst: ["expiresReminder": ["days": 30]]).write(to: rig.scratch.fileURL)
        let before = try VaultFile.openRecords(Data(contentsOf: rig.scratch.fileURL), with: Self.key).newer

        let model = rig.model()
        await model.opened()
        #expect(model.contents == .loaded)
        #expect(model.newerRecords == 1)
        #expect(model.entries == entries)

        #expect(model.add(.init(title: "Library card", value: "LIB0000001", note: "", category: .other)) != nil)

        let after = try VaultFile.openRecords(Data(contentsOf: rig.scratch.fileURL), with: Self.key)
        #expect(after.entries.count == 3)
        #expect(after.newer == before, "a later build's record changed on its way back to disk")
        let later = try #require(after.laterFields[entries[0].id])
        #expect((try JSONSerialization.jsonObject(with: later) as? [String: [String: Int]]) == ["expiresReminder": ["days": 30]],
                "a later build's field on a readable record was dropped")
    }

    // MARK: Backups and the short-list guard (VT20)

    /// The same record each time for the same `n`, id included, as the model's list holds it.
    static func entry(_ n: Int) -> VaultEntry {
        VaultEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                   title: "Number \(n)", value: "NUM\(n)00000", addedAt: day)
    }

    final class Ticker: @unchecked Sendable {
        var now = VaultFormatTests.day
        func next() -> Date { now = now.addingTimeInterval(1); return now }
    }

    @Test func eachSaveKeepsTheFileItReplacesSealedAndOwnerOnly() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: ticker.next)

        try store.save([Self.entry(1)])
        #expect(store.backups.isEmpty, "the first save has nothing to keep")
        try store.save([Self.entry(1), Self.entry(2)])
        try store.save([Self.entry(1), Self.entry(2), Self.entry(3)])

        let key = SymmetricKey(data: try #require(keychain.itemData))
        let kept = try store.backups.map { try VaultFile.open(Data(contentsOf: $0), with: key).map(\.title) }
        #expect(kept == [["Number 1", "Number 2"], ["Number 1"]], "newest first")
        #expect(store.backups.map(\.lastPathComponent) == ["vault-backup-00000002-20270115T080002.000Z.sealed",
                                                           "vault-backup-00000001-20270115T080001.000Z.sealed"])
        for url in store.backups {
            #expect(url.deletingLastPathComponent() == scratch.fileURL.deletingLastPathComponent())
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            let bytes = try Data(contentsOf: url)
            #expect(bytes.range(of: Data("NUM100000".utf8)) == nil)
        }
    }

    /// The newest ten are kept, and of the rest only the day's first: the Vault as the day began.
    @Test func onlyTheNewestBackupsAreKept() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        // One clock reading for every save: the count, not the time, keeps their order.
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: { VaultFormatTests.day })
        for n in 1...(VaultStore.backupsKept + 3) {
            try store.save((1...n).map(Self.entry))
        }
        let key = SymmetricKey(data: try #require(keychain.itemData))
        let counts = try store.backups.map { try VaultFile.open(Data(contentsOf: $0), with: key).count }
        #expect(counts == Array((3...(VaultStore.backupsKept + 2)).reversed()) + [1])
    }

    /// Set It Aside and Start New takes the backups with the Vault: for a damaged file they may
    /// be the only readable copies, and the new Vault's saves would prune them. The activity list
    /// stays. Nothing it moved is in reach of the new Vault's saves.
    @Test func settingAsideTakesTheBackupsAndLeavesTheActivityList() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: ticker.next)
        try store.save([Self.entry(1)])
        try store.save([Self.entry(1), Self.entry(2)])
        try store.save([Self.entry(1), Self.entry(2), Self.entry(3)])
        VaultActivityStore.beside(store, keychain: keychain).append([VaultActivityEvent(at: Self.day, kind: .unlocked)], now: Self.day)
        let before = try store.backups.map { try Data(contentsOf: $0) }
        #expect(before.count == 2)

        #expect(store.setAside(at: Self.day))
        #expect(!store.hasFile)
        #expect(store.backups.isEmpty, "the backups stayed in the new Vault's rotation")
        #expect(FileManager.default.fileExists(atPath: store.activityURL.path), "the activity list moved with a Set Aside")
        for n in 1...(VaultStore.backupsKept + 2) { try store.save((1...n).map(Self.entry)) }
        let folder = scratch.fileURL.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("vault-backup-") && $0.contains(".set-aside-") }.sorted(by: >)
        #expect(try aside.map { try Data(contentsOf: folder.appendingPathComponent($0)) } == before)
    }

    /// A Keychain that will not keep the new key: what was set aside for it goes back.
    @Test func aNewKeyTheKeychainRefusesPutsTheLeftoversBack() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: ticker.next)
        try store.save([Self.entry(1)])
        try store.save([Self.entry(1), Self.entry(2)])
        try store.saveReading(VaultReadingState(names: ["AB": "A B"]))
        let folder = scratch.fileURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: scratch.fileURL)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        keychain.itemData = nil
        keychain.forcedAddStatus = errSecAuthFailed
        #expect(throws: VaultError.keyNotSaved(errSecAuthFailed)) { try store.save([Self.entry(3)]) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
    }

    /// Only names this store gives a backup are backups: anything else under the prefix is never
    /// taken for the newest, and never pruned.
    @Test func aFileThatOnlyLooksLikeABackupIsNeverPruned() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), clock: Ticker().next)
        try store.save([Self.entry(1)])
        let folder = scratch.fileURL.deletingLastPathComponent()
        let strays = ["vault-backup-notes.sealed", "vault-backup-20261122.sealed",
                      "vault-backup-00000001-20270115T080001.000Z 2.sealed"].map { folder.appendingPathComponent($0) }
        for stray in strays { try Data("mine".utf8).write(to: stray) }
        for n in 2...(VaultStore.backupsKept + 3) { try store.save((1...n).map(Self.entry)) }
        for stray in strays {
            #expect(FileManager.default.fileExists(atPath: stray.path), "\(stray.lastPathComponent) was pruned")
            #expect(!store.backups.contains(stray))
        }
    }

    /// A link whose file is gone is replaced by the Vault's file, as a whole-file write always did.
    @Test func aDanglingLinkIsReplaced() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        try FileManager.default.createDirectory(at: scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: scratch.fileURL.path,
                                                   withDestinationPath: scratch.directory.appendingPathComponent("gone/vault.sealed").path)
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain())
        try store.save([Self.entry(1)])
        #expect(try store.load() == [Self.entry(1)])
    }

    /// An activity list that does not open is set aside, never sealed over by the next event.
    @Test func anActivityListThatDoesNotOpenIsSetAsideNotWrittenOver() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try store.save([Self.entry(1)])
        let damaged = Data("SCVACTV1 not a sealed box".utf8)
        try damaged.write(to: store.activityURL)
        let activity = VaultActivityStore.beside(store, keychain: keychain)
        activity.append([VaultActivityEvent(at: Self.day, kind: .unlocked)], now: Self.day)
        #expect(activity.load().map(\.kind) == [.unlocked])
        let folder = scratch.fileURL.deletingLastPathComponent()
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first { $0.hasPrefix("vault-activity.sealed.unreadable-") })
        #expect(try Data(contentsOf: folder.appendingPathComponent(aside)) == damaged)
    }

    /// Opening the panel makes no key: a reading file on a Mac with none is set aside, and nothing
    /// is sealed until a save makes one.
    @Test @MainActor func openingThePanelMakesNoKey() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        try FileManager.default.createDirectory(at: rig.store.readingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("SCVREAD1 a reading file with no key".utf8).write(to: rig.store.readingURL)
        let model = rig.model()
        await model.opened()
        #expect(rig.keychain.itemData == nil, "opening the panel made a key")
        let folder = rig.store.readingURL.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .contains { $0.hasPrefix("vault-reading.sealed.unreadable-") })
    }

    @Test func aSaveThatWouldDropSeveralRecordsIsRefusedAndKeepsTheFile() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain())
        let three = [Self.entry(1), Self.entry(2), Self.entry(3)]
        try store.save(three)
        let sealed = try Data(contentsOf: scratch.fileURL)
        let backups = store.backups

        #expect(throws: VaultError.wouldDrop(2)) { try store.save([Self.entry(1)]) }
        #expect(throws: VaultError.wouldDrop(3)) { try store.save([]) }
        #expect(try Data(contentsOf: scratch.fileURL) == sealed)
        #expect(store.backups == backups, "a refused save made a backup")

        // One at a time, as Remove does.
        try store.save([three[0], three[2]])
        try store.save([three[0]])
        try store.save([])
        #expect(try store.load().isEmpty)
    }

    /// The guard counts IDs taken away, not how much shorter the list is: two dropped while two
    /// are added is refused; one swapped for another is not; and one ID two records share (Add
    /// Missing made them until 5e33b3c47) goes as one.
    @Test func theShortListGuardCountsIDsRemoved() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain())
        try store.save([Self.entry(1), Self.entry(2), Self.entry(3)])
        #expect(throws: VaultError.wouldDrop(2)) { try store.save([Self.entry(1), Self.entry(4), Self.entry(5)]) }
        try store.save([Self.entry(1), Self.entry(2), Self.entry(4)])

        var twin = Self.entry(9)
        twin.title = "Number 9, again"
        try store.save([Self.entry(1), Self.entry(2), Self.entry(4), Self.entry(9), twin])
        try store.save([Self.entry(1), Self.entry(2), Self.entry(4)])   // removing 9 removes both
        #expect(try store.load() == [Self.entry(1), Self.entry(2), Self.entry(4)])
    }

    /// Backups are ordered by a count that only grows, not by the clock: one made after the
    /// clock was put back is still the newest, and pruning keeps it.
    @Test func aClockPutBackStillKeepsTheNewestBackup() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let clock = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: clock.next)
        for n in 1...(VaultStore.backupsKept + 1) { try store.save((1...n).map(Self.entry)) }
        clock.now = Self.day.addingTimeInterval(-86_400 * 365)   // a year back
        let before = try Data(contentsOf: scratch.fileURL)
        try store.save((1...(VaultStore.backupsKept + 2)).map(Self.entry))
        let newest = try #require(store.backups.first)
        #expect(try Data(contentsOf: newest) == before, "the backup just made was pruned or sorted last")
        // The newest ten, and the first of the day the others were made: no backup is lost to the clock.
        #expect(store.backups.count == VaultStore.backupsKept + 1)
    }

    /// Backups named before counts (`vault-backup-<time>-NNN.sealed`, on the owner's disk from
    /// deb831324) sort as the oldest, and are pruned first, never taken for the newest.
    @Test func backupsNamedBeforeCountsAreTheOldest() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), clock: ticker.next)
        try store.save([Self.entry(1)])
        let folder = scratch.fileURL.deletingLastPathComponent()
        let old = ["vault-backup-20261122T023916.339Z-001.sealed", "vault-backup-20261122T023944.646Z-001.sealed"]
        for name in old { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        try store.save([Self.entry(1), Self.entry(2)])
        #expect(store.backups.map(\.lastPathComponent).first == "vault-backup-00000001-20270115T080001.000Z.sealed")
        #expect(Array(store.backups.map(\.lastPathComponent).suffix(2)) == old.reversed())
        for n in 3...(VaultStore.backupsKept + 1) { try store.save((1...n).map(Self.entry)) }
        // Pruned first; the earlier stays only as the first of its day.
        #expect(store.backups.map(\.lastPathComponent).last == old[0])
        #expect(!store.backups.contains { $0.lastPathComponent == old[1] }, "the oldest were not pruned first")
        #expect(store.backups.count == VaultStore.backupsKept + 1)
    }

    static func days(_ store: VaultStore) -> [Date] {
        store.backups.compactMap { VaultStore.backupTime($0.lastPathComponent) }.map(Calendar.current.startOfDay(for:))
    }

    /// One busy day of saves keeps its newest ten and the Vault as the day began, and each day
    /// before it keeps its own first: the busy day cannot push every older copy out (owner,
    /// 2026-11-23).
    @Test func aBusyDayKeepsTheFirstOfEachDay() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), clock: ticker.next)
        for d in 0..<4 {
            ticker.now = Self.day.addingTimeInterval(Double(d) * 86_400)
            try store.save((1...(d + 1)).map(Self.entry))
        }
        let lastOfDay3 = try Data(contentsOf: scratch.fileURL)   // replaced by day 4's first save
        ticker.now = Self.day.addingTimeInterval(4 * 86_400)
        for n in 5...25 { try store.save((1...n).map(Self.entry)) }
        #expect(store.backups.count == VaultStore.backupsKept + 4)
        #expect(Set(Self.days(store)).count == 4, "days 1 to 3 each keep one, day 4 its first and its newest ten")
        #expect(try store.backups.contains { try Data(contentsOf: $0) == lastOfDay3 })
    }

    /// A day's backup is kept for ``VaultStore/dailyBackupDays`` days, today's included, then goes.
    @Test func aDailyBackupGoesAfterThirtyDays() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), clock: ticker.next)
        for d in 0..<40 {
            ticker.now = Self.day.addingTimeInterval(Double(d) * 86_400)
            try store.save((1...(d + 1)).map(Self.entry))
        }
        #expect(store.backups.count == VaultStore.dailyBackupDays)
        let calendar = Calendar.current
        let oldest = try #require(Self.days(store).min())
        #expect(oldest == calendar.startOfDay(for: Self.day.addingTimeInterval(10 * 86_400)))

        // The clock put back ten days: the new backup's day is one of the thirty, and none goes.
        ticker.now = Self.day.addingTimeInterval(29 * 86_400)
        try store.save((1...41).map(Self.entry))
        #expect(store.backups.count == VaultStore.dailyBackupDays + 1)
    }

    /// A clock set years ahead for a while, then put right: the day it dated is one of the thirty
    /// until thirty days of saves come after it, then goes; never kept for years.
    @Test func aBackupDatedYearsAheadGoesAfterThirtyDaysOfSaves() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), clock: ticker.next)
        try store.save([Self.entry(1)])
        ticker.now = Self.day.addingTimeInterval(3 * 365 * 86_400)
        try store.save([Self.entry(1), Self.entry(2)])                 // a backup dated years ahead
        try store.save((1...3).map(Self.entry))                        // its day, now a backup too
        let years = Calendar.current.startOfDay(for: Self.day.addingTimeInterval(3 * 365 * 86_400))
        for d in 1...VaultStore.dailyBackupDays {
            ticker.now = Self.day.addingTimeInterval(Double(d) * 86_400)
            try store.save((1...(d + 3)).map(Self.entry))
            if d == VaultStore.dailyBackupDays - 1 { #expect(Self.days(store).contains(years), "gone before thirty days of saves") }
        }
        #expect(!Self.days(store).contains(years))
    }

    /// A clock reset to years back (a dead battery) for one save costs no backup: the days kept
    /// are the newest backups' days, not a window around a wrong today.
    @Test func aClockResetForOneSaveKeepsEveryDailyBackup() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), clock: ticker.next)
        for d in 0..<20 {
            ticker.now = Self.day.addingTimeInterval(Double(d) * 86_400)
            try store.save((1...(d + 1)).map(Self.entry))
        }
        #expect(store.backups.count == 19)
        ticker.now = Date(timeIntervalSince1970: 1_000_000_000)          // 2001
        try store.save((1...21).map(Self.entry))
        #expect(store.backups.count == 20)
    }

    /// A backup's time, read back from both names it has had.
    @Test func aBackupsTimeIsReadFromItsName() {
        let time = VaultStore.backupTime("vault-backup-00000012-20261121T174512.345Z.sealed")
        #expect(abs((time?.timeIntervalSince1970 ?? 0) - 1_795_283_112.345) < 0.001)
        #expect(VaultStore.backupTime("vault-backup-20261122T023916.339Z-001.sealed") != nil)
        #expect(VaultStore.backupTime("vault-backup-00000012-garbage.sealed") == nil)
    }

    /// A disk that refuses to put the Vault's own file in place, and nothing else.
    final class RefusesTheVaultFile: FileManager, @unchecked Sendable {
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if dstURL.lastPathComponent == "vault.sealed" { throw CocoaError(.fileWriteNoPermission) }
            try super.moveItem(at: srcURL, to: dstURL)
        }
        override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?,
                                  options: FileManager.ItemReplacementOptions = [],
                                  resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            if originalItemURL.lastPathComponent == "vault.sealed" { throw CocoaError(.fileWriteNoPermission) }
            try super.replaceItem(at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName,
                                  options: options, resultingItemURL: resultingItemURL)
        }
    }

    /// Replace on a Mac whose key was lost, refused by the disk: the key made for it goes again,
    /// so the Mac still says the key is missing, not that its file came from another Mac.
    @Test func aKeyMadeForASaveThatFailedGoesAgain() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let first = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try first.save([Self.entry(1)])
        try first.save([Self.entry(1), Self.entry(2)])                 // a backup, set aside for the new key, then back
        try first.saveReading(VaultReadingState())
        let sealed = try Data(contentsOf: scratch.fileURL)
        let reading = try Data(contentsOf: first.readingURL)
        let backups = first.backups.map(\.lastPathComponent)
        #expect(backups.count == 1)
        keychain.itemData = nil                                          // the key is lost
        let refusing = VaultStore(fileURL: scratch.fileURL, keychain: keychain, fileManager: RefusesTheVaultFile())
        let moved = try #require(refusing.moveAsideForReplace(at: Self.day))
        #expect(throws: VaultError.notWritten) { try refusing.save([Self.entry(2)]) }
        #expect(keychain.itemData == nil, "a new key was left beside the old file")
        // Put back as Restore does, by a disk that allows it this time.
        VaultStore(fileURL: scratch.fileURL, keychain: keychain).putBack(moved)
        #expect(try Data(contentsOf: scratch.fileURL) == sealed)
        #expect(try Data(contentsOf: first.readingURL) == reading, "what was set aside for the new key stayed aside")
        #expect(first.backups.map(\.lastPathComponent) == backups, "the backups set aside for the new key stayed aside")
        #expect(throws: VaultError.keyMissing) { try VaultStore(fileURL: scratch.fileURL, keychain: keychain).load() }
    }

    /// A save that keeps failing keeps one copy of the file it could not replace, and prunes
    /// nothing: ten failed tries must not rotate ten real saves away.
    @Test func aSaveThatKeepsFailingRotatesNoBackupsAway() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: ticker.next)
        for n in 1...(VaultStore.backupsKept + 1) { try store.save((1...n).map(Self.entry)) }
        let before = try store.backups.map { try Data(contentsOf: $0) }

        let refusing = VaultStore(fileURL: scratch.fileURL, keychain: keychain, fileManager: RefusesTheVaultFile(),
                                  clock: ticker.next)
        for _ in 1...(VaultStore.backupsKept + 2) {
            #expect(throws: VaultError.notWritten) { try refusing.save((1...20).map(Self.entry)) }
        }
        let after = try store.backups.map { try Data(contentsOf: $0) }
        #expect(after.count == before.count + 1, "one copy of the file it could not replace, not one per try")
        #expect(Array(after.dropFirst()) == before, "older backups were pruned by saves that failed")
    }

    /// Owner-only before it is put in place, not after: a disk that checks as the file is swapped
    /// in sees 0600 every time.
    final class ChecksModeAtTheSwap: FileManager, @unchecked Sendable {
        nonisolated(unsafe) var modes: [Int] = []
        /// Ignores every chmod, as a volume that keeps no modes would.
        nonisolated(unsafe) var ignoresModes = false
        override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
            if !ignoresModes { try super.setAttributes(attributes, ofItemAtPath: path) }
        }
        private func note(_ url: URL) {
            modes.append((try? attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1)
        }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if dstURL.pathExtension == "sealed" { note(srcURL) }
            try super.moveItem(at: srcURL, to: dstURL)
        }
        override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?,
                                  options: FileManager.ItemReplacementOptions = [],
                                  resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            note(newItemURL)
            try super.replaceItem(at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName,
                                  options: options, resultingItemURL: resultingItemURL)
        }
    }

    @Test func aSealedFileIsOwnerOnlyBeforeItIsPutInPlace() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let disk = ChecksModeAtTheSwap()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), fileManager: disk)
        try store.save([Self.entry(1)])
        try store.save([Self.entry(1), Self.entry(2)])          // a replace, and a backup
        try store.saveReading(VaultReadingState())
        #expect(disk.modes.count >= 4, "\(disk.modes)")
        #expect(disk.modes.allSatisfy { $0 == 0o600 }, "\(disk.modes.map { String($0, radix: 8) })")
    }

    /// Created owner-only, not made so after: with every chmod ignored, the file swapped in is
    /// still 0600 (it was `Data.write`, at the umask's mode, then a chmod).
    @Test func aSealedFileIsCreatedOwnerOnly() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let disk = ChecksModeAtTheSwap()
        disk.ignoresModes = true
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), fileManager: disk)
        try store.save([Self.entry(1)])
        try store.save([Self.entry(1), Self.entry(2)])
        #expect(disk.modes.count >= 3, "\(disk.modes)")
        #expect(disk.modes.allSatisfy { $0 == 0o600 }, "\(disk.modes.map { String($0, radix: 8) })")
    }

    /// A field a later build added to a record this build reads goes back on disk with it, so a
    /// save here never drops it; a key this build reads (an old one included) is not kept twice.
    @Test func aLaterBuildsFieldOnARecordSurvivesASave() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        let entries = Array(try Self.formatEntries())
        var list = try entries.map { try #require(JSONSerialization.jsonObject(with: JSONEncoder.vault.encode(VaultLegacyFormat.Entry($0))) as? [String: Any]) }
        list[1]["expiresReminder"] = ["days": 30]
        try FileManager.default.createDirectory(at: scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
                                marker: VaultFile.marker, with: Self.key).write(to: scratch.fileURL)

        let records = try store.loadRecords()
        #expect(records.entries == entries)
        #expect(records.laterFields.keys.sorted() == [entries[1].id], "an old key (older, kind) was taken for a later one")
        var changed = records.entries
        changed[1].note = "renewed"
        try store.save(changed)
        let plain = try VaultFile.openPlain(Data(contentsOf: scratch.fileURL), marker: VaultFile.marker, with: Self.key)
        let saved = try #require(JSONSerialization.jsonObject(with: plain) as? [[String: Any]])
        #expect((saved[1]["expiresReminder"] as? [String: Int]) == ["days": 30], "the later build's field was dropped")
        #expect(saved[1]["note"] as? String == "renewed")
        #expect(saved[0]["expiresReminder"] == nil)
        #expect(try store.load() == changed)
    }

    /// A later field nested inside a record (in its facts) is kept while the record is unchanged;
    /// an edited one keeps its top-level later fields.
    @Test func aLaterBuildsNestedFieldSurvivesASaveOfOtherRecords() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        let entries = Array(try Self.formatEntries())
        var list = try entries.map { try #require(JSONSerialization.jsonObject(with: JSONEncoder.vault.encode(VaultLegacyFormat.Entry($0))) as? [String: Any]) }
        var facts = try #require(list[1]["facts"] as? [String: Any])
        facts["machineReadable"] = "P<USA"
        list[1]["facts"] = facts
        try FileManager.default.createDirectory(at: scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]),
                                marker: VaultFile.marker, with: Self.key).write(to: scratch.fileURL)

        var changed = try store.load()
        changed[0].note = "renewed"   // another record edited
        try store.save(changed)
        let saved = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(
            Data(contentsOf: scratch.fileURL), marker: VaultFile.marker, with: Self.key)) as? [[String: Any]])
        #expect((saved[1]["facts"] as? [String: Any])?["machineReadable"] as? String == "P<USA",
                "a later field inside an unchanged record was dropped")
        #expect(try store.load() == changed)
    }

    /// The user's own fields a later build stored in a shape this one cannot read come back as
    /// stored, not sealed empty, until set here.
    @Test func namesThisBuildCannotReadAreKeptAsStored() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try store.saveReading(VaultReadingState())
        let key = SymmetricKey(data: try #require(keychain.itemData))
        var object = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(
            Data(contentsOf: store.readingURL), marker: VaultFile.readingMarker, with: key)) as? [String: Any])
        object["names"] = ["DLVITGIRISH": ["name": "Divit Girish", "since": 2027]]   // a later shape
        try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                                marker: VaultFile.readingMarker, with: key).write(to: store.readingURL)

        var state = try #require(store.loadReading())
        #expect(state.names.isEmpty)
        state.generation = 9
        try store.saveReading(state)
        let after = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(
            Data(contentsOf: store.readingURL), marker: VaultFile.readingMarker, with: key)) as? [String: Any])
        #expect((after["names"] as? [String: Any])?["DLVITGIRISH"] != nil, "the names were sealed empty")
        #expect(after["generation"] as? Int == 9)
        // One name corrected here keeps the rest a later build wrote.
        state = try #require(store.loadReading())
        state.names["ANNAERIKSSON"] = "Anna Eriksson"
        try store.saveReading(state)
        let both = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(
            Data(contentsOf: store.readingURL), marker: VaultFile.readingMarker, with: key)) as? [String: Any])
        #expect((both["names"] as? [String: Any])?.keys.sorted() == ["ANNAERIKSSON", "DLVITGIRISH"])
        // Opened again, the name set here reads; the later one is still carried.
        let reopened = try #require(store.loadReading())
        #expect(reopened.names["ANNAERIKSSON"] == "Anna Eriksson", "a name set here was lost beside a later one")
        try store.saveReading(reopened)
        let again = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(
            Data(contentsOf: store.readingURL), marker: VaultFile.readingMarker, with: key)) as? [String: Any])
        #expect((again["names"] as? [String: Any])?.keys.sorted() == ["ANNAERIKSSON", "DLVITGIRISH"])
    }

    /// A disk that will not give a file's bytes, though the file is there.
    final class WillNotRead: FileManager, @unchecked Sendable {
        let path: String
        init(_ url: URL) { path = url.standardizedFileURL.path }
        override func contents(atPath path: String) -> Data? {
            URL(fileURLWithPath: path).standardizedFileURL.path == self.path ? nil : super.contents(atPath: path)
        }
    }

    /// A reading file or activity list that is there but will not read is never written over.
    @Test func aFileThatIsThereButWillNotReadIsNeverWrittenOver() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try store.save([Self.entry(1)])
        try store.saveReading(VaultReadingState(names: ["AB": "A B"]))
        VaultActivityStore.beside(store, keychain: keychain).append([VaultActivityEvent(at: Self.day, kind: .unlocked)], now: Self.day)
        let reading = try Data(contentsOf: store.readingURL)
        let activity = try Data(contentsOf: store.activityURL)

        #expect(VaultStore(fileURL: scratch.fileURL, keychain: keychain, fileManager: WillNotRead(store.readingURL)).openReading() == .keyRefused,
                "a file the disk will not give now is held, not set aside")
        VaultActivityStore.beside(store, keychain: keychain, fileManager: WillNotRead(store.activityURL))
            .append([VaultActivityEvent(at: Self.day, kind: .copied, what: "Passport")], now: Self.day)
        #expect(try Data(contentsOf: store.readingURL) == reading)
        #expect(try Data(contentsOf: store.activityURL) == activity, "an activity list that would not read was sealed over")
    }

    /// The list keeps the order its entries were added in, newest first, whatever their times
    /// say: two in one second, or a clock put back, never swap places.
    @Test func theActivityListKeepsTheOrderItWasAddedIn() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try store.save([Self.entry(1)])
        let activity = VaultActivityStore.beside(store, keychain: keychain)
        activity.append([VaultActivityEvent(at: Self.day, kind: .copied, what: "First")], now: Self.day)
        activity.append([VaultActivityEvent(at: Self.day, kind: .copied, what: "Second")], now: Self.day)
        activity.append([VaultActivityEvent(at: Self.day.addingTimeInterval(-60), kind: .copied, what: "Third")], now: Self.day)
        #expect(activity.load().map(\.what) == ["Third", "Second", "First"])
    }

    /// One event a later build wrote that this build cannot read (a changed field) neither hides
    /// the list nor is lost from it.
    @Test func anActivityEventThisBuildCannotReadIsKeptAndHidesNothing() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try FileManager.default.createDirectory(at: scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plain = Data(("[" + [
            #"{"at":"2027-01-15T08:00:00Z","id":"00000000-0000-0000-0000-000000000031","kind":"copied","what":"Passport"}"#,
            #"{"at":"2027-01-15T07:00:00Z","id":"00000000-0000-0000-0000-000000000032","kind":"shown","what":{"title":"Visa"}}"#,
            #"{"at":"2026-06-01T07:00:00Z","id":"00000000-0000-0000-0000-000000000033","kind":"shown","what":{"title":"Old"}}"#,
            #"{"id":"00000000-0000-0000-0000-000000000034","kind":"shown","what":{"title":"Undated"}}"#,
        ].joined(separator: ",") + "]").utf8)
        try VaultFile.sealPlain(plain, marker: VaultActivityStore.marker, with: Self.key).write(to: store.activityURL)
        let activity = VaultActivityStore.beside(store, keychain: keychain)
        #expect(activity.load().map(\.kind) == [.copied], "one event this build cannot read hid the list")
        // A day on: within ninety days of both, past them for the one from June 2026.
        let now = Self.day.addingTimeInterval(86_400)
        activity.append([VaultActivityEvent(at: now, kind: .unlocked)], now: now)
        let after = String(decoding: try VaultFile.openPlain(Data(contentsOf: store.activityURL),
                                                             marker: VaultActivityStore.marker, with: Self.key), as: UTF8.self)
        #expect(after.contains(#""title":"Visa""#), "the later build's event was lost")
        #expect(!after.contains(#""title":"Old""#), "a later build's event was kept past ninety days")
        #expect(activity.load().map(\.kind) == [.unlocked, .copied], "newest first")
        // One with no date this build can read is kept in its place until the limit leaves it out.
        #expect(after.contains(#""title":"Undated""#))
        #expect(after.range(of: "Undated")!.lowerBound > after.range(of: "Visa")!.lowerBound, "the stored order changed")
    }

    /// The same for the reading file: a field a later build wrote there survives this build's seal.
    @Test @MainActor func aLaterBuildsFieldInTheReadingFileSurvivesASeal() async throws {
        let rig = try VaultModelTests.Rig(v1: true); defer { rig.cleanUp() }
        try rig.seed([Self.entry(1)])
        try rig.store.saveReading(VaultReadingState(names: ["AB": "A B"]))
        let key = SymmetricKey(data: try #require(rig.keychain.itemData))
        var object = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(
            Data(contentsOf: rig.store.readingURL), marker: VaultFile.readingMarker, with: key)) as? [String: Any])
        object["pinnedPeople"] = ["anna"]
        try VaultFile.sealPlain(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                                marker: VaultFile.readingMarker, with: key).write(to: rig.store.readingURL)

        let opened = try #require(rig.store.loadReading())
        #expect((try JSONSerialization.jsonObject(with: #require(opened.laterFields)) as? [String: Any])?.keys.sorted() == ["pinnedPeople"],
                "a key this build reads was taken for a later one")
        let model = rig.model()
        await model.opened()
        #expect(model.add(.init(title: "Library card", value: "LIB0000001", note: "", category: .other)) != nil)
        model.setRole(.alsoUsed, of: "Anna", for: "anna")   // any change to what was read: a seal
        let after = try #require(JSONSerialization.jsonObject(with: VaultFile.openPlain(
            Data(contentsOf: rig.store.readingURL), marker: VaultFile.readingMarker, with: key)) as? [String: Any])
        #expect(after["nameRoles"] != nil, "nothing was sealed")
        #expect(after["pinnedPeople"] as? [String] == ["anna"], "the later build's field was dropped")
    }

    /// With no key and no Vault file, a new key is made only after what the lost key sealed
    /// (backups, what was read, the activity list) is set aside: under the new key those would be
    /// pruned or written over.
    @Test func aNewKeyIsMadeOnlyAfterTheLostKeysFilesAreSetAside() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: ticker.next)
        try store.save([Self.entry(1)])
        try store.save([Self.entry(1), Self.entry(2)])
        try store.saveReading(VaultReadingState(names: ["AB": "A B"]))
        VaultActivityStore.beside(store, keychain: keychain).append([VaultActivityEvent(at: Self.day, kind: .unlocked)], now: Self.day)
        let folder = scratch.fileURL.deletingLastPathComponent()
        let heldNames = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "vault.sealed" }
        let held = try Dictionary(uniqueKeysWithValues: heldNames.map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) })
        try FileManager.default.removeItem(at: scratch.fileURL)   // the Vault's own file, gone by hand
        keychain.itemData = nil                                   // and its key

        for n in 1...(VaultStore.backupsKept + 1) { try store.save((1...n).map(Self.entry)) }
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".set-aside-") }
        #expect(aside.count == held.count, "a file the lost key sealed was pruned or written over")
        for name in aside {
            let original = String(name[..<name.range(of: ".set-aside-")!.lowerBound])
            #expect(try Data(contentsOf: folder.appendingPathComponent(name)) == held[original], "\(name) is not what \(original) held")
        }
    }

    /// An activity list alone, with no key and no Vault file, is set aside before a new key too.
    @Test func anActivityListALostKeySealedIsSetAsideToo() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try store.save([Self.entry(1)])
        VaultActivityStore.beside(store, keychain: keychain).append([VaultActivityEvent(at: Self.day, kind: .unlocked)], now: Self.day)
        let activity = try Data(contentsOf: store.activityURL)
        #expect(store.setAside(at: Self.day), "the Vault's own file, set aside by hand")
        keychain.itemData = nil
        try store.save([Self.entry(2)])
        let folder = scratch.fileURL.deletingLastPathComponent()
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .first { $0.hasPrefix("vault-activity.sealed.set-aside-") })
        #expect(try Data(contentsOf: folder.appendingPathComponent(aside)) == activity)
    }

    /// A volume with no replacement folder (a network share whose root is not the user's): the
    /// temporary file goes beside the file, never named with a dot, and is gone after.
    final class NoReplacementFolder: FileManager, @unchecked Sendable {
        override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                          appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
            if directory == .itemReplacementDirectory { throw CocoaError(.fileWriteVolumeReadOnly) }
            return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
        }
    }

    @Test func aVolumeWithNoReplacementFolderStillWritesWholeAndOwnerOnly() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), fileManager: NoReplacementFolder())
        try store.save([Self.entry(1)])
        try store.save([Self.entry(1), Self.entry(2)])
        #expect(try store.load() == [Self.entry(1), Self.entry(2)])
        let folder = scratch.fileURL.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(".") || $0.contains(".writing-") }, "\(names)")
        let mode = try FileManager.default.attributesOfItem(atPath: scratch.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    /// Set Aside uses the store's own disk.
    @Test func setAsideUsesTheStoresOwnDisk() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        try VaultStore(fileURL: scratch.fileURL, keychain: keychain).save([Self.entry(1)])
        let refusing = VaultStore(fileURL: scratch.fileURL, keychain: keychain, fileManager: NoMove(refusing: scratch.fileURL))
        #expect(!refusing.setAside(at: Self.day))
        #expect(FileManager.default.fileExists(atPath: scratch.fileURL.path))
    }

    /// A link to the Vault's file is written through: the file it names is replaced, and the link
    /// stays a link.
    @Test func aLinkToTheVaultsFileIsWrittenThrough() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let elsewhere = scratch.directory.appendingPathComponent("Elsewhere/vault.sealed")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: elsewhere, keychain: keychain)
        try store.save([Self.entry(1)])
        try FileManager.default.createSymbolicLink(at: scratch.fileURL, withDestinationURL: elsewhere)
        let linked = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try linked.save([Self.entry(1), Self.entry(2)])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scratch.fileURL.path) == elsewhere.path)
        #expect(try store.load() == [Self.entry(1), Self.entry(2)])
    }

    @Test func aFileThisMacCannotOpenIsNeverWrittenOverEvenWithTheKey() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain())
        try store.save([Self.entry(1)])
        var damaged = try Data(contentsOf: scratch.fileURL)
        damaged[damaged.count - 1] ^= 0x01
        try damaged.write(to: scratch.fileURL)

        #expect(throws: VaultError.wrongKeyOrDamaged) { try store.save([Self.entry(2)]) }
        #expect(try Data(contentsOf: scratch.fileURL) == damaged)
    }

    // MARK: The one writer (VT55)

    /// A disk that will not set permissions.
    final class NoOwnerOnly: FileManager, @unchecked Sendable {
        override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// A disk that will not put a written file in place.
    final class NoSwapIn: FileManager, @unchecked Sendable {
        override func moveItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    }

    @Test @MainActor func aDiskThatRefusesOwnerOnlyStillSavesAndSaysSo() async throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain(), fileManager: NoOwnerOnly())
        let log = LogCapture()
        try store.save([Self.entry(1)])
        #expect(try store.load() == [Self.entry(1)])
        #expect(await log.holds(.warning, containing: "vault.sealed could not be made owner-only"))
    }

    @Test func everySealedFileIsOwnerOnlyAndLeavesNothingBesideIt() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain)
        try store.save([Self.entry(1)])
        try store.save([Self.entry(1), Self.entry(2)])
        try store.saveReading(VaultReadingState())
        VaultActivityStore.beside(store, keychain: keychain)
            .append([VaultActivityEvent(at: Self.day, kind: .unlocked)], now: Self.day)
        let folder = scratch.fileURL.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names.count == 4, "\(names)")
        #expect(!names.contains { $0.hasPrefix(".") }, "a temporary file was left beside the Vault's")
        for name in names {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.posixPermissions] as? Int
            #expect(mode == 0o600, "\(name)")
        }
    }

    @Test @MainActor func anActivityListTheDiskRefusesIsLoggedThroughTheInjectedDisk() async throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        keychain.itemData = Self.key.withUnsafeBytes { Data($0) }
        let activity = VaultActivityStore.beside(VaultStore(fileURL: scratch.fileURL, keychain: keychain),
                                                 keychain: keychain, fileManager: NoSwapIn())
        let log = LogCapture()
        activity.append([VaultActivityEvent(at: Self.day, kind: .unlocked)], now: Self.day)
        #expect(!FileManager.default.fileExists(atPath: activity.fileURL.path))
        #expect(await log.holds(.warning, containing: "the activity list could not be sealed"))
    }

    // MARK: Files that do not open (VT24)

    @Test @MainActor func aVaultFileThatDoesNotOpenIsLoggedWithItsSizeAndMarkerOnly() async throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let store = VaultStore(fileURL: scratch.fileURL, keychain: VaultFakeKeychain())
        // A title and number no other suite uses: the capture sees every case running beside
        // this one, and a word like "Passport" is in their lines.
        try store.save([VaultEntry(title: "Kestrelwood pass", value: "Q7310462", addedAt: Self.day)])
        var damaged = try Data(contentsOf: scratch.fileURL)
        damaged[damaged.count - 1] ^= 0x01
        try damaged.write(to: scratch.fileURL)

        let log = LogCapture()
        #expect(throws: VaultError.wrongKeyOrDamaged) { try store.load() }
        let lines = await log.entries.map(\.messageBody)
        // The whole sentence, size included: a sibling case's damaged file logs the same words.
        #expect(lines.contains("Vault: the sealed file did not open (wrongKeyOrDamaged, \(damaged.count) bytes, begins SCVAULT1) — it is left as it is"))
        #expect(!lines.contains { $0.contains("Q7310462") || $0.contains("Kestrelwood") })
    }

    @Test func aSummaryNamesOnlyAVaultMarker() {
        #expect(VaultFile.summary(of: Data("SCVREAD1abc".utf8)) == "11 bytes, begins SCVREAD1")
        #expect(VaultFile.summary(of: Data("SCVAULT9xyz".utf8)) == "11 bytes, begins SCVAULT9")
        #expect(VaultFile.summary(of: Data("Q7310462 is my number".utf8)) == "21 bytes, no Vault marker")
        #expect(VaultFile.summary(of: Data()) == "0 bytes, no Vault marker")
    }

    /// A reading file that does not open is set aside, never written over, and the panel starts
    /// fresh as it always did: no banner, and the next Refresh or Read finds what was waiting.
    @Test @MainActor func aReadingFileThatDoesNotOpenIsSetAsideAndThePanelStartsFresh() async throws {
        let rig = try VaultModelTests.Rig(v1: true); defer { rig.cleanUp() }
        try rig.seed([Self.entry(1)])
        let reading = rig.store.readingURL
        try Data("SCVREAD1 not a sealed box".utf8).write(to: reading)

        let log = LogCapture()
        let model = rig.model()
        await model.opened()

        #expect(model.contents == .loaded)
        #expect(!model.needsReadAgain, "a banner says documents were updated, which they were not")
        let lines = await log.entries.map(\.messageBody)
        #expect(lines.contains("Vault: the reading file did not open (unreadableFile, 25 bytes, begins SCVREAD1)"))
        #expect(!lines.contains { $0.contains("not a sealed box") }, "the file's bytes reached the log")
        let folder = reading.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("vault-reading.sealed.unreadable-") }
        #expect(aside.count == 1, "the file that did not open was not kept")
        #expect(try Data(contentsOf: folder.appendingPathComponent(aside[0])) == Data("SCVREAD1 not a sealed box".utf8))

    }

    /// A disk that will not move files: a damaged reading file stays where it is.
    final class NoMove: FileManager, @unchecked Sendable {
        let refused: String
        init(refusing url: URL) { refused = url.standardizedFileURL.path }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if srcURL.standardizedFileURL.path == refused { throw CocoaError(.fileWriteNoPermission) }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    /// A damaged reading file that will not move aside is never sealed over: it may hold the
    /// owner's name corrections, roles and lessons (VT24).
    @Test @MainActor func aDamagedReadingFileThatWillNotMoveIsNeverWrittenOver() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.entry(1)])
        // Not the 25 bytes another case here logs: the capture sees every case running beside it.
        let damaged = Data("SCVREAD1 held, not a sealed box".utf8)
        try damaged.write(to: rig.store.readingURL)
        let store = VaultStore(fileURL: rig.scratch.fileURL, keychain: rig.keychain, fileManager: NoMove(refusing: rig.store.readingURL))
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        let model = VaultModel(store: store, authenticator: rig.auth, defaults: rig.defaults,
                               clock: { VaultFormatTests.day }, copyToPasteboard: { _ in })
        await model.opened()
        #expect(model.contents == .loaded)
        #expect(model.add(.init(title: "Library card", value: "LIB0000001", note: "", category: .other)) != nil)
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            "/Users/anna/Documents/Health/Dental/ID Cards/card.pdf": ["Member Name: ANNA", "Member ID: XZB123456789"],
        ]))
        #expect(try Data(contentsOf: rig.store.readingURL) == damaged, "sealed over")
    }

    /// A Keychain that will not give the key for a moment is not a fresh start: with no Vault
    /// file yet, the panel opens empty, and nothing it seals later may write over what was read.
    @Test @MainActor func aReadingFileTheKeychainWillNotOpenIsNotWrittenOver() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        try rig.store.saveReading(VaultReadingState(names: ["AB": "A B"]))
        let sealed = try Data(contentsOf: rig.store.readingURL)
        rig.keychain.forcedCopyStatus = errSecInteractionNotAllowed
        #expect(rig.store.openReading() == .keyRefused)
        let model = rig.model()
        await model.opened()
        rig.keychain.forcedCopyStatus = nil              // and gives it a moment later
        #expect(model.add(.init(title: "Library card", value: "LIB0000001", note: "", category: .other)) != nil)
        model.setRole(.alsoUsed, of: "Anna", for: "anna")
        #expect(try Data(contentsOf: rig.store.readingURL) == sealed, "an empty state was sealed over it")
    }

    /// While the reading file is held, Everywhere cannot be sealed, so the name typed is kept on
    /// the ID itself rather than lost at the next launch.
    @Test @MainActor func whileHeldAnEverywhereNameIsKeptOnTheID() async throws {
        let rig = try VaultModelTests.Rig(v1: true); defer { rig.cleanUp() }
        try rig.seed([Self.entry(1)])
        try Data("SCVREAD1 held, not a sealed box".utf8).write(to: rig.store.readingURL)
        let store = VaultStore(fileURL: rig.scratch.fileURL, keychain: rig.keychain, fileManager: NoMove(refusing: rig.store.readingURL), migrating: false)
        VaultReadFolders.add("/Users/anna/Documents", in: rig.defaults)
        let model = VaultModel(store: store, authenticator: rig.auth, defaults: rig.defaults,
                               clock: { VaultFormatTests.day }, copyToPasteboard: { _ in })
        await model.opened()
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: [
            "/Users/anna/Documents/Health/Dental/ID Cards/card.pdf": ["Delta Dental", "Member Name: DLVIT GIRISH", "Member ID: XZB123456789"],
        ]))
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        var draft = model.prepared(VaultModel.Draft(find))
        draft.holderName = "Divit Girish"
        draft.correctEverywhere = true
        let id = try #require(model.confirm(find.id, as: draft))

        let again = rig.model()
        await again.opened()
        #expect(again.entries.first { $0.id == id }?.holderName == "Divit Girish", "the typed name was lost")
    }

    /// With no key in the Keychain, a reading file is one this Mac cannot open, not a fresh
    /// start: set aside, never written over by the new key's first seal.
    @Test @MainActor func aReadingFileWithNoKeyIsSetAsideNotWrittenOver() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        try rig.store.saveReading(VaultReadingState(names: ["AB": "A B"]))
        let sealed = try Data(contentsOf: rig.store.readingURL)
        rig.keychain.itemData = nil   // the key is gone; there is no Vault file

        #expect(rig.store.openReading() == .damaged)
        #expect(rig.model().add(.init(title: "Library card", value: "LIB0000001", note: "", category: .other)) != nil)
        let folder = rig.store.readingURL.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("vault-reading.sealed.unreadable-") }
        #expect(aside.count == 1, "set aside by the load, as a file this Mac cannot open")
        #expect(try Data(contentsOf: folder.appendingPathComponent(aside[0])) == sealed)
    }
}

private extension JSONEncoder {
    static var vault: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var vault: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
