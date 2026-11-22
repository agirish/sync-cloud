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

    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "sealed",
                                                 subdirectory: "Fixtures/Vault"))
        return try Data(contentsOf: url)
    }

    /// Every field a record can store, set: a typed number, a read one, a household one on another
    /// kind's card, and one from a build before pins and categories.
    static func formatEntries() throws -> [VaultEntry] {
        var loan = VaultEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                              title: "Mortgage loan number", value: "0000-1111-22", personID: "pat",
                              note: "Home loan servicer", kind: .home, addedAt: day,
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
                                  title: "Passport", value: "Z0000001", addedAt: day, facts: facts)
        passport.assignment = .household
        passport.pin = .older
        passport.geo = .india

        var plan = VaultEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                              title: "Health plan member ID", value: "XX000000000", addedAt: day, category: .health)
        plan.assignment = .person("sam")
        plan.card = .builtIn(.utilities)

        // `older` and a bare `kind`, as a build before pins and categories stored them (VT3).
        let legacy = try JSONDecoder.vault.decode(VaultEntry.self, from: Data("""
            {"addedAt":"2027-01-15T08:00:00Z","id":"00000000-0000-0000-0000-000000000004","kind":"identity",\
            "note":"","older":true,"title":"Passport (old)","updatedAt":"2027-01-15T08:00:00Z","value":"Z0000002"}
            """.utf8))
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
        try write("vault-backup-format-1") {
            try VaultBackupFile.seal(Self.formatBackup(), passphrase: Self.backupPassphrase,
                                     rounds: VaultBackupFile.leastRounds, salt: Self.backupSalt)
        }
        try write("vault-activity-format-1") {
            try VaultFile.sealPlain(Self.formatActivity(), marker: VaultActivityStore.marker, with: Self.key)
        }
    }

    @Test func theFirstVaultFormatStillOpensAndSealsBackToTheSameJSON() throws {
        let sealed = try Self.fixture("vault-format-1")
        let plain = try VaultFile.openPlain(sealed, marker: VaultFile.marker, with: Self.key)
        let records = try VaultFile.openRecords(sealed, with: Self.key)

        #expect(records.newer.isEmpty, "a record this build wrote reads as a later build's")
        #expect(records.entries == (try Self.formatEntries()))
        let resealed = try VaultFile.seal(records, with: Self.key)
        #expect(try VaultFile.openPlain(resealed, marker: VaultFile.marker, with: Self.key) == plain,
                "sealing what was opened changed the stored JSON")

        // What the shims make of the oldest shape (VT3 removes them, with a migration and a new file).
        let legacy = try #require(records.entries.last)
        #expect(legacy.pin == .older)
        #expect(legacy.kind == .identity)
        #expect(records.entries[1].assignment == .household)
        #expect(records.entries[1].facts?.details.count == 3)
        #expect(records.entries[0].card == .custom("kind-1"))
    }

    @Test func theFirstReadingFormatStillOpensAndSealsBackToTheSameJSON() throws {
        let sealed = try Self.fixture("vault-reading-format-1")
        let plain = try VaultFile.openPlain(sealed, marker: VaultFile.readingMarker, with: Self.key)
        let state = try VaultFile.open(VaultReadingState.self, sealed, marker: VaultFile.readingMarker, with: Self.key)

        #expect(state == (try Self.formatReading()))
        // Sealed again, it differs only by what this build always writes and the first did not:
        // an empty `names`.
        let resealed = try VaultFile.seal(state, marker: VaultFile.readingMarker, with: Self.key)
        var first = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(first["names"] == nil)
        first["names"] = [String: String]()
        let again = try VaultFile.openPlain(resealed, marker: VaultFile.readingMarker, with: Self.key)
        #expect(again == (try JSONSerialization.data(withJSONObject: first, options: [.sortedKeys])))
    }

    /// Format 2 (2026-11-21): what Read from This Copy, name corrections, name roles and Refresh
    /// added, every one set.
    static func formatEntries2() throws -> [VaultEntry] {
        var entries = try formatEntries()
        entries[1].chosenSource = "Immigration/Copies/Passport.pdf"
        entries[1].facts?.spokenBy = "Immigration/Passport/Pat/Passport 2030.pdf"
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

    @Test func theSecondFormatsStillOpenAndSealBackToTheSameJSON() throws {
        let vault = try Self.fixture("vault-format-2")
        let records = try VaultFile.openRecords(vault, with: Self.key)
        #expect(records.newer.isEmpty)
        #expect(records.entries == (try Self.formatEntries2()))
        #expect(try VaultFile.openPlain(VaultFile.seal(records, with: Self.key), marker: VaultFile.marker, with: Self.key)
                == VaultFile.openPlain(vault, marker: VaultFile.marker, with: Self.key))

        let reading = try Self.fixture("vault-reading-format-2")
        let state = try VaultFile.open(VaultReadingState.self, reading, marker: VaultFile.readingMarker, with: Self.key)
        #expect(state == (try Self.formatReading2()))
        let resealed = try VaultFile.seal(state, marker: VaultFile.readingMarker, with: Self.key)
        #expect(try VaultFile.openPlain(resealed, marker: VaultFile.readingMarker, with: Self.key)
                == VaultFile.openPlain(reading, marker: VaultFile.readingMarker, with: Self.key))
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
        var list = try entries.map { try JSONSerialization.jsonObject(with: JSONEncoder.vault.encode($0)) }
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
    static func sealed(_ entries: [VaultEntry], plus changes: [[String: Any]]) throws -> Data {
        let encoder = JSONEncoder.vault
        var list = try entries.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
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
        try Self.sealed(entries, plus: [["category": "bankAccount", "extra": ["a": 1]]]).write(to: rig.scratch.fileURL)
        let before = try VaultFile.openRecords(Data(contentsOf: rig.scratch.fileURL), with: Self.key).newer

        let model = rig.model()
        await model.opened()
        #expect(model.contents == .loaded)
        #expect(model.newerRecords == 1)
        #expect(model.entries == entries)

        #expect(model.add(.init(title: "Library card", value: "LIB0000001", note: "", kind: .other)) != nil)

        let after = try VaultFile.openRecords(Data(contentsOf: rig.scratch.fileURL), with: Self.key)
        #expect(after.entries.count == 3)
        #expect(after.newer == before, "a later build's record changed on its way back to disk")
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
        #expect(store.backups.map(\.lastPathComponent) == ["vault-backup-20270115T080002.000Z-001.sealed",
                                                           "vault-backup-20270115T080001.000Z-001.sealed"])
        for url in store.backups {
            #expect(url.deletingLastPathComponent() == scratch.fileURL.deletingLastPathComponent())
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            let bytes = try Data(contentsOf: url)
            #expect(bytes.range(of: Data("NUM100000".utf8)) == nil)
        }
    }

    @Test func onlyTheNewestBackupsAreKept() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        // One clock reading for every save: names that collide still keep their order.
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: { VaultFormatTests.day })
        for n in 1...(VaultStore.backupsKept + 3) {
            try store.save((1...n).map(Self.entry))
        }
        let key = SymmetricKey(data: try #require(keychain.itemData))
        let counts = try store.backups.map { try VaultFile.open(Data(contentsOf: $0), with: key).count }
        #expect(counts == Array((3...(VaultStore.backupsKept + 2)).reversed()))
    }

    /// A Vault set aside takes its backups with it: they open only with its key, and left in
    /// place the new Vault's saves would prune them.
    @Test func settingAsideTakesTheBackupsWithTheVault() throws {
        let scratch = try VaultScratch(); defer { scratch.remove() }
        let keychain = VaultFakeKeychain()
        let ticker = Ticker()
        let store = VaultStore(fileURL: scratch.fileURL, keychain: keychain, clock: ticker.next)
        try store.save([Self.entry(1)])
        try store.save([Self.entry(1), Self.entry(2)])
        try store.save([Self.entry(1), Self.entry(2), Self.entry(3)])
        let before = try store.backups.map { try Data(contentsOf: $0) }
        #expect(before.count == 2)

        #expect(store.setAside(at: Self.day))
        #expect(store.backups.isEmpty)
        let folder = scratch.fileURL.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("vault-backup-") && $0.contains(".set-aside-") }.sorted(by: >)
        #expect(try aside.map { try Data(contentsOf: folder.appendingPathComponent($0)) } == before)

        // A new key's saves never reach them.
        keychain.itemData = nil
        for n in 1...(VaultStore.backupsKept + 2) { try store.save((1...n).map(Self.entry)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.contains(".set-aside-") && $0.hasPrefix("vault-backup-") }.count == 2)
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

        // One at a time, as Remove does, or with the flag a migration would pass.
        try store.save([three[0], three[2]])
        try store.save([], allowingDrops: true)
        #expect(try store.load().isEmpty)
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
        try store.save([VaultEntry(title: "Passport", value: "Q7310462", addedAt: Self.day)])
        var damaged = try Data(contentsOf: scratch.fileURL)
        damaged[damaged.count - 1] ^= 0x01
        try damaged.write(to: scratch.fileURL)

        let log = LogCapture()
        #expect(throws: VaultError.wrongKeyOrDamaged) { try store.load() }
        let lines = await log.entries.map(\.messageBody)
        // The whole sentence, size included: a sibling case's damaged file logs the same words.
        #expect(lines.contains("Vault: the sealed file did not open (wrongKeyOrDamaged, \(damaged.count) bytes, begins SCVAULT1) — it is left as it is"))
        #expect(!lines.contains { $0.contains("Q7310462") || $0.contains("Passport") })
    }

    @Test func aSummaryNamesOnlyAVaultMarker() {
        #expect(VaultFile.summary(of: Data("SCVREAD1abc".utf8)) == "11 bytes, begins SCVREAD1")
        #expect(VaultFile.summary(of: Data("SCVAULT9xyz".utf8)) == "11 bytes, begins SCVAULT9")
        #expect(VaultFile.summary(of: Data("Q7310462 is my number".utf8)) == "21 bytes, no Vault marker")
        #expect(VaultFile.summary(of: Data()) == "0 bytes, no Vault marker")
    }

    @Test @MainActor func aReadingFileThatDoesNotOpenAsksForAReadAndIsSetAside() async throws {
        let rig = try VaultModelTests.Rig(); defer { rig.cleanUp() }
        try rig.seed([Self.entry(1)])
        let reading = rig.store.readingURL
        try Data("SCVREAD1 not a sealed box".utf8).write(to: reading)

        let log = LogCapture()
        let model = rig.model()
        await model.opened()

        #expect(model.contents == .loaded)
        #expect(model.needsReadAgain, "a lost reading file left no Read Again")
        #expect(await log.holds(.warning, containing: "the reading file did not open (unreadableFile"))
        let folder = reading.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("vault-reading.sealed.unreadable-") }
        #expect(aside.count == 1, "the file that did not open was not kept")
        #expect(!FileManager.default.fileExists(atPath: reading.path))
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
