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
        root + "/Health/Dental/ID Cards/card.pdf": ["Member Name: DLVIT GIRISH", "Member ID: XZB123456789"],
        root + "/Health/Vision/ID Cards/card.pdf": ["Member Name: DLVIT GIRISH", "Member ID: VSP99887766"],
        root + "/Health/Medical/ID Cards/card.pdf": ["Member Name: DLVIT GIRISH", "Member ID: KP12345678"],
    ]

    static func model(_ rig: Rig) async -> VaultModel {
        VaultReadFolders.add(root, in: rig.defaults)
        let model = rig.model()
        model.people = [Person(id: "divit", displayName: "Divit")]
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
        let saved = try Self.confirm(model, "XZB123456789", name: "Divit Girish", everywhere: false)
        let row = try #require(model.rows.first { $0.id == saved })
        #expect(row.facts?.holder == "Divit Girish" && row.readHolder == "Dlvit Girish")
        #expect(row.personID == "divit", "the corrected name is the one matched")
        #expect(Self.holder(model, "VSP99887766") == "Dlvit Girish", "this one only")
        // Read Everything Again: the document says Dlvit once more; the correction stands.
        await model.readDocuments(with: PlannedDocuments(pages: Self.pages), again: true)
        #expect(model.rows.first { $0.id == saved }?.facts?.holder == "Divit Girish")
    }

    @Test func everywhereReachesTheOthersAndLaterReadsAndOutlivesClosing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(model.otherIDs(readAs: "DLVIT GIRISH", excluding: find.id) == 2)
        _ = try Self.confirm(model, "XZB123456789", name: "Divit Girish", everywhere: true)
        let other = try #require(model.rows.first { $0.value == "VSP99887766" })
        #expect(other.facts?.holder == "Divit Girish" && other.readHolder == "Dlvit Girish" && other.personID == "divit")
        var later = Self.pages
        later[Self.root + "/Health/Hearing/ID Cards/card.pdf"] = ["Member Name: DLVIT GIRISH", "Member ID: HR55554444"]
        await model.readDocuments(with: PlannedDocuments(pages: later))
        #expect(Self.holder(model, "HR55554444") == "Divit Girish", "corrected as it arrives")
        model.closed()
        await model.opened()
        #expect(Self.holder(model, "HR55554444") == "Divit Girish")
    }

    /// A correction made everywhere belongs to the save it came with: a save the Keychain refuses
    /// renames no other ID, now or after the Vault is opened again (VT63).
    @Test func aRefusedSaveMakesNoCorrectionEverywhere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        var draft = model.prepared(VaultModel.Draft(find))
        draft.holderName = "Divit Girish"
        draft.correctEverywhere = true

        rig.keychain.forcedCopyStatus = errSecAuthFailed
        #expect(model.confirm(find.id, as: draft) == nil, "the save was refused")
        #expect(Self.holder(model, "VSP99887766") == "Dlvit Girish", "renamed by a change that was not kept")
        rig.keychain.forcedCopyStatus = nil

        model.closed()
        await model.opened()
        #expect(Self.holder(model, "VSP99887766") == "Dlvit Girish")
        // Saved this time, it reaches the others.
        let again = try #require(model.finds.first { $0.value == "XZB123456789" })
        #expect(model.confirm(again.id, as: draft) != nil)
        #expect(Self.holder(model, "VSP99887766") == "Divit Girish")
    }

    /// The same for Edit: a refused save of a saved ID makes no correction everywhere (VT63).
    @Test func aRefusedEditMakesNoCorrectionEverywhere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let saved = try Self.confirm(model, "XZB123456789", name: nil, everywhere: false)
        let entry = try #require(model.entries.first { $0.id == saved })
        var draft = model.prepared(VaultModel.Draft(entry), for: saved)
        draft.holderName = "Divit Girish"
        draft.correctEverywhere = true

        rig.keychain.forcedCopyStatus = errSecAuthFailed
        #expect(await model.update(saved, to: draft) == false, "the save was refused")
        #expect(Self.holder(model, "VSP99887766") == "Dlvit Girish")
        rig.keychain.forcedCopyStatus = nil
        model.closed()
        await model.opened()
        #expect(Self.holder(model, "VSP99887766") == "Dlvit Girish")
        // Saved this time, it reaches the others: the refusal above is what held it back.
        #expect(await model.update(saved, to: draft))
        #expect(Self.holder(model, "VSP99887766") == "Divit Girish")
    }

    /// Confirming or editing another ID read the same way, its Name untouched, leaves the
    /// correction where it was.
    @Test func savingAnotherIDUntouchedKeepsTheCorrectionEverywhere() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        _ = try Self.confirm(model, "XZB123456789", name: "Divit Girish", everywhere: true)
        let vision = try #require(model.finds.first { $0.value == "VSP99887766" })
        let opened = model.prepared(VaultModel.Draft(vision))
        #expect(opened.holderName == "Divit Girish" && opened.correctEverywhere, "Edit opens as it stands")
        let saved = try #require(model.confirm(vision.id, as: opened))
        #expect(Self.holder(model, "KP12345678") == "Divit Girish", "the third still corrected")
        // Its note changed later, nothing else: still corrected everywhere.
        let entry = try #require(model.entries.first { $0.id == saved })
        var note = model.prepared(VaultModel.Draft(entry))
        note.note = "Vision plan"
        #expect(await model.update(saved, to: note))
        #expect(Self.holder(model, "KP12345678") == "Divit Girish")
    }

    /// A correction for one ID stays one ID's when it is edited again.
    @Test func editingAnIDCorrectedAloneNeverSpreadsIt() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let saved = try Self.confirm(model, "XZB123456789", name: "Divit Girish", everywhere: false)
        let entry = try #require(model.entries.first { $0.id == saved })
        var note = model.prepared(VaultModel.Draft(entry))
        #expect(!note.correctEverywhere)
        note.note = "Dental plan"
        #expect(await model.update(saved, to: note))
        #expect(Self.holder(model, "VSP99887766") == "Dlvit Girish")
    }

    /// One ID put back as read stays as read, and the correction others share is untouched.
    @Test func oneIDPutBackAsReadLeavesTheOthersCorrected() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        _ = try Self.confirm(model, "XZB123456789", name: "Divit Girish", everywhere: true)
        let saved = try Self.confirm(model, "VSP99887766", name: "Dlvit Girish", everywhere: false)
        #expect(model.rows.first { $0.id == saved }?.facts?.holder == "Dlvit Girish", "put back, it stays as read")
        #expect(Self.holder(model, "KP12345678") == "Divit Girish")
        #expect(model.otherIDs(readAs: "Dlvit Girish", excluding: saved) == 2, "one with a name of its own is not counted")
    }

    @Test func putBackEverywhereTheCorrectionIsUnmade() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let saved = try Self.confirm(model, "XZB123456789", name: "Divit Girish", everywhere: true)
        let entry = try #require(model.entries.first { $0.id == saved })
        var back = model.prepared(VaultModel.Draft(entry))
        back.holderName = ""
        #expect(await model.update(saved, to: back))
        #expect(Self.holder(model, "VSP99887766") == "Dlvit Girish")
        #expect(model.rows.first { $0.id == saved }?.facts?.holder == "Dlvit Girish")
    }

    @Test func aChangeOfCaseAloneIsACorrection() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = await Self.model(rig)
        let saved = try Self.confirm(model, "XZB123456789", name: "DLVIT GIRISH", everywhere: false)
        #expect(model.rows.first { $0.id == saved }?.facts?.holder == "DLVIT GIRISH", "read as Dlvit Girish")
    }

    @Test func aSealedStateFromBeforeNamesStillOpens() throws {
        let state = try JSONDecoder().decode(VaultReadingState.self,
                                             from: Data(#"{"version":1,"generation":0,"finds":[]}"#.utf8))
        #expect(state.names.isEmpty)
        #expect(VaultReading.spellingKey("SHWETA  RAVINDRA-DANT") == VaultReading.spellingKey("Shweta Ravindra Dant"))
        #expect(VaultReading.spellingKey("Shweta Ravindra Dani") != VaultReading.spellingKey("Shweta Ravindra Dant"))
    }
}
