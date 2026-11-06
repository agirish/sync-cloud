import Testing
import Foundation
@testable import Sync

/// Pins `invalidateDifferencesForPaneRetarget`, used by the provider-change paths that suppress
/// the provider-id onChange so duplicate results survive (the Duplicates lens's "Compare copies"
/// hand-off and its restore). They must clear the old comparison's differences themselves, since
/// its rows carry absolute paths for roots the panes no longer show and stay actionable while the
/// trees load, and must leave the lens state untouched.
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
    /// every piece of duplicate state survives.
    @MainActor
    @Test func retargetInvalidationClearsDifferencesButKeepsDuplicates() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())

        // An old comparison's published results...
        let diff = makeDifference()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.verifiedSameDifferenceIds = [diff.id]
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: [diff], asOf: manager.fileOperationsEpoch)
        manager.lastScanDate = Date()
        manager.lastScanReadAt = Date(timeIntervalSinceNow: -7200)
        manager.hasScanned = true

        // ...plus live duplicate results the user must be able to return to.
        let group = makeGroup()
        manager.duplicateGroups = [group]
        manager.duplicateScanRoot = "/root"
        manager.hasFoundDuplicates = true

        let publishedFilterGenerationBefore = manager.lastPublishedFilterGeneration
        manager.invalidateDifferencesForPaneRetarget()

        // Synchronously gone: no observer may see the old rows as actionable.
        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.lastScanDate == nil)
        // The comparison's age goes with it, or the pill would date the next comparison by this one.
        #expect(manager.lastScanReadAt == nil)
        #expect(manager.hasScanned == false)

        // Untouched: the duplicate state, the reason the callers suppress the provider-id
        // onChange instead of letting `retargetPane` run.
        #expect(manager.duplicateGroups == [group])
        #expect(manager.duplicateScanRoot == "/root")
        #expect(manager.hasFoundDuplicates == true)

        // The insurance filter pass over the cleared raws must not resurrect anything. This is an
        // absence, so wait for the pass to publish: a fixed sleep can't tell "ran and resurrected
        // nothing" from "hasn't run yet" (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps").
        //
        // `lastPublishedFilterGeneration` moves when a pass commits, and nothing else does here:
        // each assignment is "only if changed", so the pass writes no property. A queued Task can't
        // stand in either: `applyFilters` suspends on a detached compute, so the Task runs during
        // that suspension, before it publishes.
        await waitUntil("the insurance filter pass publishes") {
            manager.lastPublishedFilterGeneration > publishedFilterGenerationBefore
        }
        #expect(manager.differences.isEmpty)
        #expect(manager.duplicateGroups == [group])
    }

    /// Navigation is NOT reset (unlike retargetPane): the callers re-focus the panes
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

    /// The full reset keeps its contract: `invalidateComparisonState`, routed through the shared
    /// subset, clears the trees and the differences and leaves the duplicate state alone.
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

        let publishedFilterGenerationBefore = manager.lastPublishedFilterGeneration
        manager.invalidateComparisonState()

        #expect(manager.differences.isEmpty)
        #expect(manager.rawDifferences.isEmpty)
        #expect(manager.hasScanned == false)
        #expect(manager.leftTree.isEmpty)
        #expect(manager.leftItemCount == 0)
        #expect(manager.duplicateGroups == [group])

        // `invalidateComparisonState` delegates to `invalidateDifferencesForPaneRetarget`, so it
        // inherits the same insurance pass; asserting only synchronously would miss a pass that
        // republished the rows and trees just checked gone.
        await waitUntil("the insurance filter pass publishes") {
            manager.lastPublishedFilterGeneration > publishedFilterGenerationBefore
        }
        #expect(manager.differences.isEmpty)
        #expect(manager.leftTree.isEmpty)
        #expect(manager.leftItemCount == 0)
        #expect(manager.duplicateGroups == [group])
    }

    /// `invalidateComparisonState(reloading:)` drops the named panes' trees and no others. A
    /// Settings Location edit asks `ContentView.paneRootEdits` which pane's root moved and uses
    /// the answer here and on the rescan, so editing one source doesn't re-walk the other.
    ///
    /// Both arms of both scopes are checked, so swapping the `scope != .rightOnly` /
    /// `scope != .leftOnly` guards fails. `.both`, the default, is covered by the test above.
    @MainActor
    @Test func aScopedInvalidationDropsOnlyTheNamedPanesTree() async throws {
        for scope in [FileSyncManager.PaneReloadScope.leftOnly, .rightOnly] {
            let manager = FileSyncManager(fileManager: MockFileManager())
            let left = FileNode(id: "/left/docs", name: "docs", isDirectory: true)
            let right = FileNode(id: "/right/docs", name: "docs", isDirectory: true)
            manager.rawLeftTree = [left]; manager.leftTree = [left]; manager.leftItemCount = 1
            manager.lastLoadedLeftFocusPath = "/left"
            manager.rawRightTree = [right]; manager.rightTree = [right]; manager.rightItemCount = 1
            manager.lastLoadedRightFocusPath = "/right"
            // Each pane's walk is cached, as a load leaves it, beside a walk of somewhere else.
            manager.prefetchedTrees = ["/left": [left], "/right": [right], "/elsewhere": []]
            let diff = makeDifference()
            manager.rawDifferences = [diff]; manager.differences = [diff]; manager.hasScanned = true

            manager.invalidateComparisonState(reloading: scope)

            let droppedIsLeft = scope == .leftOnly
            let context = "scope \(scope)"
            // The named pane's tree is gone…
            #expect((droppedIsLeft ? manager.leftTree : manager.rightTree).isEmpty, "\(context): the named pane's tree survived")
            #expect((droppedIsLeft ? manager.rawLeftTree : manager.rawRightTree).isEmpty, "\(context): the named pane's raw tree survived")
            #expect((droppedIsLeft ? manager.leftItemCount : manager.rightItemCount) == 0, "\(context): the named pane's count survived")
            // …and the sibling's is untouched, including its loaded-focus marker: `pruneBrowsePath`
            // reads it to tell "empty" from "not loaded yet", and nulling it would let the next
            // republish flatten a valid column stack.
            #expect((droppedIsLeft ? manager.rightTree : manager.leftTree).count == 1, "\(context): the sibling's tree was dropped")
            #expect((droppedIsLeft ? manager.rawRightTree : manager.rawLeftTree).count == 1, "\(context): the sibling's raw tree was dropped")
            #expect((droppedIsLeft ? manager.rightItemCount : manager.leftItemCount) == 1, "\(context): the sibling's count was reset")
            #expect((droppedIsLeft ? manager.lastLoadedRightFocusPath : manager.lastLoadedLeftFocusPath) != nil,
                    "\(context): the sibling was marked unloaded, so its columns prune against a tree it still has")
            // And its cached walk alone stays: the rescan reloads only the named pane and compares
            // from cached trees only when both sides hit, so dropping it would walk both folders.
            #expect(Array(manager.prefetchedTrees.keys) == [droppedIsLeft ? "/right" : "/left"],
                    "\(context): cached walks after the invalidation: \(manager.prefetchedTrees.keys.sorted())")

            // The comparison is the pair's and goes whichever pane moved.
            #expect(manager.differences.isEmpty, "\(context): the stale comparison stayed actionable")
            #expect(manager.rawDifferences.isEmpty, "\(context)")
            #expect(manager.hasScanned == false, "\(context)")
        }
        // Both roots moved: no walk describes either any more.
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.lastLoadedLeftFocusPath = "/left"
        manager.lastLoadedRightFocusPath = "/right"
        manager.prefetchedTrees = ["/left": [], "/right": [], "/elsewhere": []]
        manager.invalidateComparisonState(reloading: .both)
        #expect(manager.prefetchedTrees.isEmpty, "both roots moved and a walk survived: \(manager.prefetchedTrees.keys.sorted())")
    }
}
