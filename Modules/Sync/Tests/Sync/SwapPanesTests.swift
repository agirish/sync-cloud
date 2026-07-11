import Testing
import Foundation
@testable import Sync

@Suite struct SwapPanesTests {

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

        // Swapping again is an exact inverse — the original arrangement is restored.
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

    /// Pin: the swap remaps every difference in the same synchronous update that flips the
    /// pane state — no observer can see swapped pane labels over rows whose paths, arrows,
    /// or actions still point the pre-swap way (that misdirection copied files in the
    /// direction opposite to the arrows shown, and Replace overwrote unintended files).
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

    /// Pin: trees, item counts, focus bookkeeping, and loading flags all trade sides with the
    /// labels — pre-fix the swapped headers sat over unswapped trees until the rescan landed,
    /// and context-menu copy/move on those stale rows resolved against the wrong roots.
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

    /// Pin: checksum-verified-identical ids survive the swap (content equality is symmetric
    /// and `mirrored()` preserves ids — the verified rows must not resurface), while the
    /// pending copy-identical offer is dropped (its captured rows and left→right wording
    /// are pre-swap).
    @MainActor
    @Test func testSwapPanesKeepsVerifiedIdsButDropsPendingCopyOffer() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.verifiedSameDifferenceIds = [diff.id]
        manager.verifiedIdenticalForCopy = [diff]

        #expect(manager.swapPanes())

        #expect(manager.verifiedSameDifferenceIds == [diff.id])
        #expect(manager.verifiedIdenticalForCopy == nil)
    }

    /// Pin: the swap is refused while file operations are in flight — those operations
    /// captured pre-swap paths and directions, and remapping the rows under them would show
    /// arrows that no longer match what the running operation does. The caller keeps the
    /// provider ids put when the swap reports refusal.
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

    /// Pin: the swap is also refused while Verify All is running — a run completing after the
    /// swap would publish a `verifiedIdenticalForCopy` offer built from pre-swap differences,
    /// and the follow-up copy would run in the pre-swap direction under mismatched labels.
    @MainActor
    @Test func testSwapPanesRefusedWhileVerifyAllInFlight() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.leftRelativePath = "docs"

        manager.isVerifyAllRunning = true
        #expect(!manager.swapPanes())
        // (Field comparison — banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "Can't swap panes while an operation is running")
        #expect(manager.banner?.severity == .warning)
        // Nothing moved during the refusal.
        #expect(manager.leftRelativePath == "docs")
        #expect(manager.rawDifferences[0].action == .copyToRight)

        // With the verify run finished the same swap goes through.
        manager.isVerifyAllRunning = false
        #expect(manager.swapPanes())
        #expect(manager.rightRelativePath == "docs")
    }

    /// Pin: a provider switch (resetNavigation) drops differences and trees synchronously —
    /// rows scanned against the old roots must not stay clickable while the new provider
    /// loads — and resets `hasScanned` so the empty list reads "No Scan Performed", never a
    /// false "Everything is in sync".
    @MainActor
    @Test func testResetNavigationClearsComparisonState() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.verifiedSameDifferenceIds = [diff.id]
        manager.verifiedIdenticalForCopy = [diff]
        manager.hasScanned = true
        let node = FileNode(id: "/left/a.txt", name: "a.txt", isDirectory: false)
        manager.rawLeftTree = [node]
        manager.leftTree = [node]
        manager.leftItemCount = 1
        manager.lastLoadedLeftFocusPath = "/left"

        manager.resetNavigation()

        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(!manager.hasScanned)
        #expect(manager.leftTree.isEmpty)
        #expect(manager.rawLeftTree.isEmpty)
        #expect(manager.leftItemCount == 0)
        #expect(manager.lastLoadedLeftFocusPath == nil)
    }

    /// Pin: `mirrored()` is an exact involution, and description mirroring flips only the
    /// side-relative phrase — provider names travel with their files and stay untouched, and
    /// direction-free descriptions pass through unchanged.
    @Test func testMirroredDescriptionAndInvolution() async throws {
        #expect(FileDifference.mirroredDescription("Folder missing on right (iCloud)")
            == "Folder missing on left (iCloud)")
        #expect(FileDifference.mirroredDescription("Missing on left (Local Disk)")
            == "Missing on right (Local Disk)")
        #expect(FileDifference.mirroredDescription("iCloud file is newer")
            == "iCloud file is newer")
        #expect(FileDifference.mirroredDescription("Sizes differ") == "Sizes differ")

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
