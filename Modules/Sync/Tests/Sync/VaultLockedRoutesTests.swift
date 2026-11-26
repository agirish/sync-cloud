import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// Every route that changes or shows an ID, run once the Vault has let its numbers go (VT29):
/// none succeeds, none asks for a proof, and neither sealed file changes by a byte. And a route
/// whose proof is answered after the Vault locked meanwhile does nothing. Every value is made up.
@MainActor
@Suite struct VaultLockedRoutesTests {
    typealias Rig = VaultModelTests.Rig

    @Test func noRouteChangesOrShowsAnythingOnceTheNumbersAreLetGo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(VaultNameCorrectionTests.root, in: rig.defaults)
        rig.auth.answer = .allowed
        let model = rig.model()
        model.people = [Person(id: "divit", displayName: "Divit")]
        await model.opened()
        #expect(await model.unlock())
        await model.readDocuments(with: VaultAccountModelTests.PlannedDocuments(pages: VaultNameCorrectionTests.pages))
        let waiting = try #require(model.finds.first { $0.value == "VSP99887766" })
        let other = try #require(model.finds.first { $0.value == "KP12345678" })
        let find = try #require(model.finds.first { $0.value == "XZB123456789" })
        let saved = try #require(model.confirm(find.id, as: VaultModel.Draft(find)))
        let entry = try #require(model.entries.first { $0.id == saved })
        let section = try #require(model.peopleSections.first)

        model.systemLocked()
        #expect(model.contents != .loaded)
        rig.auth.answer = .cancelled        // a proof asked for is refused
        let vault = try Data(contentsOf: rig.store.fileURL)
        let reading = try Data(contentsOf: rig.store.readingFileOnDisk)
        let copied = rig.copied
        let proofs = rig.auth.reasons.count

        model.assign(saved, to: .household)
        model.pin(saved, .older)
        model.setGeo(saved, to: .india)
        model.setKind(saved, to: .builtIn(.health))
        model.readFrom(saved, copy: VaultNameCorrectionTests.root + "/Health/Dental/ID Cards/card.pdf")
        model.keepSaved(saved)
        model.setAside(waiting.id)
        #expect(model.setRole(.goesBy, of: "Dlvit Girish", for: "divit") == 0)
        var draft = VaultModel.Draft(entry)
        draft.note = "changed"
        #expect(await model.update(saved, to: draft) == false, "Edit")
        #expect(await model.delete(saved) == false, "Remove")
        #expect(await model.useReread(saved) == false, "Use the New Reading")
        #expect(model.confirm(other.id, as: VaultModel.Draft(other)) == nil, "Confirm")
        #expect(await model.show(saved) == false, "Show")
        #expect(await model.copy(saved) == false, "Copy")
        #expect(await model.copy("XZB123456789", for: saved) == false, "Copy a detail")
        #expect(await model.copyPerson(section.id, numbers: true) == false, "Copy a person's IDs")
        #expect(await model.copyBirth(Date(timeIntervalSince1970: 0), in: section) == false, "Copy a date of birth")

        #expect(try Data(contentsOf: rig.store.fileURL) == vault, "the Vault's file changed while its numbers were let go")
        #expect(try Data(contentsOf: rig.store.readingFileOnDisk) == reading, "the reading file changed while its numbers were let go")
        #expect(rig.copied == copied, "something reached the clipboard")
        #expect(model.entries.isEmpty && model.finds.isEmpty, "a route brought the numbers back")
        #expect(rig.auth.reasons.count == proofs, "a route asked for a proof: \(rig.auth.reasons.suffix(rig.auth.reasons.count - proofs))")
    }

    /// Answers yes, but locks the Vault while it is asked, as sleep or Lock Now can.
    final class LocksWhileAsked: VaultAuthenticating, @unchecked Sendable {
        weak var model: VaultModel?
        func prove(reason: String) async -> VaultProof {
            await MainActor.run { model?.systemLocked() }
            return .allowed
        }
    }

    /// A proof answered after the Vault locked opens nothing: each route looks again after it.
    @Test func aProofAnsweredAfterALockDoesNothing() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let entry = VaultEntry(title: "Passport", value: "Z0000009", personID: "divit", addedAt: VaultLockTests.t0)
        try rig.seed([entry])
        rig.auth.answer = .allowed
        let auth = LocksWhileAsked()
        let model = VaultModel(store: rig.store, authenticator: auth, defaults: rig.defaults,
                               clock: { VaultLockTests.t0 }, copyToPasteboard: { _ in Issue.record("a number was copied") })
        auth.model = model
        model.people = [Person(id: "divit", displayName: "Divit")]
        await model.opened()
        // It asks as it opens, and the proof locks it.
        let vault = try Data(contentsOf: rig.store.fileURL)
        #expect(await model.copy(entry.id) == false, "Copy")
        await model.opened()
        var draft = VaultModel.Draft(entry)
        draft.note = "changed"
        #expect(await model.update(entry.id, to: draft) == false, "Edit")
        await model.opened()
        if let section = model.peopleSections.first {
            #expect(await model.copyPerson(section.id, numbers: true) == false, "Copy a person's IDs")
        }
        #expect(try Data(contentsOf: rig.store.fileURL) == vault)
    }
}
