import Testing
import Foundation
@testable import Sync

@Suite struct SwapPanesTests {

    /// The focused side is a per-side fact like the selections and histories beside it, so it
    /// travels with them; left behind, it would aim ⌘F, ⌘[ and ⇧⌘N at the pane their content just
    /// left. It lives on the manager, not in view `@State`, so the swap can't forget it untested.
    @MainActor
    @Test func testSwapPanesCarriesTheFocusedSide() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        manager.focusedPaneSide = .right
        manager.swapPanes()
        #expect(manager.focusedPaneSide == .left)

        // ...and back: the swap is its own inverse here too.
        manager.swapPanes()
        #expect(manager.focusedPaneSide == .right)
    }

    /// Implicit focus has nothing to swap. Materialising a side would override the fallback, which
    /// reads the selection, and `swapPanes` has already moved the selection to the right answer.
    @MainActor
    @Test func testSwapPanesLeavesImplicitFocusImplicit() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        manager.swapPanes()

        #expect(manager.focusedPaneSide == nil)
    }

    /// A swap invalidates every column listing in flight, because each one names a side.
    /// `ColumnGraftKey` carries `isLeft`, which after a swap names the other pane's tree, so the
    /// published set would invert: the column really being read says "Can't be read", and the pane
    /// that isn't says it is. Mirroring the keys is worse: the listing was taken for a pane that
    /// has moved, so there is nothing correct left to say about it.
    @MainActor
    @Test func testSwapPanesDropsColumnListingsInFlight() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.columnGraftsInFlight = [
            FileSyncManager.ColumnGraftKey(isLeft: true, path: "/left/deep"),
            FileSyncManager.ColumnGraftKey(isLeft: false, path: "/right/deep"),
        ]

        manager.swapPanes()

        #expect(manager.columnGraftsInFlight.isEmpty,
                "a key naming a side cannot survive the sides changing")
        #expect(manager.columnGraftsInFlightPaths(isLeft: true).isEmpty)
        #expect(manager.columnGraftsInFlightPaths(isLeft: false).isEmpty)
    }

    /// The generation stops a listing already off the main actor grafting into the pane its
    /// captured `isLeft` now names. Asserted separately from the set above because the failures
    /// differ: an uncleared set draws a wrong caption, a missed generation writes one pane's
    /// listing into the other pane's tree.
    @MainActor
    @Test func testSwapPanesAdvancesThePaneOrientationGeneration() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let before = manager.paneOrientationGeneration

        manager.swapPanes()
        #expect(manager.paneOrientationGeneration == before + 1)

        // A refused swap must not advance it: an in-flight listing still matches the orientation
        // it started in, and dropping its answer would cost a column its fill for nothing.
        manager.activeFileOperationsCount = 1
        #expect(manager.swapPanes() == false)
        #expect(manager.paneOrientationGeneration == before + 1)
    }

    @MainActor
    @Test func testSwapPanesExchangesPathsSelectionsAndHistories() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        // Drive each pane to a distinct focused folder (which also builds a distinct history),
        // and select in one pane (the one-pane-selected invariant is enforced at the UI layer).
        manager.focusOn(relativePath: "left/deep", isLeft: true)
        manager.focusOn(relativePath: "right", isLeft: false)
        manager.selectedLeftPaths = ["/l/a", "/l/b"]

        let leftRelBefore = manager.leftRelativePath      // "left/deep"
        let rightRelBefore = manager.rightRelativePath    // "right"
        let leftHistBefore = manager.leftHistory
        let rightHistBefore = manager.rightHistory
        let leftSelBefore = manager.selectedLeftPaths      // ["/l/a", "/l/b"]
        let rightSelBefore = manager.selectedRightPaths    // []

        manager.swapPanes()

        // Every paired field lands on the opposite side.
        #expect(manager.leftRelativePath == rightRelBefore)
        #expect(manager.rightRelativePath == leftRelBefore)
        #expect(manager.selectedLeftPaths == rightSelBefore)
        #expect(manager.selectedRightPaths == leftSelBefore)
        #expect(manager.leftHistory == rightHistBefore)
        #expect(manager.rightHistory == leftHistBefore)
        // The relative paths stay consistent with the swapped histories' current entries, so
        // per-pane Back/Forward still walks the right stack after the flip.
        #expect(manager.leftRelativePath == manager.leftHistory.current)
        #expect(manager.rightRelativePath == manager.rightHistory.current)

        // Swapping again is an exact inverse: the original arrangement is restored.
        manager.swapPanes()
        #expect(manager.leftRelativePath == leftRelBefore)
        #expect(manager.rightRelativePath == rightRelBefore)
        #expect(manager.leftHistory == leftHistBefore)
        #expect(manager.rightHistory == rightHistBefore)
        #expect(manager.selectedLeftPaths == leftSelBefore)
        #expect(manager.selectedRightPaths == rightSelBefore)
    }

    /// A missing-on-right difference as the diff engine would produce it for the pre-swap layout.
    private func makeDifference(
        id: UUID = UUID(),
        type: FileDifference.DifferenceType = .missingOnRight,
        action: FileDifference.SyncAction = .copyToRight,
        description: String = "Missing on right (OneDrive)"
    ) -> FileDifference {
        FileDifference(
            id: id,
            relativePath: "docs/a.txt",
            leftItemPath: "/left/docs/a.txt",
            rightItemPath: "/right/docs/a.txt",
            type: type,
            action: action,
            description: description,
            leftFileSize: 10,
            rightFileSize: 20
        )
    }

    /// The swap remaps every difference in the same synchronous update that flips the pane state,
    /// so no observer sees swapped pane labels over rows whose paths, arrows or actions still point
    /// the old way. That mismatch would copy files against the arrows shown, and Replace would
    /// overwrite the wrong files.
    @MainActor
    @Test func testSwapPanesRemapsDifferencesAtomically() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        #expect(manager.swapPanes())

        for list in [manager.differences, manager.rawDifferences] {
            let swapped = try #require(list.first)
            #expect(swapped.id == diff.id)
            #expect(swapped.leftItemPath == "/right/docs/a.txt")
            #expect(swapped.rightItemPath == "/left/docs/a.txt")
            #expect(swapped.leftFileSize == 20)
            #expect(swapped.rightFileSize == 10)
            #expect(swapped.type == .missingOnLeft)
            #expect(swapped.action == .copyToLeft)
            #expect(swapped.description == "Missing on left (OneDrive)")
        }
    }

    /// Trees, item counts, focus bookkeeping and loading flags all trade sides with the labels;
    /// otherwise swapped headers sit over unswapped trees until the rescan, and copy or move from
    /// those rows' context menus resolves against the wrong roots.
    @MainActor
    @Test func testSwapPanesExchangesTreesCountsAndLoadBookkeeping() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let leftNode = FileNode(id: "/left/a.txt", name: "a.txt", isDirectory: false)
        let rightNode = FileNode(id: "/right/b.txt", name: "b.txt", isDirectory: false)
        manager.rawLeftTree = [leftNode]
        manager.leftTree = [leftNode]
        manager.rawRightTree = [rightNode]
        manager.rightTree = [rightNode]
        manager.leftItemCount = 1
        manager.rightItemCount = 1
        manager.lastLoadedLeftFocusPath = "/left"
        manager.lastLoadedRightFocusPath = "/right"
        manager.isLoadingLeftTree = true
        manager.isLoadingRightTree = false

        #expect(manager.swapPanes())

        #expect(manager.leftTree == [rightNode])
        #expect(manager.rightTree == [leftNode])
        #expect(manager.rawLeftTree == [rightNode])
        #expect(manager.rawRightTree == [leftNode])
        #expect(manager.lastLoadedLeftFocusPath == "/right")
        #expect(manager.lastLoadedRightFocusPath == "/left")
        #expect(manager.isLoadingLeftTree == false)
        #expect(manager.isLoadingRightTree == true)
    }

    /// The coverage claim is side-labelled, so it swaps with the sources it is read beside.
    /// `partialComparisonMessage` pairs `lastScanCoverage.left` with `lastScanProviders.left`, which
    /// the swap mirrors; unmirrored coverage would make the banner name the source that was read
    /// in full and say nothing of the one that wasn't. The rows survive a swap (mirrored, not
    /// cleared), so the banner survives with them and no rescan corrects it.
    @MainActor
    @Test func testSwapPanesMirrorsTheScanCoverageWithTheProviders() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        manager.lastScanCoverage = PartialComparison(left: true, right: false)
        try #require(manager.swapPanes(), "the swap was refused — this measures nothing")

        #expect(manager.lastScanCoverage == PartialComparison(left: false, right: true),
                "the banner now names the side that was read in full")

        // Its own inverse, like everything else here.
        try #require(manager.swapPanes())
        #expect(manager.lastScanCoverage == PartialComparison(left: true, right: false))
    }

    /// A complete comparison stays complete through a swap: the mirror must not invent a partial
    /// side out of two falses.
    @MainActor
    @Test func testSwapPanesLeavesACompleteComparisonComplete() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        try #require(manager.lastScanCoverage.isComplete)
        try #require(manager.swapPanes())
        #expect(manager.lastScanCoverage.isComplete)
    }

    /// Checksum-verified ids survive the swap (content equality is symmetric and `mirrored()` keeps
    /// ids, so verified rows must not resurface), while the pending copy-identical offer is dropped:
    /// its captured rows and left→right wording are pre-swap.
    @MainActor
    @Test func testSwapPanesKeepsVerifiedIdsButDropsPendingCopyOffer() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.verifiedSameDifferenceIds = [diff.id]
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: [diff], asOf: manager.fileOperationsEpoch)

        #expect(manager.swapPanes())

        #expect(manager.verifiedSameDifferenceIds == [diff.id])
        #expect(manager.verifiedIdenticalForCopy == nil)
    }

    /// The swap is refused while file operations are in flight: they captured pre-swap paths and
    /// directions, and remapped rows would show arrows that don't match what is running. The caller
    /// keeps the provider ids put when the swap reports refusal.
    @MainActor
    @Test func testSwapPanesRefusedWhileOperationsInFlight() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.leftRelativePath = "docs"

        manager.activeFileOperationsCount = 1
        #expect(!manager.swapPanes())
        manager.activeFileOperationsCount = 0

        manager.markSyncing(ids: [diff.id])
        #expect(manager.differences[0].isSyncing)
        #expect(!manager.swapPanes())
        manager.clearSyncing(ids: [diff.id])

        // Nothing moved during either refusal.
        #expect(manager.leftRelativePath == "docs")
        #expect(manager.rightRelativePath == "")
        #expect(manager.differences[0].leftItemPath == "/left/docs/a.txt")
        #expect(manager.rawDifferences[0].action == .copyToRight)

        // With operations drained the same swap goes through.
        #expect(manager.swapPanes())
        #expect(manager.rightRelativePath == "docs")
    }

    /// The swap is also refused while Verify All runs: a run finishing after the swap would
    /// publish a `verifiedIdenticalForCopy` offer built from pre-swap differences, and the copy
    /// would run the old direction under swapped labels.
    @MainActor
    @Test func testSwapPanesRefusedWhileVerifyAllInFlight() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.leftRelativePath = "docs"

        manager.isVerifyAllRunning = true
        #expect(!manager.swapPanes())
        // Fields compared, since banner equality includes a per-publish id.
        #expect(manager.banner?.message == "Can’t swap panes while an operation is running")
        #expect(manager.banner?.severity == .warning)
        // Nothing moved during the refusal.
        #expect(manager.leftRelativePath == "docs")
        #expect(manager.rawDifferences[0].action == .copyToRight)

        // With the verify run finished the same swap goes through.
        manager.isVerifyAllRunning = false
        #expect(manager.swapPanes())
        #expect(manager.rightRelativePath == "docs")
    }

    /// A provider switch (`retargetPane`) drops the differences and the switched pane's tree
    /// synchronously, so rows scanned against the old roots aren't clickable while the new provider
    /// loads, and resets `hasScanned` so the empty list reads "No Scan Performed", never a false
    /// "Everything is in sync". It leaves the other pane's tree where it was: a comparison belongs
    /// to the pair, a tree to one pane. Dropping the sibling's tree would put a spinner over a pane
    /// the user hadn't touched and, since the empty tree republishes a view update ahead of the
    /// reload, flatten its column stack (`pruneBrowsePath`).
    @MainActor
    @Test func testRetargetPaneClearsTheComparisonAndOnlyItsOwnTree() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.verifiedSameDifferenceIds = [diff.id]
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: [diff], asOf: manager.fileOperationsEpoch)
        manager.hasScanned = true
        let node = FileNode(id: "/left/a.txt", name: "a.txt", isDirectory: false)
        manager.rawLeftTree = [node]
        manager.leftTree = [node]
        manager.leftItemCount = 1
        manager.lastLoadedLeftFocusPath = "/left"
        let sibling = FileNode(id: "/right/b.txt", name: "b.txt", isDirectory: false)
        manager.rawRightTree = [sibling]
        manager.rightTree = [sibling]
        manager.rightItemCount = 1
        manager.lastLoadedRightFocusPath = "/right"

        manager.retargetPane(isLeft: true, landing: "")

        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(!manager.hasScanned)
        #expect(manager.leftTree.isEmpty)
        #expect(manager.rawLeftTree.isEmpty)
        #expect(manager.leftItemCount == 0)
        #expect(manager.lastLoadedLeftFocusPath == nil)

        // The pane nobody switched.
        #expect(manager.rightTree == [sibling], "a switch on the left pane threw away the right pane's tree")
        #expect(manager.rawRightTree == [sibling])
        #expect(manager.rightItemCount == 1)
        #expect(manager.lastLoadedRightFocusPath == "/right",
                "the untouched pane was marked unloaded, so the next republish prunes its columns against an empty tree")
    }

    /// `mirrored()` is an exact involution, and description mirroring flips only the side-relative
    /// phrase: provider names travel with their files, and direction-free descriptions pass
    /// through unchanged.
    @Test func testMirroredNameConflictKeepsQuotedNamesVerbatim() async throws {
        // A .nameConflict description quotes both leaf names exactly (that is its purpose), and
        // provider names travel with their files, so the text is side-neutral. A blanket
        // "on right"→"on left" rewrite would mangle a quoted name containing those words.
        let description = ProviderNameRules.nameConflictDescription(
            leftName: "essay on right.txt", leftProvider: "iCloud",
            rightName: "essay on right.txt.", rightProvider: "Dropbox")
        let diff = FileDifference(
            relativePath: "essay on right.txt",
            leftItemPath: "/l/essay on right.txt",
            rightItemPath: "/r/essay on right.txt.",
            type: .nameConflict,
            action: .copyToRight,
            description: description)
        #expect(diff.mirrored().description == description)   // verbatim, no side rewrite
    }

    @Test func testMirroredDescriptionAndInvolution() async throws {
        #expect(FileDifference.mirroredDescription("Folder missing on right (iCloud)")
            == "Folder missing on left (iCloud)")
        #expect(FileDifference.mirroredDescription("Missing on left (Local Disk)")
            == "Missing on right (Local Disk)")
        #expect(FileDifference.mirroredDescription("iCloud file is newer")
            == "iCloud file is newer")
        #expect(FileDifference.mirroredDescription("Sizes differ") == "Sizes differ")

        // A link note quotes a path inside the folder exactly: the side phrase outside the quotes
        // turns, the path doesn't, and the path's own words don't choose the direction.
        #expect(FileDifference.mirroredDescription(
            "Folder missing on right (iCloud) — “Docs/notes on left” inside it is a link, so a copy would carry the link")
            == "Folder missing on left (iCloud) — “Docs/notes on left” inside it is a link, so a copy would carry the link")
        #expect(FileDifference.mirroredDescription(
            "Folder missing on left (iCloud) — “Docs/notes on right” inside it is a link")
            == "Folder missing on right (iCloud) — “Docs/notes on right” inside it is a link")
        #expect(FileDifference.mirroredDescription("Folder missing on right (iCloud) — “Docs/notes on right” inside it is a link")
            == "Folder missing on left (iCloud) — “Docs/notes on right” inside it is a link")
        // An unclosed quote leaves the rest quoted rather than rewriting into it.
        #expect(FileDifference.mirroredDescription("Missing on right — “a on right")
            == "Missing on left — “a on right")

        let diff = FileDifference(
            relativePath: "x",
            leftItemPath: "/l/x",
            rightItemPath: "/r/x",
            type: .differentDates,
            action: .copyToLeft,
            description: "OneDrive file is newer",
            leftFileSize: 1,
            rightFileSize: 1
        )
        #expect(diff.mirrored().mirrored() == diff)
        #expect(diff.mirrored().action == .copyToRight)
        #expect(diff.mirrored().type == .differentDates)
    }
}
