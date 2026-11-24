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
