import Testing
import Foundation
@testable import Sync

/// Pins the two-layer ignore model: session edits mirror into the durable store in
/// root-relative coordinates, navigation clears only the session layer, the effective set
/// translates stored entries into the current focus, and the toggle/un-ignore entry points
/// keep both layers consistent.
@Suite struct PersistentIgnoresTests {

    /// A manager with a durable ignore store on a scratch suite, which the store keeps alive and
    /// which wipes itself once the test lets go. Given `mixed`, the pair's two sources open at
    /// different depths, wired the way the app wires them: the ids are what `paneSourceId` answers
    /// and the pair key is built from, the `openAt` values what `paneOpenAt` answers. The durable
    /// store needs all four to agree.
    @MainActor
    private func makeManagerWithStore(
        mixed: (leftId: String, leftOpenAt: String, rightId: String, rightOpenAt: String)? = nil
    ) -> (FileSyncManager, IgnoredItemsStore) {
        let store = IgnoredItemsStore(userDefaults: ScratchDefaults("PersistentIgnoresTests"))
        store.activate(pairKey: IgnoredItemsStore.pairKey(mixed?.leftId ?? "left", mixed?.rightId ?? "right"))
        let manager = FileSyncManager()
        manager.ignoredItemsStore = store
        if let mixed {
            manager.paneSourceId = { $0 ? mixed.leftId : mixed.rightId }
            manager.paneOpenAt = { $0 ? mixed.leftOpenAt : mixed.rightOpenAt }
        }
        return (manager, store)
    }

    @MainActor
    @Test func testIgnoreAtRootMirrorsIntoStore() {
        let (manager, store) = makeManagerWithStore()

        manager.ignoredPaths = ["junk", "node_modules"]
        #expect(store.rootRelativePaths == ["junk", "node_modules"])

        // Un-ignoring via the session layer removes from the store too.
        manager.ignoredPaths = ["node_modules"]
        #expect(store.rootRelativePaths == ["node_modules"])
    }

    @MainActor
    @Test func testIgnoreInSubfolderIsStoredRootRelative() {
        let (manager, store) = makeManagerWithStore()

        manager.focusBoth(relativePath: "Docs/Work")
        manager.ignoredPaths = ["draft.txt"]
        #expect(store.rootRelativePaths == ["Docs/Work/draft.txt"])
    }

    @MainActor
    @Test func testDivergentPaneFociKeepIgnoresSessionOnly() {
        // With the panes on different folders a focus-relative path names different items on
        // the two sides, so there is no root-relative identity to store: the durable mirror stays
        // out of it in both directions, leaving session behavior.
        let (manager, store) = makeManagerWithStore()

        store.add(["x.txt"])
        manager.focusOn(relativePath: "Docs", isLeft: false) // right pane only; left stays at root
        manager.ignoredPaths = ["x.txt"]
        // No new entry, and toggling off must not delete the root-level entry either.
        #expect(store.rootRelativePaths == ["x.txt"])
        manager.toggleIgnored(focusRelativePaths: ["x.txt"])
        #expect(store.rootRelativePaths == ["x.txt"])
        #expect(manager.ignoredPaths.isEmpty)
    }

    @MainActor
    @Test func testNavigationClearsSessionButNotStore() {
        let (manager, store) = makeManagerWithStore()

        manager.ignoredPaths = ["junk"]
        manager.focusOn(relativePath: "Docs", isLeft: true)
        #expect(manager.ignoredPaths.isEmpty)
        #expect(store.rootRelativePaths == ["junk"])

        manager.focusOn(relativePath: "", isLeft: true)
        // Back at the root, the stored entry applies again through the effective set.
        #expect(manager.effectiveIgnoredPaths == ["junk"])
    }

    @MainActor
    @Test func testEffectiveSetTranslatesStoreIntoFocus() {
        let (manager, store) = makeManagerWithStore()

        store.add(["Docs/draft.txt", "Docs/Sub/old", "Other/x", "Docs"])
        manager.focusOn(relativePath: "Docs", isLeft: true)
        // Entries under the focus translate; entries elsewhere, and the focus itself, are
        // dropped (navigating into an ignored folder shows its contents).
        #expect(manager.effectiveIgnoredPaths == ["draft.txt", "Sub/old"])
    }

    @MainActor
    @Test func testRememberOffKeepsSessionOnlyBehavior() {
        let (manager, store) = makeManagerWithStore()

        store.add(["stored-entry"])
        manager.rememberIgnoredItems = false
        manager.ignoredPaths = ["session-entry"]
        // No mirroring in, no application of stored entries out.
        #expect(store.rootRelativePaths == ["stored-entry"])
        #expect(manager.effectiveIgnoredPaths == ["session-entry"])
    }

    @MainActor
    @Test func testToggleUnignoresDurableEntryTheSessionNeverHeld() {
        let (manager, store) = makeManagerWithStore()

        // Ignored in a previous session: store holds it, session layer is empty.
        store.add(["junk"])
        #expect(manager.effectiveIgnoredPaths == ["junk"])

        manager.toggleIgnored(focusRelativePaths: ["junk"])
        #expect(store.rootRelativePaths.isEmpty)
        #expect(manager.effectiveIgnoredPaths.isEmpty)
    }

    @MainActor
    @Test func testToggleUnignoringChildRemovesCoveringAncestorEntry() {
        // "docs/report.txt" is ignored via "docs", so the menu reads "Include in comparison".
        // The toggle must agree: remove the covering entry from both layers, not insert the
        // child's own path, which would keep the row excluded after "docs" is un-ignored.
        let (manager, store) = makeManagerWithStore()

        manager.ignoredPaths = ["docs", "other"]
        manager.toggleIgnored(focusRelativePaths: ["docs/report.txt"])
        #expect(manager.ignoredPaths == ["other"])
        #expect(store.rootRelativePaths == ["other"])
        #expect(!FileSyncManager.isIgnoredPath("docs/report.txt", ignored: manager.effectiveIgnoredPaths))
    }

    @MainActor
    @Test func testToggleUnignoringAncestorCoveredTargetCountsAsIgnored() {
        // "docs/report.txt" is covered by "docs" and "a" is ignored exactly -> every target
        // is effectively ignored, so the action is un-ignore for all (not re-ignore).
        let (manager, store) = makeManagerWithStore()

        manager.ignoredPaths = ["docs", "a"]
        manager.toggleIgnored(focusRelativePaths: ["docs/report.txt", "a"])
        #expect(manager.ignoredPaths.isEmpty)
        #expect(store.rootRelativePaths.isEmpty)
    }

    @MainActor
    @Test func testToggleRoundTripIsIdentity() {
        let (manager, store) = makeManagerWithStore()

        manager.toggleIgnored(focusRelativePaths: ["a", "b"])
        #expect(manager.effectiveIgnoredPaths == ["a", "b"])
        manager.toggleIgnored(focusRelativePaths: ["a", "b"])
        #expect(manager.effectiveIgnoredPaths.isEmpty)
        #expect(store.rootRelativePaths.isEmpty)
    }

    @MainActor
    @Test func testToggleIgnoresWhenAnyTargetIsVisible() {
        let (manager, store) = makeManagerWithStore()

        manager.ignoredPaths = ["a"]
        manager.toggleIgnored(focusRelativePaths: ["a", "b"])
        #expect(manager.effectiveIgnoredPaths == ["a", "b"])
        #expect(store.rootRelativePaths == ["a", "b"])
    }

    @MainActor
    @Test func testUnignoreRootRelativeClearsBothLayers() {
        let (manager, store) = makeManagerWithStore()

        manager.focusBoth(relativePath: "Docs")
        manager.ignoredPaths = ["draft.txt"]
        #expect(store.rootRelativePaths == ["Docs/draft.txt"])

        manager.unignoreRootRelative("Docs/draft.txt")
        #expect(store.rootRelativePaths.isEmpty)
        #expect(manager.ignoredPaths.isEmpty)
        #expect(manager.effectiveIgnoredPaths.isEmpty)
    }

    @MainActor
    @Test func testClearAllEmptiesBothLayers() {
        let (manager, store) = makeManagerWithStore()

        manager.ignoredPaths = ["a", "b"]
        store.add(["c"])
        manager.clearAllIgnoredItems()
        #expect(store.rootRelativePaths.isEmpty)
        #expect(manager.ignoredPaths.isEmpty)
        #expect(manager.effectiveIgnoredPaths.isEmpty)
    }

    @MainActor
    @Test func testFilteringHidesDurablyIgnoredAndPatternMatchedDifferences() {
        let diffs = [
            FileDifference(relativePath: "keep.txt", leftItemPath: "/l/keep.txt", rightItemPath: "/r/keep.txt", type: .missingOnRight, action: .copyToRight, description: ""),
            FileDifference(relativePath: "junk/inner.txt", leftItemPath: "/l/junk/inner.txt", rightItemPath: "/r/junk/inner.txt", type: .missingOnRight, action: .copyToRight, description: ""),
            FileDifference(relativePath: "Docs/scratch.tmp", leftItemPath: "/l/Docs/scratch.tmp", rightItemPath: "/r/Docs/scratch.tmp", type: .missingOnRight, action: .copyToRight, description: ""),
        ]
        let state = FileSyncManager.computeFilteredState(
            rawLeftTree: [],
            rawRightTree: [],
            rawDifferences: diffs,
            showHidden: true,
            ignoredPaths: ["junk"],
            ignorePatterns: ["*.tmp"],
            verifiedSameDifferenceIds: [],
            dropDriveDateNoise: false
        )
        #expect(state.differences.map(\.relativePath) == ["keep.txt"])
    }

    @MainActor
    @Test func testIsNodeIgnoredSeesStoreEntriesButNotPatterns() {
        let (manager, store) = makeManagerWithStore()

        store.add(["docs/report.txt"])
        manager.ignorePatterns = ["*.tmp"]
        let stored = FileNode(id: "/root/docs/report.txt", name: "report.txt", isDirectory: false)
        let pattern = FileNode(id: "/root/x/scratch.tmp", name: "scratch.tmp", isDirectory: false)
        let plain = FileNode(id: "/root/docs/other.txt", name: "other.txt", isDirectory: false)
        #expect(manager.isNodeIgnored(stored, currentPath: "/root"))
        // Pattern matches must not read as node-ignored: this predicate drives the pane menu's
        // Ignore/Include label, and `toggleIgnored` can't except an item from a pattern, so an
        // "Include" label would promise an action the toggle can't deliver.
        #expect(!manager.isNodeIgnored(pattern, currentPath: "/root"))
        #expect(!manager.isNodeIgnored(plain, currentPath: "/root"))
    }

    // MARK: - Which pane's root the entries are measured from

    /// Two panes showing one folder through sources that land at different depths still mirror
    /// into the store, which is why `panesShareAPosition` doesn't compare raw focus paths. The same
    /// folder is `Family` in iCloud and `Documents/Family` in OneDrive; compared raw, Ignore would
    /// write nothing durable and the row would return after a relaunch.
    @MainActor
    @Test func aMixedPairShowingOneFolderStillWritesDurably() {
        let (manager, store) = makeManagerWithStore(
            mixed: (leftId: "iCloud", leftOpenAt: "", rightId: "OneDrive-X", rightOpenAt: "Documents"))

        manager.focusBoth(left: "Family", right: "Documents/Family")
        manager.ignoredPaths = ["draft.txt"]
        #expect(!store.rootRelativePaths.isEmpty,
                "a mixed pair on one folder wrote nothing durably")
    }

    /// The entries survive a pane swap, as the unordered pair key promises. Quoted against
    /// whichever source is on the left, one item is `Family/draft.txt` one way and
    /// `Documents/Family/draft.txt` the other, so a swap would match nothing and bring every
    /// ignored row back. Asserted through `effectiveIgnoredPaths`, since the promise is that the
    /// row stays hidden, not a particular spelling on disk.
    @MainActor
    @Test func theDurableSetSurvivesAPaneSwap() {
        let (manager, store) = makeManagerWithStore(
            mixed: (leftId: "iCloud", leftOpenAt: "", rightId: "OneDrive-X", rightOpenAt: "Documents"))

        manager.focusBoth(left: "Family", right: "Documents/Family")
        manager.ignoredPaths = ["draft.txt"]
        let written = store.rootRelativePaths
        #expect(manager.effectiveIgnoredPaths.contains("draft.txt"))

        // The swap, exactly as `swapPanes` performs it: the sources trade places and each pane's
        // position travels with the tree it indexes.
        manager.paneSourceId = { $0 ? "OneDrive-X" : "iCloud" }
        manager.paneOpenAt = { $0 ? "Documents" : "" }
        manager.leftRelativePath = "Documents/Family"
        manager.rightRelativePath = "Family"
        // Clear the session layer, or this test can't fail: `effectiveIgnoredPaths` is the union
        // of session and store, so a session entry would answer for the store. It is also what
        // happens: every navigation clears it, and a relaunch starts with it empty.
        manager.clearSessionIgnoredPaths()

        #expect(store.rootRelativePaths == written,
                "the swap rewrote the stored set rather than reading the same one")
        #expect(manager.effectiveIgnoredPaths.contains("draft.txt"),
                "the ignored row came back after a swap — the store was read against the other source's root")
    }

    /// The write side: ignoring one item from each orientation produces one entry. A second
    /// spelling would show in Settings as an entry the user can't recognise, and un-ignoring the
    /// visible row wouldn't remove it.
    @MainActor
    @Test func ignoringTheSameItemFromEitherOrientationWritesOneEntry() {
        let (manager, store) = makeManagerWithStore(
            mixed: (leftId: "iCloud", leftOpenAt: "", rightId: "OneDrive-X", rightOpenAt: "Documents"))

        manager.focusBoth(left: "Family", right: "Documents/Family")
        manager.ignoredPaths = ["draft.txt"]

        manager.paneSourceId = { $0 ? "OneDrive-X" : "iCloud" }
        manager.paneOpenAt = { $0 ? "Documents" : "" }
        manager.leftRelativePath = "Documents/Family"
        manager.rightRelativePath = "Family"
        manager.ignoredPaths = []          // clears the session layer for the new orientation
        manager.ignoredPaths = ["draft.txt"]

        #expect(store.rootRelativePaths.count == 1,
                "the two orientations wrote two spellings of one item: \(store.sortedPaths)")
    }

    /// The anchor follows the pair key's own ordering, not which pane is left. `pairKey` joins the
    /// two ids sorted, so the id that sorts first is the only anchor both panes can compute and a
    /// swap can't change. Ties and unknown ids fall back to the left pane.
    @MainActor
    @Test func theIgnoreAnchorFollowsTheSortedPairKey() {
        let (manager, _) = makeManagerWithStore(
            mixed: (leftId: "OneDrive-X", leftOpenAt: "Documents", rightId: "iCloud", rightOpenAt: ""))
        // "OneDrive-X" < "iCloud": uppercase sorts ahead of lowercase, and the key is built the
        // same way, so the left pane is the anchor here.
        #expect(manager.ignoreAnchorIsLeft)

        manager.paneSourceId = { $0 ? "iCloud" : "OneDrive-X" }
        #expect(!manager.ignoreAnchorIsLeft)

        // Unknown on either side, and the same source on both, fall back to the left pane.
        manager.paneSourceId = { _ in "" }
        #expect(manager.ignoreAnchorIsLeft)
        manager.paneSourceId = { _ in "iCloud" }
        #expect(manager.ignoreAnchorIsLeft)
    }
}
