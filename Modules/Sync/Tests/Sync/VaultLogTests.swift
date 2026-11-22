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
            _ = try #require(model.add(.init(title: "Zephyrine's card \(n)", value: Self.typed + "\(n)", note: "", kind: .other)))
        }
        let library = try #require(model.add(.init(title: "Zephyrine's quillery pass", value: Self.typed, note: "", kind: .other)))
        #expect(await model.delete(library))
        // The read one removed and added again: removing it sets its number aside, by fingerprint.
        #expect(await model.delete(saved))
        try #require(rig.defaults.stringArray(forKey: VaultSetAside.key)?.isEmpty == false, "nothing was set aside")

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
}
