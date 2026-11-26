import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// What the Vault writes to the app's log across its whole life, from opening to restoring a
/// backup (VT26): the lines that say what happened, and never a number, a holder's name or a
/// document's name. Every value is made up, and unique to this file, so another case's lines in
/// the same capture cannot pass for these.
@MainActor
@Suite struct VaultLogTests {
    typealias Rig = VaultModelTests.Rig

    static let root = "/Users/zephyrine/Documents"
    static let number = "XQZ730194651"
    static let holder = "ZEPHYRINE OKONKWO-LARSEN"
    static let file = root + "/Health/Qorvane Dental/Qorvane Cards/XQZ730194651 qorvane.pdf"
    static let typed = "LIB7702913"

    @Test func aWholeLifeLogsWhatHappenedAndNeverANumberOrAName() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let log = LogCapture()
        let model = rig.model()
        model.people = [Person(id: "zeph", displayName: "Zephyrine", fullNames: ["Zephyrine Okonkwo-Larsen"])]
        rig.auth.answer = .allowed
        await model.opened()
        #expect(await model.unlock())

        // Read, confirm, show, copy, edit, remove; type one in by hand.
        // Seven documents, a count no other case reads, so the tally line is this life's own.
        var pages = [Self.file: ["Delta Dental", "Member Name: \(Self.holder)", "Member ID: \(Self.number)"]]
        for n in 1...6 { pages[Self.root + "/Immigration/Letters/zeph note \(n).pdf"] = ["Nothing to see here"] }
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: pages))
        let find = try #require(model.finds.first { $0.value == Self.number })
        let saved = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        #expect(await model.show(saved))
        #expect(await model.copy(saved))
        var draft = VaultModel.Draft(try #require(model.entries.first { $0.id == saved }))
        draft.note = "renewed"
        #expect(await model.update(saved, to: draft))
        // Four more typed in, so what is backed up and restored is a count no other case logs.
        for n in 1...4 {
            _ = try #require(model.add(.init(title: "Zephyrine's card \(n)", value: Self.typed + "\(n)", note: "", category: .other)))
        }
        let library = try #require(model.add(.init(title: "Zephyrine's quillery pass", value: Self.typed, note: "", category: .other)))
        #expect(await model.delete(library))
        // The read one removed and added again: removing it sets its number aside, by fingerprint.
        #expect(await model.delete(saved))
        try #require(!rig.store.setAsideOnDisk(rig.defaults).isEmpty, "nothing was set aside")

        // Back up, lock, restore.
        let folder = VaultBackupTests.scratchFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let backup = VaultBackupTests.backup(rig, folder: folder)
        try backup.setPassphrase(VaultBackupTests.phrase)
        let url = try await backup.write(model.entries)
        model.systemLocked()
        let contents = try await backup.read(url).get()
        #expect(await backup.restore(contents, mode: .replace) == .success(4))

        let lines = await log.entries.map(\.messageBody)
        // What happened, in sentences unique to this life.
        #expect(lines.contains { $0.hasPrefix("Vault: 7 document(s), 7 opened in ") }, "the read said nothing")
        #expect(lines.contains("Vault: backed up 4 ID(s)"))
        #expect(lines.contains("Vault: restored from a backup (replaced), 4 ID(s) now"))
        // Never what was in them.
        let secrets = [Self.number, String(Self.number.suffix(6)), Self.typed, "Okonkwo", "OKONKWO", "Zephyrine",
                       "ZEPHYRINE", "zephyrine", "XQZ730194651", "Qorvane", "qorvane", "quillery", "zeph note"]
        for secret in secrets {
            #expect(!lines.contains { $0.contains(secret) }, "the log holds \"\(secret)\"")
        }
        // Nor what is kept in preferences beside the sealed files (VT28): read folders and choices
        // only. The set-aside fingerprints are keyed hashes, never the number.
        let kept = (rig.defaults.persistentDomain(forName: rig.suite) ?? [:]).map { key, value in
            // JSON kept as data is read as its text, or a number in it would pass unseen.
            "\(key)=" + ((value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)")
        }.joined(separator: "\n")
        // The read folder is the user's own path, kept in the clear (VT28's exception).
        for secret in secrets where secret != "zephyrine" {
            #expect(!kept.contains(secret), "preferences hold \"\(secret)\"")
        }
    }

    /// A session says itself in the log (VT22): opened with what it holds and how the lock is set,
    /// each proof and its answer, each lock and why, and the numbers let go. Never a title. Eleven
    /// IDs, a count no other case opens with, so these lines are this session's own.
    @Test func aSessionLogsItsOpeningProofsLocksAndLettingGo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let titles = (1...11).map { "Wexmoor pass \($0)" }
        try rig.seed(titles.enumerated().map { n, title in
            VaultEntry(title: title, value: "WXM\(100_000 + n)", addedAt: VaultRig.t0)
        })
        rig.defaults.set(VaultLockSettings.Relock.afterOneMinute.rawValue, forKey: VaultLockSettings.relockKey)
        let log = LogCapture()
        let model = rig.model()
        // This model's own lines: the log's capture also holds every suite's beside it.
        final class Lines { var all: [String] = [] }
        let own = Lines()
        model.sessionLine = { own.all.append($0) }
        rig.auth.answer = .allowed
        await model.opened()
        #expect(model.contents == .loaded)
        rig.clock.advance(61); model.tick()
        #expect(model.contents != .loaded)
        rig.auth.answer = .cancelled
        #expect(await model.unlock() == false)
        rig.auth.answer = .allowed
        #expect(await model.unlock())
        model.lockNow()

        let loaded = "Vault: loaded, 11 saved ID(s) and 0 to confirm; asks as soon as vault opens, locks after 1 minute idle, or when vault closes"
        let letGo = "Vault: let go of 11 saved ID(s) and 0 to confirm from memory"
        #expect(own.all == ["Vault: a proof to unlock was given", loaded, "Vault: locked (idle)", letGo,
                            "Vault: a proof to unlock was canceled", "Vault: a proof to unlock was given", loaded,
                            "Vault: locked (Lock Now)", letGo])
        // And each reached the log, with nothing of a title in it.
        let lines = await log.entries.map(\.messageBody)
        #expect(own.all.allSatisfy(lines.contains))
        for title in titles + ["Wexmoor", "WXM"] {
            #expect(!lines.contains { $0.contains(title) }, "the log holds \"\(title)\"")
        }
    }

    /// A proof answered after the Vault locked is said to be set aside, not given.
    @Test func aProofAnsweredAfterALockIsLoggedAsSetAside() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultEntry(title: "Wexmoor card", value: "WXM200001", addedAt: VaultRig.t0)])
        let auth = VaultLockedRoutesTests.LocksWhileAsked()
        let model = VaultModel(store: rig.store, authenticator: auth, defaults: rig.defaults,
                               clock: { [clock = rig.clock] in clock.now }, copyToPasteboard: { _ in })
        auth.model = model
        var own: [String] = []
        model.sessionLine = { own.append($0) }
        await model.opened()
        #expect(own == ["Vault: a proof to unlock was answered after the Vault closed or locked, and set aside"])
    }

    /// A reader that notes each of its files locked, as a folder of password PDFs would.
    struct LockedFiles: VaultDocumentReading {
        let paths: [String]
        func files() async -> [URL] { paths.map { URL(fileURLWithPath: $0) } }
        func pages(in file: URL) async -> [[String]] { [] }
        func stamp(of file: URL) -> String? { nil }
        func noted(_ file: URL) async -> (pages: [[String]], complete: Bool, notes: VaultReadNotes, origins: [VaultPageOrigin]?) {
            var notes = VaultReadNotes()
            notes.locked = 1
            return ([], true, notes, nil)
        }
    }

    /// The read's summary counts each file's notes (VT25): nine locked PDFs, a count no other case reads.
    @Test func theReadsSummaryCountsWhatWasPassedOver() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let root = "/Users/wexmoor/Documents"
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        await model.opened()
        let log = LogCapture()
        await model.readDocuments(with: LockedFiles(paths: (1...9).map { "\(root)/Immigration/Passport/locked \($0).pdf" }))
        let lines = await log.entries.map(\.messageBody)
        #expect(lines.contains { $0.hasPrefix("Vault: 9 document(s), 9 opened in ") && $0.hasSuffix("; 9 locked") },
                "\(lines.filter { $0.contains("9 document(s)") })")
    }

    /// A close says "locked" only when it locked an open Vault: not under "For every ID",
    /// where nothing was open to lock, and not twice.
    @Test func aCloseThatLocksNothingSaysNothingLocked() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultEntry(title: "Wexmoor card", value: "WXM300001", addedAt: VaultRig.t0)])
        rig.defaults.set(VaultLockSettings.Ask.everyNumber.rawValue, forKey: VaultLockSettings.askKey)
        let model = rig.model()
        var own: [String] = []
        model.sessionLine = { own.append($0) }
        await model.opened()
        model.closed()
        #expect(!own.contains { $0.hasPrefix("Vault: locked") }, "\(own)")
        #expect(own.last == "Vault: let go of 1 saved ID(s) and 0 to confirm from memory")
    }

    /// Under "After 10 minutes idle, even if closed": closing locks nothing; reopened after the
    /// limit, the idle lock is said once; and the Mac sleeping says a lock only while it was open.
    @Test func aVaultLeftOpenAcrossClosingSaysEachLockOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultEntry(title: "Wexmoor card", value: "WXM400001", addedAt: VaultRig.t0)])
        rig.defaults.set(VaultLockSettings.Relock.afterTenMinutes.rawValue, forKey: VaultLockSettings.relockKey)
        rig.auth.answer = .allowed
        let model = rig.model()
        var own: [String] = []
        model.sessionLine = { own.append($0) }
        await model.opened()
        model.closed()
        #expect(model.contents == .loaded && !own.contains { $0.hasPrefix("Vault: locked") }, "\(own)")
        rig.clock.advance(601)
        await model.opened()
        #expect(own.filter { $0 == "Vault: locked (idle, while closed)" }.count == 1, "\(own)")
        // Open again after its proof; the Mac sleeps twice: one lock.
        #expect(model.isOpen)
        model.systemLocked()
        model.systemLocked()
        #expect(own.filter { $0 == "Vault: locked (the Mac locked or slept, or the window closed)" }.count == 1, "\(own)")
    }
}
