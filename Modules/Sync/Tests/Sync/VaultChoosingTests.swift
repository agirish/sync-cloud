import Foundation
import Testing
@testable import Sync

/// A choice about an ID, saved or waiting, made by one path (VT1). Every number and name is
/// made up.
@Suite struct VaultChoosingTests {
    static let facts = VaultReadFacts(category: .health, holder: "Pat Q", form: "Member ID",
                                      sources: [VaultSource(path: "/papers/card.pdf", role: "Card", rank: 1)])

    /// Move to Archive on an ID an older build marked older stores it as a pin, as the panel's
    /// action always has: what was stored is replaced, not kept beside it.
    @Test func aPinMadeAgainReplacesAnOlderBuildsMark() throws {
        let stored = #"{"id":"00000000-0000-0000-0000-000000000001","title":"Old","value":"P1234567","note":"","kind":"identity","addedAt":0,"updatedAt":0,"older":true}"#
        var entry = try JSONDecoder().decode(VaultLegacyFormat.Entry.self, from: Data(stored.utf8)).entry
        #expect(entry.pin == .older)
        entry.apply(.pin(.older))
        let sealed = String(decoding: try JSONEncoder().encode(VaultLegacyFormat.Entry(entry)), as: UTF8.self)
        #expect(sealed.contains(#""pin":"older""#))
        #expect(!sealed.contains(#""older":"#))
    }

    /// A choice already made for a waiting ID is what the editor starts with; the name is
    /// matched only when none was.
    @Test func aWaitingIDsChoiceWinsOverItsName() {
        let people = [Person(id: "pat", displayName: "Pat", fullNames: ["Pat Q"])]
        var find = VaultFind(title: "Dental plan", value: "MEM0000001", facts: Self.facts)
        #expect(VaultModel.Draft(find, people: people).personID == "pat")
        find.apply(.assignment(.household))
        #expect(VaultModel.Draft(find, people: people).personID == nil)
        #expect(VaultModel.Draft(find, people: people).isHousehold)
        find.apply(.assignment(.person("sam")))
        #expect(VaultModel.Draft(find, people: people).personID == "sam")
    }

    /// Counts the reading file put in place, and refuses the Vault's while told to.
    final class Disk: FileManager, @unchecked Sendable {
        nonisolated(unsafe) var seals = 0
        nonisolated(unsafe) var refusing = false
        let vault: String
        init(vault: String) { self.vault = vault; super.init() }
        private func check(_ url: URL) throws {
            if refusing, url.lastPathComponent == vault { throw CocoaError(.fileWriteNoPermission) }
            if url.lastPathComponent == vault { seals += 1 }   // the document: one write per action
        }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            try check(dstURL)
            try super.moveItem(at: srcURL, to: dstURL)
        }
        override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?,
                                  options: FileManager.ItemReplacementOptions = [],
                                  resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try check(originalItemURL)
            try super.replaceItem(at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName,
                                  options: options, resultingItemURL: resultingItemURL)
        }
    }

    /// Kind on a waiting ID seals the reading file once, with its lesson; on a saved ID whose
    /// save is refused, nothing else happens: no card, no lesson, no seal.
    @MainActor @Test func aKindChoiceSealsOnceAndARefusedSaveStopsIt() async throws {
        let rig = try VaultRig(); defer { rig.cleanUp() }
        VaultReadFolders.add(VaultKindsTests.root, in: rig.defaults)
        let disk = Disk(vault: rig.scratch.fileURL.lastPathComponent)
        let store = VaultStore(fileURL: rig.scratch.fileURL, keychain: rig.keychain, fileManager: disk)
        let model = VaultModel(store: store, authenticator: rig.auth, defaults: rig.defaults,
                               clock: { VaultRig.t0 }, copyToPasteboard: { _ in })
        await model.opened()
        await model.readDocuments(with: VaultKindsTests.documents)
        let waiting = try #require(model.finds.first { $0.value == "1234 5678 9012" })
        var before = disk.seals
        model.setKind(waiting.id, to: .builtIn(.utilities))
        #expect(disk.seals - before == 1)
        #expect(model.rows.first { $0.id == waiting.id }?.card == .builtIn(.utilities))

        let other = try #require(model.finds.first { $0.value == "5555 6666 7777" })
        let saved = try #require(model.confirm(other.id, as: VaultModel.Draft(other)))
        let card = model.rows.first { $0.id == saved }?.card
        disk.refusing = true
        before = disk.seals
        model.setKind(saved, to: .builtIn(.loans))
        #expect(model.rows.first { $0.id == saved }?.card == card)
        #expect(disk.seals == before)
    }
}
