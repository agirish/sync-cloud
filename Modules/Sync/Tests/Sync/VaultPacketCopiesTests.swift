import Foundation
import Testing
@testable import Sync

/// VT107 step 3 (owner): a copy filed in a packet (a petition's, an application's) is not opened
/// while it is as it was when last read whole and every number it gave is held from a document in
/// its own kind's folder. Every number is made up.
@MainActor
@Suite struct VaultPacketCopiesTests {
    typealias Rig = VaultModelTests.Rig
    typealias Shelf = VaultShelf

    static let root = "/Users/anna/Documents"
    static let home = root + "/Immigration/Passport/Anna/scan.pdf"
    static let packet = root + "/Immigration/H-1B/Petition/passport.pdf"
    static let page = VaultToConfirmTests.passportPage

    /// A Vault that has read the passport from its own folder and the petition's copy of it.
    static func rig(copy: [String] = page) async throws -> (rig: Rig, model: VaultModel, shelf: Shelf) {
        let rig = try Rig()
        VaultReadFolders.add(root, in: rig.defaults)
        let shelf = Shelf([home: page, packet: copy])
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: shelf)
        #expect(Set(shelf.opened) == [home, packet], "both read the first time")
        shelf.forgetOpened()
        return (rig, model, shelf)
    }

    /// After a change of rules, as the app runs it: the Refresh that follows opens each ID's own
    /// document, and Discover More comes next. The shelf is read in the app's order (originals
    /// first) and what it opened is forgotten before Discover More.
    static func refreshedUnderNewRules(_ rig: Rig, _ model: VaultModel, _ shelf: Shelf,
                                       before: () -> Void = {}) async throws -> VaultModel {
        let again = try await underNewRules(rig, model)
        before()
        await again.readDocuments(with: Planned(shelf), scope: .refresh())
        shelf.forgetOpened()
        return again
    }

    @Test func aPacketsCopyOfANumberHeldFromItsOwnFolderIsNotOpened() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let again = try await Self.refreshedUnderNewRules(rig, model, shelf)
        await again.readDocuments(with: Planned(shelf))
        #expect(shelf.opened.isEmpty, "the petition's copy was opened")
        #expect(again.finds.count == 1, "the passport is still there")
        // Not marked read: the next Discover More weighs it again, and passes it over again.
        await again.readDocuments(with: Planned(shelf))
        #expect(shelf.opened.isEmpty)
    }

    @Test func aChangedCopyIsOpened() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let again = try await Self.refreshedUnderNewRules(rig, model, shelf)
        shelf.write(Self.packet, Self.page)
        await again.readDocuments(with: Planned(shelf))
        #expect(shelf.opened == [Self.packet])
    }

    /// A copy passed over is not marked read, but Refresh still sees it change, by the size and
    /// date it was last read at, and offers Discover More for it (VT107 step 4).
    @Test func refreshSeesAPassedOverCopyChange() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        // Saved: its facts name both documents, so the copy stays one of them.
        let find = try #require(model.finds.first)
        _ = try #require(model.confirm(find.id, as: model.confirmationDraft(find)))
        let again = try await Self.refreshedUnderNewRules(rig, model, shelf)
        await again.readDocuments(with: Planned(shelf))
        again.dismissDiscover()
        try #require(again.otherSources.contains(Self.packet), "still one of the passport's documents")
        shelf.write(Self.packet, Self.page)
        await again.readDocuments(with: Planned(shelf), scope: .refresh())
        #expect(again.needsDiscover && again.copiesChanged)
    }

    /// With the original gone, the copy is the only document that holds the number.
    @Test func aCopyWhoseOriginalIsGoneIsOpened() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let again = try await Self.refreshedUnderNewRules(rig, model, shelf) { shelf.remove(Self.home) }
        await again.readDocuments(with: Planned(shelf))
        #expect(shelf.opened == [Self.packet])
        #expect(again.finds.count == 1, "read from the copy")
    }

    /// "All its numbers held" is the test, never the folder alone: a packet can be the only copy
    /// of another paper. Here the copy is the I-94's own document, which Refresh opens.
    @Test func aCopyHoldingANumberNoOwnFolderHoldsIsOpened() async throws {
        let (rig, model, shelf) = try await Self.rig(copy: Self.page + ["Admission (I-94) Record Number: 123456789 A1"])
        defer { rig.cleanUp() }
        #expect(model.finds.count == 2)
        let again = try await Self.underNewRules(rig, model)
        await again.readDocuments(with: Planned(shelf))
        #expect(Set(shelf.opened) == [Self.home, Self.packet])
        #expect(again.finds.count == 2)
    }

    /// Two packets' copies hold each other's number, but neither is the original: both are opened.
    @Test func copiesHeldOnlyByEachOtherAreOpened() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let other = Self.root + "/Immigration/H-4/Application/passport.pdf"
        let shelf = Shelf([Self.packet: Self.page, other: Self.page])
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: shelf)
        shelf.forgetOpened()
        let again = try await Self.underNewRules(rig, model)
        await again.readDocuments(with: Planned(shelf))
        #expect(Set(shelf.opened) == [Self.packet, other])
    }

    /// A file in a packet that gave nothing is no copy of anything held: it is opened.
    @Test func aPacketFileThatGaveNothingIsOpened() async throws {
        let (rig, model, shelf) = try await Self.rig(copy: ["Cover letter, nothing to see"]); defer { rig.cleanUp() }
        let again = try await Self.refreshedUnderNewRules(rig, model, shelf)
        await again.readDocuments(with: Planned(shelf))
        #expect(shelf.opened == [Self.packet])
    }

    /// Read Everything Again reads every file, as if for the first time: copies too.
    @Test func readEverythingAgainOpensTheCopy() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        await model.readDocuments(with: Planned(shelf), again: true)
        #expect(Set(shelf.opened) == [Self.home, Self.packet])
    }

    /// The copy an ID is read from (Read from This Copy) is never passed over, even when Discover
    /// More runs before any Refresh (the 2026-11-25 review).
    @Test func theCopyChosenToReadFromIsNeverPassedOver() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let row = try #require(model.rows.first { $0.category == .passport })
        try #require(row.sourceChoices == [Self.packet])
        model.readFrom(row.id, copy: Self.packet)
        let again = try await Self.underNewRules(rig, model)
        await again.readDocuments(with: Planned(shelf))
        #expect(Set(shelf.opened) == [Self.home, Self.packet])
    }

    /// Not for This ID opens the copy again: what it gave before no longer speaks for it.
    @Test func notForThisIDOpensTheCopyAgain() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let find = try #require(model.finds.first)
        let saved = try #require(model.confirm(find.id, as: model.confirmationDraft(find)))
        model.fileContents = { "contents of " + $0.lastPathComponent }
        try #require(await model.notForThisID(saved, path: Self.packet))
        await model.readDocuments(with: Planned(shelf))
        #expect(shelf.opened.contains(Self.packet))
    }

    /// Seals what was read as an older build would have, and opens the Vault again.
    static func underNewRules(_ rig: Rig, _ model: VaultModel) async throws -> VaultModel {
        model.systemLocked()
        var state = try #require(rig.store.readingOnDisk())
        state.version = VaultReading.version - 1
        try rig.store.writeReadingOnDisk(state)
        let again = rig.model()
        await again.opened()
        #expect(again.finds.isEmpty, "what the older rules read is let go")
        return again
    }

    /// What the copy gave is kept across a change of rules, which lets go of everything read, so
    /// the copy is known before it is opened: neither the Refresh that follows nor Discover More
    /// opens it, as the app runs them (VT107 steps 3 and 4).
    @Test func afterAChangeOfRulesTheCopyIsKnownBeforeItIsOpened() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let again = try await Self.underNewRules(rig, model)
        await again.readDocuments(with: Planned(shelf), scope: .refresh())
        #expect(shelf.opened == [Self.home], "Refresh opens the passport's own document")
        shelf.forgetOpened()
        await again.readDocuments(with: Planned(shelf))
        #expect(shelf.opened.isEmpty, "Discover More opens neither: the copy is held from home")
        #expect(again.finds.count == 1)
    }

    /// A saved ID's facts name the document it was saved from; that home scan, replaced since by
    /// a renewal, no longer holds the number, so the packet's copy, the only one that does, is
    /// opened (the 2026-11-25 review).
    @Test func aSavedNumberWhoseHomeScanWasReplacedIsReadFromItsCopy() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let find = try #require(model.finds.first)
        _ = try #require(model.confirm(find.id, as: model.confirmationDraft(find)))
        shelf.write(Self.home, ["Nothing on this page now"])
        let again = try await Self.underNewRules(rig, model)
        await again.readDocuments(with: Planned(shelf), scope: .refresh())
        shelf.forgetOpened()
        await again.readDocuments(with: Planned(shelf))
        #expect(shelf.opened.contains(Self.packet), "the only copy that holds it was passed over")
    }

    /// An original set down in a TMP folder inside the passport's own folder is set down, not
    /// filed (VT50): it holds nothing at home for the packet's copy, which is opened.
    @Test func anOriginalSetDownAtHomeHoldsNothingForAPacketsCopy() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let setDown = Self.root + "/Immigration/Passport/Anna/TMP/scan.pdf"
        let shelf = Shelf([setDown: Self.page, Self.packet: Self.page])
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: shelf)
        try #require(model.refreshSources == [setDown], "the set-down original is the passport's own document")
        shelf.forgetOpened()
        let again = try await Self.underNewRules(rig, model)
        await again.readDocuments(with: Planned(shelf))
        #expect(Set(shelf.opened) == [setDown, Self.packet])
    }

    /// Every number the copy gave must be held from home, not one: here its I-94 number is held
    /// only from a printout in a folder that is not an I-94's own, so the copy is opened.
    @Test func aCopyWithOneNumberNotHeldAtHomeIsOpened() async throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        VaultReadFolders.add(Self.root, in: rig.defaults)
        let i94 = ["Admission (I-94) Record Number: 123456789 A1"]
        let printout = Self.root + "/Immigration/Scans/i94.pdf"
        let shelf = Shelf([Self.home: Self.page, Self.packet: Self.page + i94, printout: i94])
        let model = rig.model()
        await model.opened()
        await model.readDocuments(with: shelf)
        try #require(!model.refreshSources.contains(Self.packet), "the copy is neither ID's own document")
        shelf.forgetOpened()
        let again = try await Self.underNewRules(rig, model)
        await again.readDocuments(with: Planned(shelf))
        #expect(shelf.opened.contains(Self.packet))
    }

    /// An original in a folder no longer read is not seen by this read, though it is still on
    /// disk: it holds nothing, and the copy is opened.
    @Test func anOriginalOutsideTheReadFoldersHoldsNothing() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        let again = try await Self.refreshedUnderNewRules(rig, model, shelf)
        VaultReadFolders.remove(Self.root, in: rig.defaults)
        VaultReadFolders.add(Self.root + "/Immigration/H-1B", in: rig.defaults)
        // What a walk of the one folder still read finds.
        let walked = Shelf([Self.packet: Self.page])
        await again.readDocuments(with: Planned(walked))
        #expect(walked.opened == [Self.packet])
    }

    /// A Forget offers everything again: the copies too.
    @Test func afterAForgetTheCopyIsOpened() async throws {
        let (rig, model, shelf) = try await Self.rig(); defer { rig.cleanUp() }
        await model.opened()
        #expect(model.forgetSetAside())
        await model.readDocuments(with: shelf)
        #expect(Set(shelf.opened) == [Self.home, Self.packet])
    }

    /// The shelf, read in the order the app's reader reads (``VaultReadPlan``).
    final class Planned: VaultDocumentReading, @unchecked Sendable {
        let shelf: Shelf
        init(_ shelf: Shelf) { self.shelf = shelf }
        var followsReadPlan: Bool { true }
        func files() async -> [URL] { await shelf.files() }
        func pages(in file: URL) async -> [[String]] { await shelf.pages(in: file) }
        func stamp(of file: URL) -> String? { shelf.stamp(of: file) }
        func modified(of file: URL) -> Date? { nil }
        func exists(_ file: URL) -> Bool { shelf.exists(file) }
    }

    /// The log says how many, never which.
    @Test func theReadsLineCountsTheCopiesPassedOver() {
        var tally = VaultReadTally()
        tally.documents = 3
        tally.copiesPassedOver = 2
        #expect(tally.summary(seconds: 5).contains(", 2 copies in packets passed over"))
    }
}
