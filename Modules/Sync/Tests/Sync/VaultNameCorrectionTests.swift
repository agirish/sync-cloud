import Foundation
import Testing
@testable import Sync

/// Edit's Name: a name a scan misread, corrected for one ID or for every ID read so, and kept
/// across later reads. Nothing changes for another ID but by saving with Everywhere. Every
/// number and name is made up.
@MainActor
@Suite struct VaultNameCorrectionTests {
    typealias Rig = VaultModelTests.Rig
    typealias PlannedDocuments = VaultAccountModelTests.PlannedDocuments

    static let root = "/Users/anna/Documents"
    static let pages: [String: [String]] = [
        root + "/Health/Dental/ID Cards/card.pdf": ["Member Name: TOBLAS LINDQVIST", "Member ID: XZB123456789"],
        root + "/Health/Vision/ID Cards/card.pdf": ["Member Name: TOBLAS LINDQVIST", "Member ID: VSP99887766"],
        root + "/Health/Medical/ID Cards/card.pdf": ["Member Name: TOBLAS LINDQVIST", "Member ID: KP12345678"],
    ]

    static func model(_ rig: Rig) async -> VaultModel {
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        model.people = [Person(id: "tobias", displayName: "Tobias")]
        await model.opened()
        await model.readDocuments(with: PlannedDocuments(pages: pages))
        return model
    }

    static func holder(_ model: VaultModel, _ value: String) -> String? {
        model.rows.first { $0.value == value }?.facts?.holder
    }

    /// Confirms the waiting `value` as Edit would: opened, its Name set, Everywhere as given.
    static func confirm(_ model: VaultModel, _ value: String, name: String?, everywhere: Bool) throws -> UUID {
        let find = try #require(model.finds.first { $0.value == value })
        var draft = model.prepared(VaultModel.Draft(find))
        draft.holderName = name
        draft.correctEverywhere = everywhere
        return try #require(model.confirm(find.id, as: draft))
    }

    @Test func oneIDsCorrectionIsShownMatchedAndKeepsWhatWasRead() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        #expect(model.rows.first { $0.value == "XZB123456789" }?.personID == nil, "a misread name answers to nobody")
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(model.prepared(VaultModel.Draft(find)).correctEverywhere == false, "Everywhere starts off")
        let saved = try Self.confirm(model, "XZB123456789", name: "Tobias Lindqvist", everywhere: false)
        let row = try #require(model.rows.first { $0.id == saved })
        #expect(row.facts?.holder == "Tobias Lindqvist" && row.readHolder == "Toblas Lindqvist")
        #expect(row.personID == "tobias", "the corrected name is the one matched")
        #expect(Self.holder(model, "VSP99887766") == "Toblas Lindqvist", "this one only")
        // Read Everything Again: the document says Toblas once more; the correction stands.
        await model.readDocuments(with: PlannedDocuments(pages: Self.pages), again: true)
        #expect(model.rows.first { $0.id == saved }?.facts?.holder == "Tobias Lindqvist")
    }

    @Test func everywhereReachesTheOthersAndLaterReadsAndOutlivesClosing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(model.otherIDs(readAs: "TOBLAS LINDQVIST", excluding: find.id) == 2)
        _ = try Self.confirm(model, "XZB123456789", name: "Tobias Lindqvist", everywhere: true)
        let other = try #require(model.rows.first { $0.value == "VSP99887766" })
        #expect(other.facts?.holder == "Tobias Lindqvist" && other.readHolder == "Toblas Lindqvist" && other.personID == "tobias")
        var later = Self.pages
        later[Self.root + "/Health/Hearing/ID Cards/card.pdf"] = ["Member Name: TOBLAS LINDQVIST", "Member ID: HR55554444"]
        await model.readDocuments(with: PlannedDocuments(pages: later))
        #expect(Self.holder(model, "HR55554444") == "Tobias Lindqvist", "corrected as it arrives")
        model.closed()
        await model.opened()
        #expect(Self.holder(model, "HR55554444") == "Tobias Lindqvist")
    }

    /// A correction made everywhere belongs to the save it came with: a save the Keychain refuses
    /// renames no other ID, now or after the Vault is opened again (VT63).
    @Test func aRefusedSaveMakesNoCorrectionEverywhere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        var draft = model.prepared(VaultModel.Draft(find))
        draft.holderName = "Tobias Lindqvist"
        draft.correctEverywhere = true

        rig.keychain.forcedCopyStatus = errSecAuthFailed
        #expect(model.confirm(find.id, as: draft) == nil, "the save was refused")
        #expect(Self.holder(model, "VSP99887766") == "Toblas Lindqvist", "renamed by a change that was not kept")
        rig.keychain.forcedCopyStatus = nil

        model.closed()
        await model.opened()
        #expect(Self.holder(model, "VSP99887766") == "Toblas Lindqvist")
        // Saved this time, it reaches the others.
        let again = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(model.confirm(again.id, as: draft) != nil)
        #expect(Self.holder(model, "VSP99887766") == "Tobias Lindqvist")
    }

    /// Counts the reading file put in place: each one is a whole seal.
    final class CountsSeals: FileManager, @unchecked Sendable {
        nonisolated(unsafe) var seals = 0
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if dstURL.lastPathComponent == "vault.sealed" { seals += 1 }   // the document: one write per action
            try super.moveItem(at: srcURL, to: dstURL)
        }
        override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?,
                                  options: FileManager.ItemReplacementOptions = [],
                                  resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            if originalItemURL.lastPathComponent == "vault.sealed" { seals += 1 }   // the document: one write per action
            try super.replaceItem(at: originalItemURL, withItemAt: newItemURL, backupItemName: backupItemName,
                                  options: options, resultingItemURL: resultingItemURL)
        }
    }

    /// One action seals the reading file once (VT65): Confirm with Everywhere sealed it for the
    /// correction, for the find it took away, and for itself.
    @Test func oneConfirmSealsTheReadingFileOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let disk = CountsSeals()
        let store = VaultStore(fileURL: rig.scratch.fileURL, keychain: rig.keychain, fileManager: disk)
        let model = VaultModel(store: store, authenticator: rig.auth, defaults: rig.defaults,
                               clock: { VaultLockTests.t0 }, copyToPasteboard: { _ in })
        model.people = [Person(id: "tobias", displayName: "Tobias")]
        await model.opened()
        await model.readDocuments(with: PlannedDocuments(pages: Self.pages))
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        var draft = model.prepared(VaultModel.Draft(find))
        draft.holderName = "Tobias Lindqvist"
        draft.correctEverywhere = true
        let before = disk.seals
        #expect(model.confirm(find.id, as: draft) != nil)
        #expect(disk.seals - before == 1, "\(disk.seals - before) seals for one Confirm")
        #expect(Self.holder(model, "VSP99887766") == "Tobias Lindqvist")
        // What it sealed is all of it, read from the file as it now stands.
        let sealed = try #require(store.readingOnDisk())
        #expect(sealed.names.values.contains("Tobias Lindqvist"), "the correction was not in the one seal")
        #expect(!sealed.finds.contains { $0.value == "XZB123456789" }, "the confirmed find was not taken out in it")

        // Edit with Everywhere, and Add, seal once too.
        let other = try #require(model.finds.first { $0.value == "VSP99887766" })
        let saved = try #require(model.confirm(other.id, as: VaultModel.Draft(other)))
        var edit = model.prepared(VaultModel.Draft(try #require(model.entries.first { $0.id == saved })), for: saved)
        edit.holderName = "Tobias L. Lindqvist"
        edit.correctEverywhere = true
        let beforeEdit = disk.seals
        #expect(await model.update(saved, to: edit))
        #expect(disk.seals - beforeEdit == 1, "\(disk.seals - beforeEdit) seals for one Edit")
        let waiting = try #require(model.finds.first { $0.value == "KP12345678" })
        var typed = VaultModel.Draft(title: "Medical card", value: waiting.value, note: "", category: .other)
        typed.category = .health
        let beforeAdd = disk.seals
        #expect(model.add(typed) != nil)
        #expect(disk.seals - beforeAdd == 1, "\(disk.seals - beforeAdd) seals for one Add")
    }

    /// The same for Edit: a refused save of a saved ID makes no correction everywhere (VT63).
    @Test func aRefusedEditMakesNoCorrectionEverywhere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let saved = try Self.confirm(model, "XZB123456789", name: nil, everywhere: false)
        let entry = try #require(model.entries.first { $0.id == saved })
        var draft = model.prepared(VaultModel.Draft(entry), for: saved)
        draft.holderName = "Tobias Lindqvist"
        draft.correctEverywhere = true

        rig.keychain.forcedCopyStatus = errSecAuthFailed
        #expect(await model.update(saved, to: draft) == false, "the save was refused")
        #expect(Self.holder(model, "VSP99887766") == "Toblas Lindqvist")
        rig.keychain.forcedCopyStatus = nil
        model.closed()
        await model.opened()
        #expect(Self.holder(model, "VSP99887766") == "Toblas Lindqvist")
        // Saved this time, it reaches the others: the refusal above is what held it back.
        #expect(await model.update(saved, to: draft))
        #expect(Self.holder(model, "VSP99887766") == "Tobias Lindqvist")
    }

    /// Confirming or editing another ID read the same way, its Name untouched, leaves the
    /// correction where it was.
    @Test func savingAnotherIDUntouchedKeepsTheCorrectionEverywhere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        _ = try Self.confirm(model, "XZB123456789", name: "Tobias Lindqvist", everywhere: true)
        let vision = try #require(model.finds.first { $0.value == "VSP99887766" })
        let opened = model.prepared(VaultModel.Draft(vision))
        #expect(opened.holderName == "Tobias Lindqvist" && opened.correctEverywhere, "Edit opens as it stands")
        let saved = try #require(model.confirm(vision.id, as: opened))
        #expect(Self.holder(model, "KP12345678") == "Tobias Lindqvist", "the third still corrected")
        // Its note changed later, nothing else: still corrected everywhere.
        let entry = try #require(model.entries.first { $0.id == saved })
        var note = model.prepared(VaultModel.Draft(entry))
        note.note = "Vision plan"
        #expect(await model.update(saved, to: note))
        #expect(Self.holder(model, "KP12345678") == "Tobias Lindqvist")
    }

    /// A correction for one ID stays one ID's when it is edited again.
    @Test func editingAnIDCorrectedAloneNeverSpreadsIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let saved = try Self.confirm(model, "XZB123456789", name: "Tobias Lindqvist", everywhere: false)
        let entry = try #require(model.entries.first { $0.id == saved })
        var note = model.prepared(VaultModel.Draft(entry))
        #expect(!note.correctEverywhere)
        note.note = "Dental plan"
        #expect(await model.update(saved, to: note))
        #expect(Self.holder(model, "VSP99887766") == "Toblas Lindqvist")
    }

    /// One ID put back as read stays as read, and the correction others share is untouched.
    @Test func oneIDPutBackAsReadLeavesTheOthersCorrected() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        _ = try Self.confirm(model, "XZB123456789", name: "Tobias Lindqvist", everywhere: true)
        let saved = try Self.confirm(model, "VSP99887766", name: "Toblas Lindqvist", everywhere: false)
        #expect(model.rows.first { $0.id == saved }?.facts?.holder == "Toblas Lindqvist", "put back, it stays as read")
        #expect(Self.holder(model, "KP12345678") == "Tobias Lindqvist")
        #expect(model.otherIDs(readAs: "Toblas Lindqvist", excluding: saved) == 2, "one with a name of its own is not counted")
    }

    @Test func putBackEverywhereTheCorrectionIsUnmade() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let saved = try Self.confirm(model, "XZB123456789", name: "Tobias Lindqvist", everywhere: true)
        let entry = try #require(model.entries.first { $0.id == saved })
        var back = model.prepared(VaultModel.Draft(entry))
        back.holderName = ""
        #expect(await model.update(saved, to: back))
        #expect(Self.holder(model, "VSP99887766") == "Toblas Lindqvist")
        #expect(model.rows.first { $0.id == saved }?.facts?.holder == "Toblas Lindqvist")
    }

    @Test func aChangeOfCaseAloneIsACorrection() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let saved = try Self.confirm(model, "XZB123456789", name: "TOBLAS LINDQVIST", everywhere: false)
        #expect(model.rows.first { $0.id == saved }?.facts?.holder == "TOBLAS LINDQVIST", "read as Toblas Lindqvist")
    }

    @Test func aSealedStateFromBeforeNamesStillOpens() throws {
        let state = try JSONDecoder().decode(VaultReadingState.self,
                                             from: Data(#"{"version":1,"generation":0,"finds":[]}"#.utf8))
        #expect(state.names.isEmpty)
        #expect(VaultReading.spellingKey("SIGRID  LINNEA-BERQ") == VaultReading.spellingKey("Sigrid Linnea Berq"))
        #expect(VaultReading.spellingKey("Sigrid Linnea Berg") != VaultReading.spellingKey("Sigrid Linnea Berq"))
    }
}
