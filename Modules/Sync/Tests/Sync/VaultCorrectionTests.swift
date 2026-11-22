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
        #expect(model.undoCorrection())
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
