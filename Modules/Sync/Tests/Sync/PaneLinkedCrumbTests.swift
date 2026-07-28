import Testing
import Foundation
import Events
@testable import Sync

/// The breadcrumb's both-panes route: ⌥-click, and every plain crumb click while the seam link is
/// on (which is the shipped default for anyone who has ever switched the link on — it is sticky).
///
/// This is the route that regressed when a pane's location was split into scope + browse position.
/// `PaneCombinedPathTests` pinned the single-pane routing; the linked route still went through
/// `focusBoth`, which knows only about the scope. With both panes scoped at their root — the normal
/// state, because walking into columns never re-roots — a click on the root crumb asked to focus
/// `""` while both panes already were focused on `""`, and `focusBoth`'s "nothing to do" guard
/// returned. Three columns deep, the crumb that should be the fastest way out did nothing at all.
///
/// So these tests are about *escape*: every crumb must be reachable from wherever the columns have
/// wandered, on both panes, and without a rescan when the folder is one the panes are already
/// showing.
@MainActor
@Suite struct PaneLinkedCrumbTests {

    private let otherRoot = "/other"

    /// The sibling pane has `Documents/Invoices` but no `2025` inside it, and no `Photos` at all.
    private func otherIndex() -> PaneChildrenIndex {
        let invoices = FileNode(id: "/other/Documents/Invoices", name: "Invoices", isDirectory: true,
                                children: [FileNode(id: "/other/Documents/Invoices/a.pdf", name: "a.pdf", isDirectory: false)])
        let documents = FileNode(id: "/other/Documents", name: "Documents", isDirectory: true, children: [invoices])
        return PaneChildrenIndex(tree: PaneTree(side: .right, version: 1, nodes: [documents]), treeRoot: otherRoot)
    }

    private func navigate(_ m: FileSyncManager, to combined: String, from isLeft: Bool = true) {
        m.navigateBothPanes(toCombinedPath: combined, from: isLeft,
                            otherIndex: otherIndex(), otherTreeRoot: otherRoot)
    }

    // MARK: - The regression

    /// The reported bug: linked panes, both scoped at their root, browsing three columns deep. The
    /// root crumb is the only one-click way home and it must take it.
    @Test func testTheRootCrumbLeavesTheColumnsOnBothPanes() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices", "2025"])
        m.rightBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices", "2025"])

        navigate(m, to: "")

        #expect(m.leftBrowsePath.isEmpty, "the clicked pane stayed in its columns")
        #expect(m.rightBrowsePath.isEmpty, "the linked pane stayed in its columns")
        #expect(m.leftRelativePath == "")
        #expect(m.rightRelativePath == "")
        #expect(m.leftHistory.entries == [""], "a browse move must not push history")
        #expect(m.rightHistory.entries == [""])
    }

    /// The same dead crumb one level up: the panes are scoped on a folder and browsing below it, so
    /// the crumb naming that scope is where "back to the folder I'm comparing" lives.
    @Test func testTheScopesOwnCrumbClosesTheColumnsOnBothPanes() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work", isLeft: true)
        m.focusOn(relativePath: "Work", isLeft: false)
        m.leftBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])
        m.rightBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])

        navigate(m, to: "Work")

        #expect(m.leftBrowsePath.isEmpty)
        #expect(m.rightBrowsePath.isEmpty)
        #expect(m.leftRelativePath == "Work", "the scope must survive — this is not a re-root")
        #expect(m.rightRelativePath == "Work")
        #expect(m.leftHistory.entries == ["", "Work"], "no history entry for a browse move")
        #expect(m.rightHistory.entries == ["", "Work"])
    }

    // MARK: - Skipping levels

    /// A crumb several levels up is a jump, not a step: it lands exactly where it was clicked
    /// rather than one column out.
    @Test func testAnAncestorCrumbSkipsStraightToItsFolder() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices", "2025"])
        m.rightBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices", "2025"])

        navigate(m, to: "Documents")

        #expect(m.leftBrowsePath.components == ["Documents"])
        #expect(m.rightBrowsePath.components == ["Documents"])
    }

    /// A crumb inside the scope stays a browse move on both panes: no re-root, so no tree reload
    /// and no rescan for a folder both panes are already showing.
    @Test func testACrumbInsideTheScopeNeverRerootsEitherPane() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work", isLeft: true)
        m.focusOn(relativePath: "Work", isLeft: false)
        m.leftBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])
        m.rightBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])

        navigate(m, to: "Work/Documents")

        #expect(m.leftRelativePath == "Work")
        #expect(m.rightRelativePath == "Work")
        #expect(m.leftBrowsePath.components == ["Documents"])
        #expect(m.rightBrowsePath.components == ["Documents"])
        #expect(m.leftHistory.entries == ["", "Work"])
        #expect(m.rightHistory.entries == ["", "Work"])
    }

    /// Above the scope there is nothing to browse to, so both panes genuinely re-root — the escape
    /// hatch `focusBoth` used to provide, kept intact.
    @Test func testACrumbAboveTheScopeRerootsBothPanes() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work/Invoices", isLeft: true)
        m.focusOn(relativePath: "Work/Invoices", isLeft: false)
        m.leftBrowsePath = PaneBrowsePath(components: ["2025"])
        m.rightBrowsePath = PaneBrowsePath(components: ["2025"])

        navigate(m, to: "Work")

        #expect(m.leftRelativePath == "Work")
        #expect(m.rightRelativePath == "Work")
        #expect(m.leftBrowsePath.isEmpty, "re-rooting resets the stack")
        #expect(m.rightBrowsePath.isEmpty)
        #expect(m.leftHistory.entries == ["", "Work/Invoices", "Work"])
        #expect(m.rightHistory.entries == ["", "Work/Invoices", "Work"])
    }

    // MARK: - The two panes are routed independently

    /// The panes' scopes need not agree — the link is about *location*, and each pane reaches the
    /// same location through whichever of its own halves owns it.
    @Test func testEachPaneIsRoutedByItsOwnScope() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Work", isLeft: false)   // only the right pane is narrowed
        m.leftBrowsePath = PaneBrowsePath(components: ["Work", "Documents", "Invoices"])
        m.rightBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])

        navigate(m, to: "Work/Documents")

        #expect(m.leftRelativePath == "", "the left pane browses there — its scope is the root")
        #expect(m.leftBrowsePath.components == ["Work", "Documents"])
        #expect(m.rightRelativePath == "Work", "the right pane is already scoped there")
        #expect(m.rightBrowsePath.components == ["Documents"])
        #expect(m.combinedRelativePath(isLeft: true) == m.combinedRelativePath(isLeft: false),
                "however they got there, both panes must report the same location")
    }

    @Test func testTheRightPaneCanDriveTheLinkToo() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])
        m.rightBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])

        navigate(m, to: "Documents", from: false)

        #expect(m.rightBrowsePath.components == ["Documents"])
        #expect(m.leftBrowsePath.components == ["Documents"])
    }

    // MARK: - Honesty about the sibling's tree

    /// The sibling gets the same pruning a mirrored column drill gets: the panes are compared
    /// because they differ, so a folder this pane has may be missing over there.
    @Test func testTheSiblingStopsWhereItsOwnTreeStops() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])

        navigate(m, to: "Documents/Invoices/2025")

        #expect(m.leftBrowsePath.components == ["Documents", "Invoices", "2025"],
                "the clicked pane goes where it was clicked, regardless of the sibling")
        #expect(m.rightBrowsePath.components == ["Documents", "Invoices"],
                "the sibling stops at the deepest folder it genuinely has")
    }

    /// Building the sibling's index is a full walk of its tree (~40k nodes in the app), and the
    /// commonest linked crumb click — home to the root — needs no index at all.
    @Test func testTheSiblingsIndexIsBuiltOnlyWhenThereIsAStackToPrune() {
        let m = FileSyncManager()
        m.leftBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])
        m.rightBrowsePath = PaneBrowsePath(components: ["Documents", "Invoices"])
        var built = 0

        m.navigateBothPanes(toCombinedPath: "", from: true,
                            otherIndex: { built += 1; return otherIndex() }(), otherTreeRoot: otherRoot)
        #expect(built == 0, "going home to the root paid for the sibling's whole tree")

        m.navigateBothPanes(toCombinedPath: "Documents", from: true,
                            otherIndex: { built += 1; return otherIndex() }(), otherTreeRoot: otherRoot)
        #expect(built == 1, "a stack that lands somewhere must still be checked against the sibling")
    }

    /// When the sibling re-roots, the tree its index describes is the one it just left — pruning
    /// the new stack against it would be checking the wrong folder. The republish prune covers it.
    @Test func testASiblingThatRerootsIsNotPrunedAgainstItsOldTree() {
        let m = FileSyncManager()
        m.focusOn(relativePath: "Elsewhere", isLeft: false)
        var built = 0

        m.navigateBothPanes(toCombinedPath: "Documents/Invoices/2025", from: true,
                            otherIndex: { built += 1; return otherIndex() }(), otherTreeRoot: otherRoot)

        #expect(m.rightRelativePath == "Documents/Invoices/2025", "above its scope — a re-root")
        #expect(built == 0, "the stale index must not be consulted, let alone built")
    }
}
