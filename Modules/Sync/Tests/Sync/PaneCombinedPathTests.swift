import Testing
import Foundation
import Events
@testable import Sync

/// The header renders one location, but a pane holds two: its comparison scope and where it is
/// browsing inside it. Joining them is what stops the path line describing a folder the pane is not
/// showing; splitting a click back apart is what stops a crumb inside the scope triggering a
/// rescan it does not need.
@MainActor
@Suite struct PaneCombinedPathTests {

    @Test func testJoinsScopeAndBrowsePosition() {
        let m = FileSyncManager()
        #expect(m.combinedRelativePath(isLeft: true) == "")

        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)
        #expect(m.combinedRelativePath(isLeft: true) == "Documents", "at the root scope, browsing is the whole path")

        m.focusOn(relativePath: "Work", isLeft: true)   // resets the stack
        #expect(m.combinedRelativePath(isLeft: true) == "Work")

        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)
        #expect(m.combinedRelativePath(isLeft: true) == "Work/Invoices/2025")
    }

    /// A crumb inside the scope is a browse move: it must not re-root, because re-rooting reloads
    /// the tree and re-runs the scan for a folder the pane is already showing.
    @Test func testCrumbInsideTheScopeOnlyMovesTheColumns() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work", isLeft: true)
        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)
        m.leftBrowsePath.drill(into: "2025", atDepth: 1)

        m.navigatePane(isLeft: true, toCombinedPath: "Work/Invoices", drawsColumns: true)
        #expect(m.leftRelativePath == "Work", "scope must not move")
        #expect(m.leftBrowsePath.components == ["Invoices"])

        // The scope's own crumb drops back to the resting column, still without re-rooting.
        m.navigatePane(isLeft: true, toCombinedPath: "Work", drawsColumns: true)
        #expect(m.leftRelativePath == "Work")
        #expect(m.leftBrowsePath.isEmpty)
    }

    /// A crumb *above* the scope is the only way back out, so it genuinely re-roots.
    @Test func testCrumbAboveTheScopeReRoots() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work/Invoices", isLeft: true)
        m.leftBrowsePath.drill(into: "2025", atDepth: 0)

        m.navigatePane(isLeft: true, toCombinedPath: "Work", drawsColumns: true)
        #expect(m.leftRelativePath == "Work")
        #expect(m.leftBrowsePath.isEmpty, "re-rooting resets the stack")
    }

    @Test func testRootCrumbFromTheRootScopeIsABrowseMove() {
        let m = FileSyncManager()
        m.leftBrowsePath.drill(into: "Documents", atDepth: 0)

        m.navigatePane(isLeft: true, toCombinedPath: "", drawsColumns: true)
        #expect(m.leftRelativePath == "")
        #expect(m.leftBrowsePath.isEmpty)
    }

    /// Prefix matching must respect the path boundary, or a sibling scope whose name merely starts
    /// the same ("Work" vs "Workshop") would be mistaken for a folder inside it.
    @Test func testSiblingScopeSharingANamePrefixIsNotTreatedAsInside() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work", isLeft: true)
        m.leftBrowsePath.drill(into: "Invoices", atDepth: 0)

        m.navigatePane(isLeft: true, toCombinedPath: "Workshop", drawsColumns: true)
        #expect(m.leftRelativePath == "Workshop", "a sibling is a re-root, not a browse move")
        #expect(m.leftBrowsePath.isEmpty)
    }

    // MARK: - Tree draws no columns

    /// The reported bug, in the model: a pane flipped to Tree kept its header reading the folder
    /// the columns were last parked in — `Documents/Claude/Projects/Investing` over a tree sitting
    /// at its root. Tree lists the scope whole, so the scope is where that pane *is*.
    @Test func testATreePaneIsAtItsScopeNotWhereItsParkedColumnsStopped() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Claude", isLeft: true)
        m.leftBrowsePath.drill(into: "Projects", atDepth: 0)
        m.leftBrowsePath.drill(into: "Investing", atDepth: 1)

        #expect(m.paneLocation(isLeft: true, drawsColumns: true) == "Claude/Projects/Investing")
        #expect(m.paneLocation(isLeft: true, drawsColumns: false) == "Claude",
                "a tree pane's header must not name a folder only its parked columns knew about")

        // Parked, not cleared: the whole reason the two answers differ is that flipping back to
        // Columns has to restore the columns *and* the path that describes them.
        #expect(m.leftBrowsePath.components == ["Projects", "Investing"])
        #expect(m.paneLocation(isLeft: true, drawsColumns: true) == "Claude/Projects/Investing")
    }

    /// A tree pane at its root has nothing below the root crumb, which is the shape the screenshot
    /// showed — and the one place a stale stack was loudest.
    @Test func testATreePaneAtItsRootReadsAsTheRootEvenWithADeepStackParked() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Home", "Accessories"])

        #expect(m.paneLocation(isLeft: true, drawsColumns: false) == "")
        #expect(m.paneLocation(isLeft: true, drawsColumns: true) == "Home/Accessories")
    }

    /// In Tree every crumb and quick-jump target is a re-root: routing one into the stack wrote to
    /// state the pane draws nowhere, so the click landed on nothing at all. Re-rooting is also what
    /// puts the move on the back stack, where a navigation belongs.
    @Test func testATreeCrumbReRootsRatherThanMovingAStackItCannotDraw() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Home"])

        m.navigatePane(isLeft: true, toCombinedPath: "Family", drawsColumns: false)
        #expect(m.leftRelativePath == "Family", "the tree must re-root, not move an invisible stack")
        #expect(m.leftBrowsePath.isEmpty, "re-rooting resets the stack")
        #expect(m.canGoBack(isLeft: true, drawsColumns: false), "a tree navigation must be undoable by Back")
    }

    /// The same click in Columns is a browse move — the two presentations really do route the same
    /// crumb differently, which is why the flag is threaded rather than assumed.
    @Test func testTheSameCrumbIsABrowseMoveInColumns() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Home"])

        m.navigatePane(isLeft: true, toCombinedPath: "Family", drawsColumns: true)
        #expect(m.leftRelativePath == "", "columns must not re-root inside the scope")
        #expect(m.leftBrowsePath.components == ["Family"])
    }

    /// Clicking the folder a tree is already rooted at must not stack a history entry that makes
    /// Back appear to stall — and it must leave the parked stack alone. The Columns branch for the
    /// same path drops the stack deliberately (that crumb *means* "back to the resting column"), so
    /// a tree click routed through it would silently throw away the columns waiting to be flipped
    /// back to.
    @Test func testATreeCrumbForTheFolderItIsAlreadyRootedAtChangesNothing() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Claude", isLeft: true)
        m.leftBrowsePath = PaneBrowsePath(components: ["Projects", "Investing"])
        let backBefore = m.canGoBack(isLeft: true, drawsColumns: false)

        m.navigatePane(isLeft: true, toCombinedPath: "Claude", drawsColumns: false)
        #expect(m.leftRelativePath == "Claude")
        #expect(m.canGoBack(isLeft: true, drawsColumns: false) == backBefore, "a dead click must not grow the history")
        #expect(m.leftBrowsePath.components == ["Projects", "Investing"],
                "the parked columns must survive a click that moved nothing")
    }

    /// `‹` in Tree: it must move the history, not spend the click unwinding columns nobody can see.
    /// Three deep before flipping to Tree, Back used to do nothing three times over — and quietly
    /// ate the stack that the flip back to Columns was going to restore.
    @Test func testBackInTreeMovesTheHistoryAndLeavesTheParkedColumnsAlone() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Claude", isLeft: true)
        m.leftBrowsePath = PaneBrowsePath(components: ["Projects", "Investing"])

        m.goBack(isLeft: true, drawsColumns: false)
        #expect(m.leftRelativePath == "", "one Back must undo the one real navigation")
        #expect(m.leftBrowsePath.components == ["Projects", "Investing"], "the parked stack is not Back's to spend")

        // The same pane in Columns really does step out of a column first — the branch that is
        // right there and wrong here.
        m.focusOn(relativePath: "Claude", isLeft: true)
        m.leftBrowsePath = PaneBrowsePath(components: ["Projects", "Investing"])
        m.goBack(isLeft: true, drawsColumns: true)
        #expect(m.leftRelativePath == "Claude", "columns unwind before the history moves")
        #expect(m.leftBrowsePath.components == ["Projects"])
    }

    /// The arrow's enablement has to agree with what pressing it does, or `‹` lights up for a move
    /// that changes nothing on screen.
    @Test func testTheBackArrowIsNotLitByAStackTheTreeDoesNotDraw() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Home", "Accessories"])

        #expect(m.canGoBack(isLeft: true, drawsColumns: true), "columns can step back out")
        #expect(!m.canGoBack(isLeft: true, drawsColumns: false),
                "a tree at its root with no history has nowhere to go back to")

        m.leftBrowsePath.popLast()
        #expect(m.canGoForward(isLeft: true, drawsColumns: true), "columns can step back in")
        #expect(!m.canGoForward(isLeft: true, drawsColumns: false))
    }

    /// The presentation is per pane, so a linked crumb click is genuinely two different moves at
    /// once. Asking the clicked pane's mode on the sibling's behalf is the bug this rules out.
    @Test func testLinkedPanesEachRouteThroughTheirOwnPresentation() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Home"])
        m.rightBrowsePath = PaneBrowsePath(components: ["Home"])

        // The sibling really has `Family`, so the prune that follows a browse move keeps it — this
        // test is about routing, and an index that pruned the stack away would hide the answer.
        let family = FileNode(id: "/other/Family", name: "Family", isDirectory: true, children: [])
        m.navigateBothPanes(toCombinedPath: "Family", from: true,
                            drawsColumns: false, otherDrawsColumns: true,
                            otherIndex: PaneChildrenIndex(
                                tree: PaneTree(side: .right, version: 1, nodes: [family]),
                                treeRoot: "/other"),
                            otherTreeRoot: "/other")

        #expect(m.leftRelativePath == "Family", "the tree side re-roots")
        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.rightRelativePath == "", "the columns side must not re-root")
        #expect(m.rightBrowsePath.components == ["Family"])
    }

    @Test func testEachPaneJoinsItsOwnHalves() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Left", isLeft: true)
        m.focusOn(relativePath: "Right", isLeft: false)
        m.leftBrowsePath.drill(into: "A", atDepth: 0)
        m.rightBrowsePath.drill(into: "B", atDepth: 0)

        #expect(m.combinedRelativePath(isLeft: true) == "Left/A")
        #expect(m.combinedRelativePath(isLeft: false) == "Right/B")
    }
}
