import Testing
import Foundation
@testable import Sync

/// Pins `invalidateDifferencesForPaneRetarget`, the targeted invalidation used by the
/// suppressed provider-change paths (Tidy's "Compare copies" hand-off and its restore). Those
/// paths deliberately suppress the provider-id onChange so the Tidy duplicate results survive —
/// which means they must clear the OLD comparison's differences themselves (the rows carry
/// absolute paths for roots the panes no longer show and stay actionable during the tree-load
/// window), while leaving the Tidy state — the original reason for the suppression — untouched.
@Suite struct PaneRetargetInvalidationTests {

    private func makeDifference() -> FileDifference {
        FileDifference(
            id: UUID(),
            relativePath: "docs/a.txt",
            leftItemPath: "/old-left/docs/a.txt",
            rightItemPath: "/old-right/docs/a.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right",
            leftFileSize: 10,
            rightFileSize: nil
        )
    }

    private func makeGroup() -> DuplicateGroup {
        let keeper = DuplicateCopy(id: "/root/A/report.pdf", name: "report.pdf", isDirectory: false,
                                   size: 8192, itemCount: 1, modificationDate: nil, uniqueItemCount: 0,
                                   depth: 2, isRecommendedKeeper: true)
        let redundant = DuplicateCopy(id: "/root/B/report.pdf", name: "report.pdf", isDirectory: false,
                                      size: 8192, itemCount: 1, modificationDate: nil, uniqueItemCount: 0,
                                      depth: 2, isRecommendedKeeper: false)
        return DuplicateGroup(matchType: .identical, name: "report.pdf", isDirectory: false,
                              copies: [keeper, redundant], reclaimableBytes: 8192)
    }

    /// The core contract: every published diff-presentation field is dropped synchronously, and
    /// every piece of Tidy duplicate state survives.
    @MainActor
    @Test func retargetInvalidationClearsDifferencesButKeepsDuplicates() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        // An old comparison's published results...
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.verifiedSameDifferenceIds = [diff.id]
        manager.verifiedIdenticalForCopy = [diff]
        manager.lastScanDate = Date()
        manager.hasScanned = true

        // ...plus live Tidy duplicate results the user must be able to return to.
        let group = makeGroup()
        manager.duplicateGroups = [group]
        manager.duplicateScanRoot = "/root"
        manager.hasFoundDuplicates = true

        manager.invalidateDifferencesForPaneRetarget()

        // Synchronously gone: no observer may see the old rows as actionable.
        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.lastScanDate == nil)
        #expect(manager.hasScanned == false)

        // Untouched: the Tidy duplicate state (the whole reason the callers suppress the
        // provider-id onChange instead of letting resetNavigation run).
        #expect(manager.duplicateGroups == [group])
        #expect(manager.duplicateScanRoot == "/root")
        #expect(manager.hasFoundDuplicates == true)

        // The insurance filter pass over the cleared raws must not resurrect anything.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.differences.isEmpty)
        #expect(manager.duplicateGroups == [group])
    }

    /// Navigation is NOT reset (unlike resetNavigation): the callers re-focus the panes
    /// themselves right after, and wiping the histories/selections here would fight that.
    @MainActor
    @Test func retargetInvalidationLeavesNavigationAlone() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.focusOn(relativePath: "keep/here", isLeft: true)
        manager.focusOn(relativePath: "and/there", isLeft: false)
        manager.selectedLeftPaths = ["/x/a"]

        manager.invalidateDifferencesForPaneRetarget()

        #expect(manager.leftRelativePath == "keep/here")
        #expect(manager.rightRelativePath == "and/there")
        #expect(manager.selectedLeftPaths == ["/x/a"])
        #expect(manager.leftHistory.canGoBack)
    }

    /// The full reset keeps its contract too: `invalidateComparisonState` (now routed through
    /// the shared subset) still clears the trees AND the differences, and still leaves the
    /// Tidy duplicate state alone — pinning the refactor as behavior-preserving.
    @MainActor
    @Test func fullInvalidationStillClearsTreesAndDifferences() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.hasScanned = true
        manager.leftTree = [FileNode(id: "/old-left/docs", name: "docs", isDirectory: true)]
        manager.leftItemCount = 1
        let group = makeGroup()
        manager.duplicateGroups = [group]

        manager.invalidateComparisonState()

        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
        #expect(manager.hasScanned == false)
        #expect(manager.leftTree.isEmpty)
        #expect(manager.leftItemCount == 0)
        #expect(manager.duplicateGroups == [group])
    }
}
