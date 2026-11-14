import Testing
import Foundation
import Events
@testable import Sync

/// The duplicate removal path tells the truth about a destructive action.
///
/// The undo promise: `deleteItems` registers a restore-undo only for items that reached the Trash,
/// and its `DeleteOutcome` says so. On a Trash-less volume (exFAT, most SMB shares) the files are
/// destroyed permanently, so a banner promising ⌘Z would reverse whatever was on top of the stack.
///
/// The same-size rewrite: the resolve-time drift check compares mtime as well as size, so a
/// same-length edit (2025 to 2026) is not trashed as redundant.
@Suite struct DuplicateRemovalHonestyTests {

    private func group(keeper: String, redundant: String, reclaim: Int) -> DuplicateGroup {
        let when = Date(timeIntervalSince1970: 1_000)
        return .stub([.stub(keeper, keeper: true, modified: when, depth: 1),
                      .stub(redundant, keeper: false, modified: when, depth: 1)], reclaimable: reclaim)
    }

    // MARK: The undo promise

    /// On a Trash-less volume the copies are destroyed permanently, and the banner must not offer
    /// an undo that would fire at an unrelated operation.
    @MainActor
    @Test func aPermanentRemovalDoesNotPromiseUndo() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true                     // no Trash on this volume
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        manager.permanentDeleteConfirmer = { _ in true }  // the user confirms the permanent delete
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
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

    /// The other direction: a normal Trash removal still offers its undo, and the drift guard does
    /// not over-refuse an untouched pair.
    @MainActor
    @Test func aTrashedRemovalStillPromisesUndo() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        let ok = await manager.resolveDuplicateGroup(g)

        #expect(ok == true)
        #expect(mockFM.virtualDisk["/b/x"] == nil)
        #expect(manager.banner?.isUndoable == true)
    }

    /// A partial batch's undo offer must expire like a whole one's, so its banner passes
    /// `undoable:` as its siblings do. `invalidateUndoableBanner` reads the flag, not the sentence;
    /// an offer kept only in prose would outlive the undo stack moving on and point ⌘Z at the
    /// wrong step. Warnings are normally left standing so an unrelated op can't clear an error,
    /// which is why severity and undoability are separate parameters.
    @MainActor
    @Test func aPartialBatchThatOffersUndoIsMarkedUndoableSoTheOfferCanExpire() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        // Two eligible groups, one with its keeper gone: filtered out of `batch` but still in
        // `eligible`, which takes the partial branch. The surviving group trashes normally, so the
        // outcome really is undoable; otherwise this would test the no-offer case.
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/y"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        // …and NOT "/a/y": the second group's keeper never existed.
        let present = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        let keeperGone = group(keeper: "/a/y", redundant: "/b/y", reclaim: 1000)
        manager.duplicateGroups = [present, keeperGone]

        await manager.applyRecommendedDuplicates([present, keeperGone])

        // Premise: this is the partial branch.
        let message = try #require(manager.banner?.message)
        #expect(message.contains("of 2 groups"),
                "not the partial branch — the banner reads “\(message)”, so the flag below is not the one under test")
        // The flag is the offer (it shows the Undo button), and `invalidateUndoableBanner` retires
        // it by the same flag.
        #expect(manager.banner?.isUndoable == true,
                "the partial banner made no undo offer, so its Undo button is missing — or, offered by prose alone, invalidateUndoableBanner would leave it up after the stack moves on")
        #expect(!message.contains("⌘Z"), "the Undo button says ⌘Z; the sentence repeats it (TE216)")
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
        // A copy the Trash took without a location is outside the restore-undo too.
        #expect(!DeleteOutcome(trashed: 2, trashedWithoutLocation: 1).isUndoable)
        #expect(DeleteOutcome(trashed: 2, trashedWithoutLocation: 1).removed == 3)
        #expect(!DeleteOutcome().isUndoable, "removing nothing is not something to undo")
        // Declined items were never removed, by either route.
        #expect(DeleteOutcome(declined: 4).removed == 0)
    }

    // MARK: The same-size rewrite

    /// `2025` → `2026`: identical length, different bytes, later mtime. Size alone would read this
    /// as the copy the scan grouped, and trash it.
    @MainActor
    @Test func aSameSizeRewriteOfACopyIsRefused() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        // Same size as the scan recorded, edited since.
        mockFM.virtualDisk["/b/x"] = .file(1000, modified: Date(timeIntervalSince1970: 9_999))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        let ok = await manager.resolveDuplicateGroup(g)

        #expect(ok == false)
        #expect(mockFM.virtualDisk["/b/x"] != nil, "an edited copy must never be trashed as redundant")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("changed since it was scanned") == true)
        // Nothing was removed: a refusal, kept for this session only.
        #expect(manager.banner?.isRefusal == true)
    }

    /// A scan that recorded no date still resolves on size alone, rather than refusing the group
    /// for lack of a baseline.
    @MainActor
    @Test func aPairWithNoRecordedDateStillResolvesOnSize() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: nil)
        mockFM.virtualDisk["/b/x"] = .file(1000, modified: nil)
        let g = DuplicateGroup.stub([.stub("/a/x", keeper: true, depth: 1), .stub("/b/x", keeper: false, depth: 1)])
        manager.duplicateGroups = [g]

        #expect(await manager.resolveDuplicateGroup(g) == true)
        #expect(mockFM.virtualDisk["/b/x"] == nil)
    }

    // MARK: What the batch says when it removes nothing, and what it claims it freed

    /// "Nothing to remove" is not "something changed". Drift is only one way to get an empty
    /// batch: a group whose every redundant copy is protected contributes no paths while nothing
    /// changed, so "rescan before removing copies" would send the user round a loop.
    @MainActor
    @Test func aBatchOfProtectedCopiesIsNotReportedAsDrift() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))

        let when = Date(timeIntervalSince1970: 1_000)
        let g = DuplicateGroup.stub([.stub("/a/x", keeper: true, modified: when, depth: 1),
                                     .stub("/b/x", keeper: false, modified: when, depth: 1, protected: true)])
        try #require(g.recommendedRemovalPaths.isEmpty, "the fixture no longer produces an empty removal list")
        try #require(g.isRecommendedForBatch, "the fixture is not eligible, so it never reaches the banner under test")
        manager.duplicateGroups = [g]

        await manager.applyRecommendedDuplicates([g])

        let said = try #require(manager.banner?.message)
        #expect(!said.contains("changed since they were scanned"),
                "a group nothing has touched was reported as drifted — a rescan finds the same thing: “\(said)”")
        #expect(said.contains("protected"), "the banner does not say why nothing was removed: “\(said)”")
        #expect(mockFM.virtualDisk["/b/x"] != nil)
        #expect(manager.banner?.isRefusal == true, "nothing left the disk, so it is kept for this session only")
    }

    /// A banner that names a cause must have checked it. A group with no redundant copies also
    /// gives an empty removal list, and `applyRecommendedDuplicates` is `public` over a
    /// `DuplicateGroup` initializer that validates nothing, so a one-copy group must not be told
    /// its copies are protected.
    @MainActor
    @Test func aGroupWithNothingToRemoveIsNotCalledProtected() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        // One copy, and it is the keeper: no redundant copies, so nothing is protected.
        let g = DuplicateGroup.stub([.stub("/a/x", keeper: true, modified: Date(timeIntervalSince1970: 1_000), depth: 1)])
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
        #expect(manager.banner?.isRefusal == true)
    }

    /// …and the drift wording still covers the case it is for.
    @MainActor
    @Test func aDriftedBatchStillSaysToRescan() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        // The redundant copy was rewritten since the scan — a different size is a KNOWN mismatch.
        mockFM.virtualDisk["/b/x"] = .file(2000, modified: Date(timeIntervalSince1970: 1_000))
        let g = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1000)
        manager.duplicateGroups = [g]

        await manager.applyRecommendedDuplicates([g])

        #expect(manager.banner?.message.contains("changed since they were scanned") == true,
                "a genuinely drifted batch stopped telling the user to rescan: “\(manager.banner?.message ?? "nil")”")
        #expect(mockFM.virtualDisk["/b/x"] != nil, "a drifted copy was trashed")
        #expect(manager.banner?.isRefusal == true)
    }

    /// Space the user never got back must not be reported as reclaimed. A group whose redundant
    /// copy vanished between the scan and the click still resolves and drops off the list, but
    /// this run freed nothing for it.
    ///
    /// The vanished group's keeper must match its recorded size, or the fixture proves nothing:
    /// `keeperStillExists` refuses a drifted keeper, so the group would drop at the batch filter
    /// before the accounting line.
    @MainActor
    @Test func bytesAreNotCreditedForCopiesThatVanishedExternally() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager.forTests(fileManager: mockFM)
        mockFM.virtualDisk["/a/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/b/x"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        mockFM.virtualDisk["/a/y"] = .file(1000, modified: Date(timeIntervalSince1970: 1_000))
        // `/b/y` is deliberately NOT on the disk: something else removed it after the scan.

        let here = group(keeper: "/a/x", redundant: "/b/x", reclaim: 1_000)
        let gone = group(keeper: "/a/y", redundant: "/b/y", reclaim: 4_000)
        manager.duplicateGroups = [here, gone]

        await manager.applyRecommendedDuplicates([here, gone])

        let said = try #require(manager.banner?.message)
        #expect(!said.contains(FileSyncManager.formatBytes(5_000)),
                "the banner credited this run with space a copy that had already vanished used to take: “\(said)”")
        #expect(said.contains("1 KB"), "the banner does not name the one group this run actually freed: “\(said)”")
    }
}
