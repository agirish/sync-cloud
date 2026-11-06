import Testing
import Foundation
import Events
@testable import Sync

/// `‹` and `›` serve two stacks: the column stack first, then the pane's focus history. That is
/// what makes the arrows work in a narrow pane, where the single column replaces its contents and
/// Back is the only way out.
///
/// Browsing must not reach the focus history early: a focus change reloads the tree and re-runs
/// the scan, so a Back that fell through too eagerly would re-scope the comparison when the user
/// only meant to step out of a folder. These tests pin the order and the boundary.
@MainActor
@Suite struct PaneBrowseNavigationTests {

    // MARK: - Order: columns before history

    /// A pane three columns deep with focus history behind it unwinds the columns first: they are
    /// the more recent navigation.
    @Test func testBackUnwindsColumnsBeforeTouchingFocusHistory() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Documents", isLeft: true)
        #expect(m.leftRelativePath == "Documents")

        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)

        m.goBack(isLeft: true, drawsColumns: true)
        #expect(m.leftBrowsePath.components == ["Invoices"])
        #expect(m.leftRelativePath == "Documents", "focus must not move while columns remain")

        m.goBack(isLeft: true, drawsColumns: true)
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.leftRelativePath == "Documents", "the last column pop must still not re-scope")

        // Only now does Back reach the focus history.
        m.goBack(isLeft: true, drawsColumns: true)
        #expect(m.leftRelativePath == "")
    }

    @Test func testCanGoBackIsTrueWhileInsideColumnsWithNoFocusHistory() {
        let m = FileSyncManager()
        #expect(m.canGoBack(isLeft: true, drawsColumns: true) == false)

        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        // Nothing was re-rooted, so the focus history is empty; the arrow must light up anyway or
        // push navigation has no way back.
        #expect(m.leftHistory.canGoBack == false)
        #expect(m.canGoBack(isLeft: true, drawsColumns: true) == true)
    }

    /// Forward is Back's inverse in the same order, so drilling, backing out and going forward
    /// returns you where you were instead of firing an unrelated focus jump.
    @Test func testForwardWalksBackIntoColumnsBeforeFocusHistory() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.leftBrowsePath.drill(into: "Invoices", atDepth: 1)

        m.goBack(isLeft: true, drawsColumns: true)
        m.goBack(isLeft: true, drawsColumns: true)
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.canGoForward(isLeft: true, drawsColumns: true) == true)

        m.goForward(isLeft: true, drawsColumns: true)
        m.goForward(isLeft: true, drawsColumns: true)
        #expect(m.leftBrowsePath.components == ["Documents", "Invoices"])
        #expect(m.canGoForward(isLeft: true, drawsColumns: true) == false)
    }

    /// Branching discards the forward stack, like a browser: drilling somewhere else after backing
    /// out must not leave `›` promising to return to the abandoned branch.
    @Test func testDrillingAfterBackingOutClearsForward() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.goBack(isLeft: true, drawsColumns: true)
        #expect(m.canGoForward(isLeft: true, drawsColumns: true) == true)

        m.leftBrowsePath.drill(into: "Photos", atDepth: 0)
        #expect(m.canGoForward(isLeft: true, drawsColumns: true) == false)
    }

    // MARK: - Panes stay independent

    @Test func testEachPaneUnwindsOnlyItsOwnColumns() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.rightBrowsePath.drill(into: "Photos", atDepth: 0)

        m.goBack(isLeft: true, drawsColumns: true)
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.rightBrowsePath.components == ["Photos"], "the sibling pane must not move")
    }

    // MARK: - Scope changes reset the stack

    /// Re-rooting replaces the tree the columns were walking. Keeping the stack would leave it
    /// naming folders relative to a root that no longer applies.
    @Test func testFocusOnResetsThatPanesColumns() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)
        m.rightBrowsePath.drill(into: "Photos", atDepth: 0)

        m.focusOn(relativePath: "Documents", isLeft: true)
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.rightBrowsePath.components == ["Photos"], "only the re-rooted pane resets")
    }

    /// `focusBoth` resets only the panes that actually move — matching how it pushes history.
    @Test func testFocusBothResetsOnlyThePanesThatMove() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Documents", isLeft: true)
        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)
        m.rightBrowsePath.drill(into: "Photos", atDepth: 0)

        // The left pane is already at "Documents"; the right one is not.
        m.focusBoth(relativePath: "Documents")
        #expect(m.leftBrowsePath.components == ["Invoices"], "a pane that didn't move keeps its columns")
        #expect(m.rightBrowsePath.isEmpty)
    }

    /// Changing the source on one pane must not close the other pane's open columns. The switched
    /// pane's stack names folders under a root it is leaving; the sibling's names folders still on
    /// screen.
    @Test func testRetargetPaneClearsOnlyItsOwnStack() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.rightBrowsePath.drill(into: "Photos", atDepth: 0)

        m.retargetPane(isLeft: false, landing: "")
        #expect(m.rightBrowsePath.isEmpty)
        #expect(m.leftBrowsePath.components == ["Documents"],
                "a source switch on the right pane closed the left pane's open columns")
    }

    /// The mirror, so neither side's polarity can be the one that is wrong.
    @Test func testRetargetPaneClearsOnlyItsOwnStackOnTheLeft() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.rightBrowsePath.drill(into: "Photos", atDepth: 0)

        m.retargetPane(isLeft: true, landing: "")
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.rightBrowsePath.components == ["Photos"])
    }

    /// The stack travels with the tree it indexes, like the history beside it.
    @Test func testSwapPanesCarriesTheColumnsAcross() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.rightBrowsePath.drill(into: "Photos", atDepth: 0)

        #expect(m.swapPanes() == true)
        #expect(m.leftBrowsePath.components == ["Photos"])
        #expect(m.rightBrowsePath.components == ["Documents"])
    }

    // MARK: - Pruning through the manager

    @Test func testPruneDropsAStackIntoADeletedFolder() {
        let m = FileSyncManager()
        // The pane's tree is loaded: a precondition of pruning, which every real republish meets.
        // The test below says why.
        m.lastLoadedLeftFocusPath = ""
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.leftBrowsePath.drill(into: "Gone", atDepth: 1)

        let documents = FileNode(id: "/r/Documents", name: "Documents", isDirectory: true, children: [])
        let index = PaneChildrenIndex(tree: PaneTree(side: .left, version: 1, nodes: [documents]), treeRoot: "/r")
        m.pruneBrowsePath(isLeft: true, against: index, treeRoot: "/r")

        #expect(m.leftBrowsePath.components == ["Documents"])
        #expect(m.leftBrowsePath.currentDirectory(treeRoot: "/r") == "/r/Documents")
    }

    /// A dropped tree is not an answer about which folders exist. `invalidateComparisonState`
    /// clears both trees synchronously, so re-pointing a pane publishes an empty tree one view
    /// update before the reload refills it. Pruning against that would flatten every stack to the
    /// root, so every browse-tab switch would lose the restored tab's columns.
    @Test func testAStackSurvivesAPublishFromATreeThatIsNotLoadedYet() {
        let m = FileSyncManager()
        m.lastLoadedLeftFocusPath = ""
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.leftBrowsePath.drill(into: "US", atDepth: 1)

        // What a tab switch does to the pane before its reload lands.
        m.invalidateComparisonState()

        let empty = PaneChildrenIndex(tree: PaneTree(side: .left, version: 2, nodes: []), treeRoot: "/r")
        m.pruneBrowsePath(isLeft: true, against: empty, treeRoot: "/r")

        #expect(m.leftBrowsePath.components == ["Documents", "US"],
                "the column stack was pruned against a tree that had been dropped, not against one that says the folders are gone")
    }

    /// The shallow-tree half. Progressive loading publishes the root's children with nothing under
    /// them before the deep walk finishes, and that publish sets `lastLoadedFocusPath` too. Guarding
    /// on the marker alone would prune against a one-level tree and cut the stack to its first
    /// component, so the guard also checks loading, as `pruneSelection`'s does.
    @Test func testAStackSurvivesTheShallowTreeProgressiveLoadingPublishesFirst() {
        let m = FileSyncManager()
        m.lastLoadedLeftFocusPath = ""
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.leftBrowsePath.drill(into: "US", atDepth: 1)
        m.isLoadingLeftTree = true

        // The shallow publish: Documents exists, nothing under it has been walked yet.
        let documents = FileNode(id: "/r/Documents", name: "Documents", isDirectory: true, children: [])
        let shallow = PaneChildrenIndex(tree: PaneTree(side: .left, version: 2, nodes: [documents]),
                                        treeRoot: "/r")
        m.pruneBrowsePath(isLeft: true, against: shallow, treeRoot: "/r")

        #expect(m.leftBrowsePath.components == ["Documents", "US"],
                "the stack was cut to its first component by a tree that is still loading")
    }

    /// So the guard can't widen into "never prune": a loaded, genuinely empty tree still collapses
    /// the stack, because that is an answer about which folders exist.
    @Test func testALoadedButEmptyTreeStillCollapsesTheStack() {
        let m = FileSyncManager()
        m.lastLoadedLeftFocusPath = ""
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)

        let empty = PaneChildrenIndex(tree: PaneTree(side: .left, version: 2, nodes: []), treeRoot: "/r")
        m.pruneBrowsePath(isLeft: true, against: empty, treeRoot: "/r")

        #expect(m.leftBrowsePath.components.isEmpty,
                "a loaded tree with nothing in it left the stack naming a folder that is gone")
    }

    // MARK: - The single-source rail shares the left pane's column stack

    // The rail renders through the left pane's state (focus, selection, history and browse path),
    // so a column stack built in Organize is still there in Compare. It survives only while it
    // describes real folders in the tree the pane has; these three tests pin that boundary.

    /// Continuity: no re-root, so the stack the rail built is the stack Compare shows.
    @Test func testTheRailsColumnStackSurvivesIntoCompareWhenTheRootIsUnchanged() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Inbox", isLeft: true)
        m.leftBrowsePath.drill(into: "Receipts", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)

        // Switching surfaces re-asserts the same focus. `focusOn` returns on an unchanged relative
        // path before its reset, which is what preserves the stack.
        m.focusOn(relativePath: "Inbox", isLeft: true)

        #expect(m.leftBrowsePath.components == ["Receipts", "2025"])
    }

    /// …but a lens that re-roots the rail is a different scope, and the stack must not ride along:
    /// its names were resolved against a tree that no longer applies.
    @Test func testARailReRootDropsTheColumnStack() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Inbox", isLeft: true)
        m.leftBrowsePath.drill(into: "Receipts", atDepth: 0)

        m.focusOn(relativePath: "Archive", isLeft: true)

        #expect(m.leftBrowsePath.isEmpty, "a re-root resets rather than prunes — new scope, not a changed one")
        #expect(m.leftRelativePath == "Archive")
    }

    /// And the surviving stack is still only as deep as the tree supports: a folder deleted while
    /// the rail was showing it is pruned on the next republish, so Compare cannot inherit a stack
    /// into a folder that is gone.
    @Test func testASharedStackIsStillPrunedAgainstTheTreeItLandsOn() {
        let m = FileSyncManager()
        m.lastLoadedLeftFocusPath = ""      // a republish only happens on a loaded tree
        m.leftBrowsePath.drill(into: "Receipts", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)

        // The republished tree has Receipts but no longer has 2025 under it.
        let receipts = FileNode(id: "/r/Receipts", name: "Receipts", isDirectory: true, children: [])
        let index = PaneChildrenIndex(tree: PaneTree(side: .left, version: 1, nodes: [receipts]), treeRoot: "/r")
        m.pruneBrowsePath(isLeft: true, against: index, treeRoot: "/r")

        #expect(m.leftBrowsePath.components == ["Receipts"])
    }

    /// Browsing must not clear session-ignored paths — that clear belongs to a change of
    /// comparison scope, and stepping out of a column changes only where you are looking.
    @Test func testSteppingOutOfAColumnKeepsIgnoredPaths() {
        let m = FileSyncManager()
        m.ignoredPaths = ["noisy.log"]

        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.goBack(isLeft: true, drawsColumns: true)
        #expect(m.ignoredPaths == ["noisy.log"], "a column pop is not a scope change")

        // A real scope change still clears them, so the assertion above isn't passing because
        // nothing ever clears.
        m.focusOn(relativePath: "Documents", isLeft: true)
        #expect(m.ignoredPaths.isEmpty)
    }
}
