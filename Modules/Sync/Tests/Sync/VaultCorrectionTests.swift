import Foundation
import Testing
@testable import Sync

/// A correction as the pane shows it, Undo, and the editor's refusal of an ID the Vault has.
/// Every number is made up.
@MainActor
@Suite struct VaultCorrectionTests {
    typealias Rig = VaultModelTests.Rig
    static let card = VaultReadAsTests.card

    /// Anna's license, read as D1234567 and waiting.
    static func waiting(_ rig: Rig) async throws -> (model: VaultModel, find: VaultFind) {
        let model = rig.model()
        model.fileContents = { await VaultReadAsTests.documents([card: VaultFixtures.licensePage]).contentKey(of: $0) }
        await model.readDocuments(with: VaultReadAsTests.documents([card: VaultFixtures.licensePage]))
        return (model, try #require(model.finds.first))
    }

    static func corrected(_ model: VaultModel, _ find: VaultFind, to value: String) throws -> UUID {
        var draft = VaultModel.Draft(find)
        draft.value = value
        return try #require(model.confirm(find.id, as: draft))
    }

    @Test func aCorrectionSaysWhatItChangedAndInWhichFile() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, find) = try await Self.waiting(rig)
        let id = try Self.corrected(model, find, to: "D1234568")
        #expect(model.lastCorrection == VaultModel.Correction(id: id, file: "License.pdf", changed: 1))
        // Not a correction: saved as read.
        let otherRig = try Rig(); defer { otherRig.cleanUp() }
        let other = try await Self.waiting(otherRig)
        _ = other.model.confirm(other.find.id, as: VaultModel.Draft(other.find))
        #expect(other.model.lastCorrection == nil)
        #expect(VaultModel.charactersChanged("D1234567", "D1234598") == 2)
        #expect(VaultModel.charactersChanged("D1234567", "D12345678") == nil)
    }

    @Test func undoingACorrectionMadeOnAddingPutsTheReadingBackToConfirm() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, find) = try await Self.waiting(rig)
        let id = try Self.corrected(model, find, to: "D1234568")
        let writes = model.documentWrites
        #expect(model.undoCorrection())
        #expect(model.documentWrites == writes + 1, "the saved ID goes and the waiting one comes back in one write")
        #expect(try rig.store.loadDocument()?.document.finds().map(\.value) == ["D1234567"], "back in To Confirm on disk")
        await model.notesWritten()
        #expect(!model.entries.contains { $0.id == id }, "the added ID stayed")
        #expect(model.finds.map(\.value) == ["D1234567"])
        #expect(model.selection == find.id)
        #expect(model.rows.first { $0.id == find.id }?.documents.map(\.path) == [Self.card], "its card did not come back with it")
        #expect(model.lastCorrection == nil)
        #expect(!model.undoCorrection(), "Undo ran twice")
        // Nothing was set aside, so the next read finds it waiting still.
        await model.readDocuments(with: VaultReadAsTests.documents([Self.card: VaultFixtures.licensePage]), again: true)
        #expect(model.finds.map(\.value) == ["D1234567"])
    }

    @Test func undoingAnEditPutsTheNumberAndItsNotesBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, find) = try await Self.waiting(rig)
        let id = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        var draft = VaultModel.Draft(try #require(model.entries.first { $0.id == id }))
        draft.value = "D1234568"
        #expect(await model.update(id, to: draft))
        await model.notesWritten()
        #expect(model.entries.first { $0.id == id }?.readAs?.count == 1)
        #expect(model.undoCorrection(), "notes written since kept Undo from working")
        let entry = try #require(model.entries.first { $0.id == id })
        #expect(entry.value == "D1234567" && entry.readAs == nil)
        #expect(model.finds.isEmpty)
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path) == [Self.card])
    }

    @Test func aNoteStillBeingWrittenIsNotAddedToAnIDUndoPutBack() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, find) = try await Self.waiting(rig)
        let id = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        var draft = VaultModel.Draft(try #require(model.entries.first { $0.id == id }))
        draft.value = "D1234568"
        #expect(await model.update(id, to: draft))
        #expect(model.undoCorrection())
        await model.notesWritten()
        #expect(model.entries.first { $0.id == id }?.readAs == nil)
    }

    @Test func undoIsRefusedOnceTheIDChangedAgainAndGoesWithTheLock() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let (model, find) = try await Self.waiting(rig)
        let id = try Self.corrected(model, find, to: "D1234568")
        model.pin(id, .older)
        #expect(!model.undoCorrection())
        #expect(model.entries.contains { $0.id == id })

        let againRig = try Rig(); defer { againRig.cleanUp() }
        let (again, waiting) = try await Self.waiting(againRig)
        _ = try Self.corrected(again, waiting, to: "D1234568")
        again.systemLocked()
        #expect(again.lastCorrection == nil)
        await again.opened()
        #expect(!again.undoCorrection())
    }

    static let letter = "/Documents/Identity/License/Anna/Renewal letter.pdf"
    /// The letter prints the license's number as it really is, D1234568.
    static let letterPage = ["California USA DRIVER LICENSE", "DL D1234568", "EXP 05/16/2030", "LN ERIKSSON", "FN ANNA", "Renewal"]

    @Test func undoBringsBackAWaitingIDTheCorrectedNumberDropped() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        let documents = VaultReadAsTests.documents([Self.card: VaultFixtures.licensePage, Self.letter: Self.letterPage])
        model.fileContents = { [documents] in await documents.contentKey(of: $0) }
        await model.readDocuments(with: documents)
        let misread = try #require(model.finds.first { $0.value == "D1234567" })
        let letter = try #require(model.finds.first { $0.value == "D1234568" })
        let id = try Self.corrected(model, misread, to: "D1234568")
        #expect(model.finds.isEmpty, "the letter's reading still waited beside the ID that has its number now")
        await model.notesWritten()
        #expect(model.undoCorrection())
        #expect(Set(model.finds.map(\.id)) == [misread.id, letter.id], "the letter's reading went with the Undo")
        #expect(!model.entries.contains { $0.id == id })
        #expect(model.rows.first { $0.id == letter.id }?.documents.map(\.path) == [Self.letter])

        // The same through Edit.
        let editRig = try Rig(); defer { editRig.cleanUp() }
        let edited = editRig.model()
        edited.fileContents = { [documents] in await documents.contentKey(of: $0) }
        await edited.readDocuments(with: documents)
        let first = try #require(edited.finds.first { $0.value == "D1234567" })
        let saved = try #require(edited.confirm(first.id, as: VaultModel.Draft(first)))
        var draft = VaultModel.Draft(try #require(edited.entries.first { $0.id == saved }))
        draft.value = "D1234568"
        #expect(await edited.update(saved, to: draft))
        #expect(edited.finds.isEmpty)
        #expect(edited.undoCorrection())
        #expect(edited.finds.map(\.value) == ["D1234568"])
        #expect(edited.rows.first { $0.value == "D1234568" }?.documents.map(\.path) == [Self.letter])
    }

    @Test func aReadSinceTheCorrectionIsNotUndoneOver() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let model = rig.model()
        // The card is marked read, and is not opened again while it is unchanged.
        var card = VaultReadAsTests.documents([Self.card: VaultFixtures.licensePage])
        card.stamps = [Self.card: "1"]
        await model.readDocuments(with: card)
        let id = try Self.corrected(model, try #require(model.finds.first), to: "D1234568")
        #expect(model.lastCorrection != nil)
        // A letter printing the corrected number, read before Undo.
        var both = VaultReadAsTests.documents([Self.card: VaultFixtures.licensePage, Self.letter: Self.letterPage])
        both.stamps = [Self.card: "1", Self.letter: "1"]
        await model.readDocuments(with: both)
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path).contains(Self.letter) == true)
        #expect(model.lastCorrection == nil, "Undo was still offered over what the read took")
        #expect(!model.undoCorrection())
        #expect(model.rows.first { $0.id == id }?.documents.map(\.path).contains(Self.letter) == true, "the letter went")

        // A copy printing the old number, read before Undo: it waits once, not twice.
        let otherRig = try Rig(); defer { otherRig.cleanUp() }
        let (other, waiting) = try await Self.waiting(otherRig)
        _ = try Self.corrected(other, waiting, to: "D1234568")
        await other.notesWritten()
        let copy = VaultReadAsTests.documents([Self.card: VaultFixtures.licensePage, Self.letter: VaultFixtures.licensePage + ["Copy"]])
        other.fileContents = { [copy] in await copy.contentKey(of: $0) }
        await other.readDocuments(with: copy)
        #expect(!other.undoCorrection())
        #expect(other.finds.filter { $0.value == "D1234567" }.count == 1)

        // A read that takes nothing for either number leaves Undo as it was: the card, unchanged,
        // is not opened again, and the other file prints another number.
        let quietRig = try Rig(); defer { quietRig.cleanUp() }
        let quiet = quietRig.model()
        var stamped = VaultReadAsTests.documents([Self.card: VaultFixtures.licensePage])
        stamped.stamps = [Self.card: "1"]
        await quiet.readDocuments(with: stamped)
        _ = try Self.corrected(quiet, try #require(quiet.finds.first), to: "D1234568")
        var unrelated = VaultReadAsTests.documents([Self.card: VaultFixtures.licensePage, VaultReadAsTests.relative:
            VaultReadAsTests.shwetaPage.map { $0.replacingOccurrences(of: "D1234567", with: "S7654321") }])
        unrelated.stamps = [Self.card: "1", VaultReadAsTests.relative: "1"]
        await quiet.readDocuments(with: unrelated)
        #expect(quiet.finds.map(\.value) == ["S7654321"])
        #expect(quiet.lastCorrection != nil)
        #expect(quiet.undoCorrection())
    }

    @Test func theEditorFindsTheSavedIDANumberAlreadyIs() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport, VaultModelTests.memberID])
        let model = rig.model()
        await model.opened()
        #expect(model.savedRow(holding: "a 3829-1647", excluding: nil)?.id == VaultModelTests.passport.id)
        #expect(model.savedRow(holding: "A38291647", excluding: VaultModelTests.passport.id) == nil, "an ID is not its own duplicate")
        #expect(model.savedRow(holding: "", excluding: nil) == nil)
        #expect(model.savedRow(holding: "Z0000000", excluding: nil) == nil)
    }
}
