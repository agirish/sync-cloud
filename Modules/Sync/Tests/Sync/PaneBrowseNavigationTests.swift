import Testing
import Foundation
import Events
@testable import Sync

/// `‹` and `›` serve two stacks now: the column stack first, then the pane's focus history. That
/// unification is the whole reason the arrows work in a narrow pane, where the single column
/// replaces its contents and Back is the only way out.
///
/// The risk it introduces is precise: browsing must never reach the *focus* history, because a
/// focus change reloads the tree and re-runs the scan for a different subfolder. A Back that fell
/// through too eagerly would re-scope the comparison when the user only meant to step out of a
/// folder. These tests pin the order, the fall-through, and the boundary between them.
@MainActor
@Suite struct PaneBrowseNavigationTests {

    // MARK: - Order: columns before history

    /// The core rule. A pane three columns deep with focus history behind it must unwind the
    /// columns first — they are the more recent navigation.
    @Test func testBackUnwindsColumnsBeforeTouchingFocusHistory() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Documents", isLeft: true)
        #expect(m.leftRelativePath == "Documents")

        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)

        m.goBack(isLeft: true)
        #expect(m.leftBrowsePath.components == ["Invoices"])
        #expect(m.leftRelativePath == "Documents", "focus must not move while columns remain")

        m.goBack(isLeft: true)
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.leftRelativePath == "Documents", "the last column pop must still not re-scope")

        // Only now does Back reach the focus history.
        m.goBack(isLeft: true)
        #expect(m.leftRelativePath == "")
    }

    @Test func testCanGoBackIsTrueWhileInsideColumnsWithNoFocusHistory() {
        let m = FileSyncManager()
        #expect(m.canGoBack(isLeft: true) == false)

        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        // Nothing was re-rooted, so the focus history is still empty — the arrow must light up
        // anyway or push navigation has no way back.
        #expect(m.leftHistory.canGoBack == false)
        #expect(m.canGoBack(isLeft: true) == true)
    }

    /// Forward is Back's inverse in the same order, so drilling, backing out and going forward
    /// returns you where you were instead of firing an unrelated focus jump.
    @Test func testForwardWalksBackIntoColumnsBeforeFocusHistory() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.leftBrowsePath.drill(into: "Invoices", atDepth: 1)

        m.goBack(isLeft: true)
        m.goBack(isLeft: true)
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.canGoForward(isLeft: true) == true)

        m.goForward(isLeft: true)
        m.goForward(isLeft: true)
        #expect(m.leftBrowsePath.components == ["Documents", "Invoices"])
        #expect(m.canGoForward(isLeft: true) == false)
    }

    /// Branching discards the forward stack, like a browser: drilling somewhere else after backing
    /// out must not leave `›` promising to return to the abandoned branch.
    @Test func testDrillingAfterBackingOutClearsForward() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.goBack(isLeft: true)
        #expect(m.canGoForward(isLeft: true) == true)

        m.leftBrowsePath.drill(into: "Photos", atDepth: 0)
        #expect(m.canGoForward(isLeft: true) == false)
    }

    // MARK: - Panes stay independent

    @Test func testEachPaneUnwindsOnlyItsOwnColumns() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.rightBrowsePath.drill(into: "Photos", atDepth: 0)

        m.goBack(isLeft: true)
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

    @Test func testResetNavigationClearsBothStacks() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.rightBrowsePath.drill(into: "Photos", atDepth: 0)

        m.resetNavigation()
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.rightBrowsePath.isEmpty)
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
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        m.leftBrowsePath.drill(into: "Gone", atDepth: 1)

        let documents = FileNode(id: "/r/Documents", name: "Documents", isDirectory: true, children: [])
        let index = PaneChildrenIndex(tree: PaneTree(side: .left, version: 1, nodes: [documents]), treeRoot: "/r")
        m.pruneBrowsePath(isLeft: true, against: index, treeRoot: "/r")

        #expect(m.leftBrowsePath.components == ["Documents"])
        #expect(m.leftBrowsePath.currentDirectory(treeRoot: "/r") == "/r/Documents")
    }

    // MARK: - The single-source rail shares the left pane's column stack

    // The rail renders through the left pane's state — focus, selection, history AND browse path —
    // so a column stack built in Organize is still there when the user switches to Compare. That is
    // deliberate continuity, but until now nothing pinned WHICH half of it is deliberate: the stack
    // survives only while it still describes real folders in the tree the pane actually has. These
    // three tests fix that boundary, so a future change to the rail cannot quietly turn shared
    // continuity into a stack pointing at the wrong tree.

    /// Continuity: no re-root, so the stack the rail built is the stack Compare shows.
    @Test func testTheRailsColumnStackSurvivesIntoCompareWhenTheRootIsUnchanged() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Inbox", isLeft: true)
        m.leftBrowsePath.drill(into: "Receipts", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)

        // Switching surfaces re-asserts the same focus. `focusOn` guards on an unchanged relative
        // path and returns BEFORE its reset, which is exactly what preserves the stack.
        m.focusOn(relativePath: "Inbox", isLeft: true)

        #expect(m.leftBrowsePath.components == ["Receipts", "2025"])
    }

    /// …but a lens that re-roots the rail is a different scope, and the stack must NOT ride along:
    /// its component names were resolved against a tree that no longer applies.
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
        m.goBack(isLeft: true)
        #expect(m.ignoredPaths == ["noisy.log"], "a column pop is not a scope change")

        // A real scope change still clears them, so the distinction is doing work rather than
        // this assertion passing because nothing ever clears.
        m.focusOn(relativePath: "Documents", isLeft: true)
        #expect(m.ignoredPaths.isEmpty)
    }
}
