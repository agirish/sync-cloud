import Foundation
import Testing
@testable import Sync

/// Two copies of SyncCloud on one Vault (VT108): the installed app and a build beside it, each with
/// its own model over the same sealed file. A save over a file the other saved since is refused,
/// and the refused copy reads the Vault again, so nothing the other saved is lost.
@MainActor
@Suite struct VaultTwoCopiesTests {
    typealias Rig = VaultModelTests.Rig

    @Test func aSaveOverAnotherCopysSaveIsRefusedAndTheVaultIsReadAgain() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let first = rig.model(), second = rig.model()
        await first.opened()
        await second.opened()

        let library = try #require(first.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")))
        // The second still holds the Vault as it opened: saved from it, the library card would go.
        #expect(second.add(VaultModel.Draft(title: "Gym card", value: "GYM0000002")) == nil)
        #expect(second.notice == VaultModel.message(for: .changedElsewhere))
        #expect(Set(second.entries.map(\.id)) == [VaultModelTests.passport.id, library], "it reads the Vault again")
        #expect(try rig.store.load().map(\.title).sorted() == ["Library card", "Passport"])

        // Made again, it lands beside the first copy's.
        #expect(second.add(VaultModel.Draft(title: "Gym card", value: "GYM0000002")) != nil)
        #expect(second.notice == nil)
        #expect(try rig.store.load().map(\.title).sorted() == ["Gym card", "Library card", "Passport"])

        // And the first, now behind, is refused in turn rather than dropping the gym card.
        #expect(await first.delete(library) == false)
        #expect(try rig.store.load().count == 3)
        #expect(first.entries.count == 3)
    }

    @Test func aCopyThatOpenedAnEmptyVaultIsRefusedOnceTheOtherSavedOne() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let first = rig.model(), second = rig.model()
        await first.opened()
        await second.opened()
        #expect(first.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) != nil)
        #expect(second.add(VaultModel.Draft(title: "Gym card", value: "GYM0000002")) == nil)
        #expect(second.entries.map(\.title) == ["Library card"])
    }

    /// Confirmed in both: the second's is refused, its find leaves To Confirm with the first's
    /// saved ID read in, and nothing is saved twice.
    @Test func aConfirmRefusedLeavesNothingWaitingTheOtherSaved() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let first = rig.model(), second = rig.model()
        await first.opened()
        await second.opened()
        let pages = VaultFakeDocuments(pages: ["/docs/notice.pdf": VaultToConfirmTests.noticePage])
        await first.readDocuments(with: pages)
        await second.readDocuments(with: pages)
        let one = try #require(first.finds.first { $0.title == "USCIS receipt number" })
        let two = try #require(second.finds.first { $0.title == "USCIS receipt number" })
        #expect(first.confirm(one.id, as: VaultModel.Draft(one)) != nil)

        #expect(second.confirm(two.id, as: VaultModel.Draft(two)) == nil)
        #expect(second.notice == VaultModel.message(for: .changedElsewhere))
        #expect(second.entries.contains { $0.value == one.value })
        #expect(!second.finds.contains { $0.value == one.value }, "saved by the first, it no longer waits here")
        #expect(try rig.store.load().filter { $0.value == one.value }.count == 1)
    }

    /// Changed into a file this copy cannot read: what it cannot read is said, not that it shows
    /// the Vault as it is.
    @Test func aChangeThatCannotBeReadSaysSo() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.passport])
        let model = rig.model()
        await model.opened()
        try Data("not a vault".utf8).write(to: rig.scratch.fileURL)
        #expect(model.add(VaultModel.Draft(title: "Library card", value: "LIB0000001")) == nil)
        #expect(model.notice == VaultModel.message(for: .unreadableFile))
        #expect(try Data(contentsOf: rig.scratch.fileURL) == Data("not a vault".utf8), "nothing written over it")
    }

    /// VT112: both copies edit one ID. The second's editor opened before the first saved, so its
    /// save is refused once, saying why, not written over the first's edit; saving again, from the
    /// ID as it now is (as the panel moves it on), replaces it on purpose.
    @Test func anEditOverAnotherCopysEditOfTheSameIDIsRefusedOnce() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        let id = VaultModelTests.mortgage.id
        let first = rig.model(), second = rig.model()
        await first.opened()
        await second.opened()
        let opened = try #require(second.entry(id: id))

        var theirs = VaultModel.Draft(opened)
        theirs.note = "Refinanced in 2026"
        #expect(await first.update(id, to: theirs, editedFrom: try #require(first.entry(id: id))))

        var mine = VaultModel.Draft(opened)
        mine.title = "Home loan"
        #expect(await second.update(id, to: mine, editedFrom: opened) == false)
        #expect(second.notice == VaultModel.editedElsewhere, "said once, and why")
        #expect(try rig.store.load().first?.note == "Refinanced in 2026", "the first's edit stands")

        #expect(await second.update(id, to: mine, editedFrom: try #require(second.entry(id: id))))
        #expect(try rig.store.load().first?.title == "Home loan")
    }

    /// Another copy's change to a different ID, or to what the editor does not show: refused by the
    /// file once (VT108), then saved; never the edit message.
    @Test func anEditAfterAnotherCopysOtherChangeSavesAfterTheFilesRefusal() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage, VaultModelTests.passport])
        let first = rig.model(), second = rig.model()
        await first.opened()
        await second.opened()
        let opened = try #require(second.entry(id: VaultModelTests.mortgage.id))
        first.pin(VaultModelTests.passport.id, .older)
        var mine = VaultModel.Draft(opened)
        mine.note = "Escrow"
        #expect(await second.update(opened.id, to: mine, editedFrom: opened) == false)
        #expect(second.notice == VaultModel.message(for: .changedElsewhere))
        #expect(await second.update(opened.id, to: mine, editedFrom: opened))
    }

    /// One copy alone: a row's menu used on the ID being edited is this copy's own change. The save
    /// is not refused, and keeps the pin the menu chose (the editor shows none).
    @Test func thisCopysOwnChangeNeverRefusesItsEditAndThePinStays() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.seed([VaultModelTests.mortgage])
        let model = rig.model()
        await model.opened()
        let opened = try #require(model.entry(id: VaultModelTests.mortgage.id))
        model.pin(opened.id, .older)
        var draft = VaultModel.Draft(opened)
        draft.note = "Escrow"
        #expect(await model.update(opened.id, to: draft, editedFrom: opened))
        #expect(model.notice == nil)
        #expect(model.entry(id: opened.id)?.pin == .older, "the menu's choice is not undone")
    }

    @Test func aStoreSavesOverOnlyTheFileItExpects() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let made = try rig.store.save([VaultModelTests.passport], expecting: .absent)
        let after = try rig.store.save([VaultModelTests.passport, VaultModelTests.mortgage], expecting: made)
        #expect(throws: VaultError.changedElsewhere) { try rig.store.save([VaultModelTests.passport], expecting: made) }
        #expect(throws: VaultError.changedElsewhere) { try rig.store.save([], expecting: .absent) }
        #expect(try rig.store.load().count == 2, "nothing was written over it")
        #expect(try rig.store.loadRecordsAndState().onDisk == after)
        // A restore expects nothing, and writes what it was asked to.
        try rig.store.save([VaultModelTests.passport, VaultModelTests.mortgage, VaultModelTests.memberID])
    }
}
