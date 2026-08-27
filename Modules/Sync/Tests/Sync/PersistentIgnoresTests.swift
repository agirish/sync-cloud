import Testing
import Foundation
@testable import Sync

/// Pins the two-layer ignore model: session edits mirror into the durable store in
/// root-relative coordinates, navigation clears only the session layer, the effective set
/// translates stored entries into the current focus, and the toggle/un-ignore entry points
/// keep both layers consistent.
@Suite struct PersistentIgnoresTests {

    @MainActor
    private func makeManagerWithStore() -> (FileSyncManager, IgnoredItemsStore, UserDefaults, String) {
        let suite = "PersistentIgnoresTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: IgnoredItemsStore.pairKey("left", "right"))
        let manager = FileSyncManager()
        manager.ignoredItemsStore = store
        return (manager, store, defaults, suite)
    }

    @MainActor
    @Test func testIgnoreAtRootMirrorsIntoStore() {
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        manager.ignoredPaths = ["junk", "node_modules"]
        #expect(store.rootRelativePaths == ["junk", "node_modules"])

        // Un-ignoring via the session layer removes from the store too.
        manager.ignoredPaths = ["node_modules"]
        #expect(store.rootRelativePaths == ["node_modules"])
    }

    @MainActor
    @Test func testIgnoreInSubfolderIsStoredRootRelative() {
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        manager.focusBoth(relativePath: "Docs/Work")
        manager.ignoredPaths = ["draft.txt"]
        #expect(store.rootRelativePaths == ["Docs/Work/draft.txt"])
    }

    @MainActor
    @Test func testDivergentPaneFociKeepIgnoresSessionOnly() {
        // With the panes on different folders a focus-relative path names DIFFERENT items on
        // the two sides, so there is no well-defined root-relative identity to store: the
        // durable mirror must stay out of it (both directions), leaving session behavior.
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

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
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

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
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        store.add(["Docs/draft.txt", "Docs/Sub/old", "Other/x", "Docs"])
        manager.focusOn(relativePath: "Docs", isLeft: true)
        // Entries under the focus translate; entries elsewhere — and the focus itself —
        // are dropped (navigating INTO an ignored folder shows its contents).
        #expect(manager.effectiveIgnoredPaths == ["draft.txt", "Sub/old"])
    }

    @MainActor
    @Test func testRememberOffKeepsSessionOnlyBehavior() {
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        store.add(["stored-entry"])
        manager.rememberIgnoredItems = false
        manager.ignoredPaths = ["session-entry"]
        // No mirroring in, no application of stored entries out.
        #expect(store.rootRelativePaths == ["stored-entry"])
        #expect(manager.effectiveIgnoredPaths == ["session-entry"])
    }

    @MainActor
    @Test func testToggleUnignoresDurableEntryTheSessionNeverHeld() {
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        // Ignored in a previous session: store holds it, session layer is empty.
        store.add(["junk"])
        #expect(manager.effectiveIgnoredPaths == ["junk"])

        manager.toggleIgnored(focusRelativePaths: ["junk"])
        #expect(store.rootRelativePaths.isEmpty)
        #expect(manager.effectiveIgnoredPaths.isEmpty)
    }

    @MainActor
    @Test func testToggleUnignoringChildRemovesCoveringAncestorEntry() {
        // "docs/report.txt" is effectively ignored via the "docs" entry, so the menu label
        // reads "Include in comparison". The toggle must agree: remove the covering entry
        // (from both layers), NOT insert the child's own path — which would leave the row
        // struck through and silently excluded even after "docs" is later un-ignored.
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

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
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        manager.ignoredPaths = ["docs", "a"]
        manager.toggleIgnored(focusRelativePaths: ["docs/report.txt", "a"])
        #expect(manager.ignoredPaths.isEmpty)
        #expect(store.rootRelativePaths.isEmpty)
    }

    @MainActor
    @Test func testToggleRoundTripIsIdentity() {
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        manager.toggleIgnored(focusRelativePaths: ["a", "b"])
        #expect(manager.effectiveIgnoredPaths == ["a", "b"])
        manager.toggleIgnored(focusRelativePaths: ["a", "b"])
        #expect(manager.effectiveIgnoredPaths.isEmpty)
        #expect(store.rootRelativePaths.isEmpty)
    }

    @MainActor
    @Test func testToggleIgnoresWhenAnyTargetIsVisible() {
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        manager.ignoredPaths = ["a"]
        manager.toggleIgnored(focusRelativePaths: ["a", "b"])
        #expect(manager.effectiveIgnoredPaths == ["a", "b"])
        #expect(store.rootRelativePaths == ["a", "b"])
    }

    @MainActor
    @Test func testUnignoreRootRelativeClearsBothLayers() {
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

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
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

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
        let (manager, store, defaults, suite) = makeManagerWithStore()
        defer { wipeDefaultsSuite(suite) }

        store.add(["docs/report.txt"])
        manager.ignorePatterns = ["*.tmp"]
        let stored = FileNode(id: "/root/docs/report.txt", name: "report.txt", isDirectory: false)
        let pattern = FileNode(id: "/root/x/scratch.tmp", name: "scratch.tmp", isDirectory: false)
        let plain = FileNode(id: "/root/docs/other.txt", name: "other.txt", isDirectory: false)
        #expect(manager.isNodeIgnored(stored, currentPath: "/root"))
        // Pattern matches must NOT read as node-ignored: this predicate drives the pane menu's
        // Ignore/Include label, and `toggleIgnored` cannot except an item from a pattern — a
        // pattern-derived "Include" label would promise an action the toggle can't deliver
        // (and its formUnion used to mirror a phantom entry into the durable store).
        #expect(!manager.isNodeIgnored(pattern, currentPath: "/root"))
        #expect(!manager.isNodeIgnored(plain, currentPath: "/root"))
    }

    // MARK: - Which pane's root the entries are measured from

    /// A pair whose two sources open at different depths, wired the way the app wires it.
    ///
    /// `leftId`/`rightId` are what `paneSourceId` answers and what the pair key is built from;
    /// `leftOpenAt`/`rightOpenAt` are what `paneOpenAt` answers. Everything the durable store does
    /// for a mixed pair depends on those four values agreeing with each other, which is exactly
    /// what nothing checked before.
    @MainActor
    private func makeMixedPair(
        leftId: String, leftOpenAt: String,
        rightId: String, rightOpenAt: String
    ) -> (FileSyncManager, IgnoredItemsStore, String) {
        let suite = "PersistentIgnoresTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: IgnoredItemsStore.pairKey(leftId, rightId))
        let manager = FileSyncManager()
        manager.ignoredItemsStore = store
        manager.paneSourceId = { $0 ? leftId : rightId }
        manager.paneOpenAt = { $0 ? leftOpenAt : rightOpenAt }
        return (manager, store, suite)
    }

    /// **Two panes showing the same folder through sources that land at different depths still
    /// mirror into the store**, which is the whole reason `panesShareAPosition` replaced a raw
    /// comparison of the two focus paths.
    ///
    /// iCloud lands at its root and OneDrive two components in, so the same folder is `Family` on
    /// one side and `Documents/Family` on the other. The raw test can never be true for such a
    /// pair, so Ignore worked for the session, wrote nothing, and the row was back after a relaunch
    /// with nothing anywhere saying why.
    @MainActor
    @Test func aMixedPairShowingOneFolderStillWritesDurably() {
        let (manager, store, suite) = makeMixedPair(
            leftId: "iCloud", leftOpenAt: "", rightId: "OneDrive-X", rightOpenAt: "Documents")
        defer { wipeDefaultsSuite(suite) }

        manager.focusBoth(left: "Family", right: "Documents/Family")
        manager.ignoredPaths = ["draft.txt"]
        #expect(!store.rootRelativePaths.isEmpty,
                "a mixed pair on one folder wrote nothing durably")
    }

    /// **The entries survive a pane swap, which is what the unordered pair key promises.**
    ///
    /// `pairKey` sorts its two ids so one key serves the pair in either orientation — free while
    /// both roots were documents folders, because a root-relative path then read the same from
    /// either side. It is not free now: quoted against whichever source happens to be on the left,
    /// the same item is `Family/draft.txt` one way and `Documents/Family/draft.txt` the other, so
    /// a swap re-read yesterday's entries in the other source's coordinates, matched nothing, and
    /// brought every ignored row back — the un-ignore direction, which is the damaging one.
    ///
    /// Asserted through `effectiveIgnoredPaths` rather than through the stored strings, because
    /// what the user is promised is that the row stays hidden, not that a particular spelling is
    /// on disk.
    @MainActor
    @Test func theDurableSetSurvivesAPaneSwap() {
        let (manager, store, suite) = makeMixedPair(
            leftId: "iCloud", leftOpenAt: "", rightId: "OneDrive-X", rightOpenAt: "Documents")
        defer { wipeDefaultsSuite(suite) }

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
        // **The session layer has to go, or this test cannot fail.** `effectiveIgnoredPaths` is the
        // union of the session set and the store, so a live session entry answers the question the
        // store is supposed to answer — the first draft of this test passed against the very defect
        // it was written for. Clearing it is also what actually happens: `clearSessionIgnoredPaths`
        // runs on every navigation, and a relaunch — the case the durable store exists for — starts
        // with the session layer empty.
        manager.clearSessionIgnoredPaths()

        #expect(store.rootRelativePaths == written,
                "the swap rewrote the stored set rather than reading the same one")
        #expect(manager.effectiveIgnoredPaths.contains("draft.txt"),
                "the ignored row came back after a swap — the store was read against the other source's root")
    }

    /// The same claim from the write side: ignoring the same item from each orientation must
    /// produce ONE entry, not one per orientation.
    ///
    /// This is the accumulation half of the swap defect. It is not merely cosmetic — a second
    /// spelling is an entry the Settings list shows, the user cannot recognise, and un-ignoring
    /// the visible row does not remove.
    @MainActor
    @Test func ignoringTheSameItemFromEitherOrientationWritesOneEntry() {
        let (manager, store, suite) = makeMixedPair(
            leftId: "iCloud", leftOpenAt: "", rightId: "OneDrive-X", rightOpenAt: "Documents")
        defer { wipeDefaultsSuite(suite) }

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

    /// **The anchor is chosen by the pair key's own ordering, not by which pane is left.**
    ///
    /// Directly, because it is the one decision every assertion above rests on and the shape of
    /// the answer matters: `pairKey` joins the two ids SORTED, so quoting entries against the id
    /// that sorts first is the only choice that both panes can compute and that a swap cannot
    /// change. Ties and unknown ids fall back to the left pane, which is what this did before the
    /// closure existed.
    @MainActor
    @Test func theIgnoreAnchorFollowsTheSortedPairKey() {
        let (manager, _, suite) = makeMixedPair(
            leftId: "OneDrive-X", leftOpenAt: "Documents", rightId: "iCloud", rightOpenAt: "")
        defer { wipeDefaultsSuite(suite) }
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
