import Testing
import Foundation
import Events
@testable import Sync

/// Two ways the duplicate removal path told the user something untrue about a destructive action.
///
/// **The undo promise.** `deleteItems` gets undoability right — it registers a restore-undo only
/// for items that reached the Trash, and flags its own banner `undoable: false` otherwise — but it
/// returned a bare `Int`, so the duplicates callers replaced that banner with an unconditional
/// "press ⌘Z to undo". On a Trash-less volume (exFAT, most SMB shares) that promise is printed
/// after files were destroyed permanently, and ⌘Z then reverses whatever was previously on top of
/// the stack.
///
/// **The same-size rewrite.** The resolve-time drift check compared byte size alone, so any
/// same-length edit — 2025 to 2026 — compared equal to the scanned copy and was trashed as
/// redundant. The merge path in the same file had already rejected that reasoning.
@Suite struct DuplicateRemovalHonestyTests {

    @MainActor
    private func makeManager(_ fm: MockFileManager) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        return manager
    }

    private func stub(size: Int, modified: Date?) -> MockFileManager.FileStub {
        var attrs: [FileAttributeKey: Any] = [.size: size]
        if let modified { attrs[.modificationDate] = modified }
        return MockFileManager.FileStub(isDirectory: false, attributes: attrs, contents: nil)
    }

    private func group(keeper: String, redundant: String, reclaim: Int) -> DuplicateGroup {
        let k = DuplicateCopy(id: keeper, name: (keeper as NSString).lastPathComponent, isDirectory: false,
                              size: 1000, itemCount: 1, modificationDate: Date(timeIntervalSince1970: 1_000),
                              uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant, name: (redundant as NSString).lastPathComponent, isDirectory: false,
                              size: 1000, itemCount: 1, modificationDate: Date(timeIntervalSince1970: 1_000),
                              uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false)
        return DuplicateGroup(matchType: .identical, name: k.name, isDirectory: false,
                              copies: [k, r], reclaimableBytes: reclaim)
    }

    // MARK: The undo promise

    /// The headline: on a Trash-less volume the copies are destroyed permanently, and the banner
    /// must not offer an undo that would fire at an unrelated operation.
    @MainActor
    @Test func aPermanentRemovalDoesNotPromiseUndo() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true                     // no Trash on this volume
        let manager = makeManager(mockFM)
        manager.permanentDeleteConfirmer = { _ in true }  // the user confirms the permanent delete
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        let ok = await manager.resolveDuplicateGroup(g)

        #expect(ok == true)
        #expect(mockFM.virtualDisk["/b/x"] == nil, "the copy was destroyed permanently")
        #expect(manager.banner?.message.contains("Reclaimed") == true)
        #expect(manager.banner?.message.contains("⌘Z") != true,
                "nothing was registered for undo, so ⌘Z would reverse an unrelated operation")
        #expect(manager.banner?.isUndoable != true)
    }

    /// The other direction: a normal Trash removal still offers the undo it genuinely has, or the
    /// fix would just have removed a working affordance.
    @MainActor
    @Test func aTrashedRemovalStillPromisesUndo() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        let ok = await manager.resolveDuplicateGroup(g)

        #expect(ok == true)
        #expect(mockFM.virtualDisk["/b/x"] == nil)
        #expect(manager.banner?.message.contains("⌘Z") == true)
        #expect(manager.banner?.isUndoable == true)
    }

    /// **A partial batch's offer has to EXPIRE like a whole one's.** The two sibling banners pass
    /// `undoable:`; this one conditioned only its sentence on `outcome.isUndoable` and left the
    /// flag at its default. `invalidateUndoableBanner` reads the flag, not the sentence, so the
    /// offer survived the undo stack moving on — and once another operation registers, "Press ⌘Z
    /// to undo" is an instruction to reverse the WRONG step. That is the same misdirected shortcut
    /// `DeleteOutcome` exists to prevent, reached by a different route.
    ///
    /// Warnings are normally left standing, deliberately, so an error cannot be cleared by an
    /// unrelated op — which is precisely why severity and undoability are separate parameters.
    @MainActor
    @Test func aPartialBatchThatOffersUndoIsMarkedUndoableSoTheOfferCanExpire() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        // Two eligible groups, one of whose keepers is gone: it is filtered out of `batch` while
        // staying in `eligible`, which is what takes the partial branch. The surviving group
        // trashes normally, so the outcome genuinely IS undoable — without that this would be
        // asserting about the no-offer case.
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/y"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        // …and NOT "/a/y": the second group's keeper never existed.
        let present = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        let keeperGone = group(keeper: "/a/y", redundant: "/b/y", reclaim: 1000)
        manager.duplicateGroups = [present, keeperGone]

        await manager.applyRecommendedDuplicates([present, keeperGone])

        // The premise: this is the partial branch, and it did make an offer.
        let message = try #require(manager.banner?.message)
        #expect(message.contains("of 2 groups"),
                "not the partial branch — the banner reads “\(message)”, so the flag below is not the one under test")
        #expect(message.contains("⌘Z"),
                "the partial banner made no undo offer at all, so there is nothing here that needs to expire")
        // THE INVARIANT: an offer that is made must also be retractable.
        #expect(manager.banner?.isUndoable == true,
                "the banner offers ⌘Z but is not marked undoable, so invalidateUndoableBanner leaves it up after the stack moves on and the offer starts pointing at another operation")
    }

    // MARK: The outcome type itself

    @Test func theOutcomeSeparatesRecoverableFromPermanent() {
        #expect(DeleteOutcome(trashed: 3).isUndoable)
        #expect(DeleteOutcome(trashed: 3).removed == 3)
        // A mixed batch is NOT undoable: the restore-undo covers only the trashed subset, so an
        // offered Undo would silently leave the permanent deletions in place.
        #expect(!DeleteOutcome(trashed: 2, permanentlyDeleted: 1).isUndoable)
        #expect(DeleteOutcome(trashed: 2, permanentlyDeleted: 1).removed == 3)
        #expect(!DeleteOutcome(permanentlyDeleted: 2).isUndoable)
        #expect(!DeleteOutcome().isUndoable, "removing nothing is not something to undo")
        // Declined items were never removed, by either route.
        #expect(DeleteOutcome(declined: 4).removed == 0)
    }

    // MARK: The same-size rewrite

    /// `2025` → `2026`: identical length, different bytes, later mtime. Size alone read this as
    /// the copy the scan grouped and trashed it.
    @MainActor
    @Test func aSameSizeRewriteOfACopyIsRefused() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        // Same size as the scan recorded, edited since.
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 9_999))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        let ok = await manager.resolveDuplicateGroup(g)

        #expect(ok == false)
        #expect(mockFM.virtualDisk["/b/x"] != nil, "an edited copy must never be trashed as redundant")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("changed since it was scanned") == true)
    }

    /// And the guard must not over-refuse an untouched pair, or Tidy stops working entirely.
    @MainActor
    @Test func anUntouchedPairStillResolves() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        let when = Date(timeIntervalSince1970: 1_000)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: when)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: when)
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        #expect(await manager.resolveDuplicateGroup(g) == true)
        #expect(mockFM.virtualDisk["/b/x"] == nil)
    }

    /// A scan that recorded no date still resolves on size alone — the fallback that keeps every
    /// pre-existing group working rather than refusing it for lack of a baseline.
    @MainActor
    @Test func aPairWithNoRecordedDateStillResolvesOnSize() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: nil)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: nil)
        let k = DuplicateCopy(id: "/a/x", name: "x", isDirectory: false, size: 1000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: "/b/x", name: "x", isDirectory: false, size: 1000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false)
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [k, r], reclaimableBytes: 1000)
        manager.duplicateGroups = [g]

        #expect(await manager.resolveDuplicateGroup(g) == true)
        #expect(mockFM.virtualDisk["/b/x"] == nil)
    }

    // MARK: What the batch says when it removes nothing, and what it claims it freed

    /// **"Nothing to remove" is not "something changed."** Every empty batch produced the same
    /// warning — "These groups changed since they were scanned — rescan before removing copies" —
    /// and drift is only one of the two ways to get one. A group whose every redundant copy is
    /// PROTECTED contributes no paths while nothing about it has changed at all, so a rescan finds
    /// exactly the same group and the advice sends the user around a loop.
    @MainActor
    @Test func aBatchOfProtectedCopiesIsNotReportedAsDrift() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))

        let keeper = DuplicateCopy(id: "/a/x", name: "x", isDirectory: false, size: 1000, itemCount: 1,
                                   modificationDate: Date(timeIntervalSince1970: 1_000),
                                   uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let protectedCopy = DuplicateCopy(id: "/b/x", name: "x", isDirectory: false, size: 1000,
                                          itemCount: 1, modificationDate: Date(timeIntervalSince1970: 1_000),
                                          uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false,
                                          isProtectedFromRemoval: true)
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [keeper, protectedCopy], reclaimableBytes: 1000)
        try #require(g.recommendedRemovalPaths.isEmpty, "the fixture no longer produces an empty removal list")
        try #require(g.isRecommendedForBatch, "the fixture is not eligible, so it never reaches the banner under test")
        manager.duplicateGroups = [g]

        await manager.applyRecommendedDuplicates([g])

        let said = try #require(manager.banner?.message)
        #expect(!said.contains("changed since they were scanned"),
                "a group nothing has touched was reported as drifted — a rescan finds the same thing: “\(said)”")
        #expect(said.contains("protected"), "the banner does not say why nothing was removed: “\(said)”")
        // And both copies are still there — nothing was trashed on the way to that message.
        #expect(mockFM.virtualDisk["/b/x"] != nil)
    }

    /// **A banner that names a cause must have checked it.** The empty-batch message says every
    /// copy is protected — but an empty removal list is equally what a group carrying no redundant
    /// copies at all produces, and `applyRecommendedDuplicates` is `public` over a `DuplicateGroup`
    /// initializer that validates nothing, so what counts as a "group" is the caller's to decide.
    ///
    /// Measured before the fix: a one-copy group, with nothing protected anywhere, was told that
    /// every copy in it was protected — the same class of mistake as the drift wording it replaced,
    /// one state over.
    @MainActor
    @Test func aGroupWithNothingToRemoveIsNotCalledProtected() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        // One copy, and it is the keeper: no redundant copies, so nothing is protected.
        let only = DuplicateCopy(id: "/a/x", name: "x", isDirectory: false, size: 1000, itemCount: 1,
                                 modificationDate: Date(timeIntervalSince1970: 1_000),
                                 uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let g = DuplicateGroup(matchType: .identical, name: "x", isDirectory: false,
                               copies: [only], reclaimableBytes: 0)
        try #require(g.redundantCopies.isEmpty, "the fixture gained a redundant copy — it no longer reproduces the case")
        try #require(g.recommendedRemovalPaths.isEmpty)
        try #require(g.isRecommendedForBatch, "the fixture is ineligible, so it never reaches the banner")
        manager.duplicateGroups = [g]

        await manager.applyRecommendedDuplicates([g])

        let said = try #require(manager.banner?.message)
        #expect(!said.contains("protected"),
                "a group with no redundant copies was told every copy in it is protected: “\(said)”")
        #expect(!said.contains("changed since they were scanned"),
                "…and it is not drift either: “\(said)”")
        #expect(said.contains("Nothing to remove"), "the banner stopped saying nothing was removed: “\(said)”")
    }

    /// …and the drift wording survives for the case it was written for, so the fix above is a
    /// narrowing rather than a removal.
    @MainActor
    @Test func aDriftedBatchStillSaysToRescan() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        // The redundant copy was rewritten since the scan — a different size is a KNOWN mismatch.
        mockFM.virtualDisk["/b/x"] = stub(size: 2000, modified: Date(timeIntervalSince1970: 1_000))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        await manager.applyRecommendedDuplicates([g])

        #expect(manager.banner?.message.contains("changed since they were scanned") == true,
                "a genuinely drifted batch stopped telling the user to rescan: “\(manager.banner?.message ?? "nil")”")
        #expect(mockFM.virtualDisk["/b/x"] != nil, "a drifted copy was trashed")
    }

    /// **Space the user never got back must not be reported as reclaimed.**
    ///
    /// A group whose redundant copy vanished externally between the scan and the click still
    /// resolves — every removal path is gone, so it correctly drops off the list — but this run
    /// freed nothing for it. Measured before the fix, two identical pairs with one copy already
    /// removed by something else reported **"Reclaimed 5 KB from 2 groups — press ⌘Z to undo"** for
    /// a run that trashed one 1 KB file.
    ///
    /// **The keeper of the vanished group has to match its recorded size**, or the fixture proves
    /// nothing: `keeperStillExists` refuses a drifted keeper, so a keeper stubbed at a different
    /// size drops the group at the batch filter and the accounting line is never reached. A first
    /// draft of this test did exactly that, passed against the unfixed code, and read as evidence
    /// the defect was unreachable.
    @MainActor
    @Test func bytesAreNotCreditedForCopiesThatVanishedExternally() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/a/y"] = stub(size: 1000, modified: Date(timeIntervalSince1970: 1_000))
        // `/b/y` is deliberately NOT on the disk: something else removed it after the scan.

        let here = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1_000)
        let gone = group(keeper: "/a/y", redundant: "/b/y", reclaim: 4_000)
        manager.duplicateGroups = [here, gone]

        await manager.applyRecommendedDuplicates([here, gone])

        let said = try #require(manager.banner?.message)
        print("PROBE banner=\(said) err=\(String(describing: manager.currentError))")
        #expect(said.contains(FileSyncManager.formatBytes(1_000)),
                "the banner does not name what this run actually freed: “\(said)”")
        #expect(!said.contains(FileSyncManager.formatBytes(5_000)),
                "the banner credited this run with space a copy that had already vanished used to take: “\(said)”")
        #expect(said.contains("1 KB"), "the banner does not name the one group this run actually freed: “\(said)”")
    }
}
