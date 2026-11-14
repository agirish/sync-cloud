import Testing
import Foundation
@testable import FileExplorer
import Sync

/// Flipping a pane from Columns to Tree opens the folders the columns were standing in:
/// `FileTreeView.carryOver` translates `PaneBrowsePath` into the outline's expansion set. The stack
/// is read, never consumed, so flipping back restores exactly the columns that were there.
@Suite struct PaneColumnCarryOverTests {

    private let root = "/Users/me/Documents"

    @Test func testOpensEveryFolderTheColumnsWereStandingIn() {
        let stack = PaneBrowsePath(components: ["Claude", "Projects", "Investing"])
        let carry = FileTreeView.carryOver([], stack: stack, treeRoot: root, tree: [])

        #expect(carry.expanded == [
            "/Users/me/Documents/Claude",
            "/Users/me/Documents/Claude/Projects",
            "/Users/me/Documents/Claude/Projects/Investing",
        ])
        #expect(carry.deepest == "/Users/me/Documents/Claude/Projects/Investing",
                "the row brought into view is the folder the deepest column was listing")
    }

    /// The tree's root has no disclosure row, and `expansionPruned` would keep it forever.
    @Test func testTheTreesOwnRootIsNotPutInTheExpansionSet() {
        let carry = FileTreeView.carryOver([], stack: PaneBrowsePath(components: ["Claude"]),
                                           treeRoot: root, tree: [])
        #expect(!carry.expanded.contains(root))
        #expect(carry.expanded == ["/Users/me/Documents/Claude"])
    }

    /// Folders the user opened by hand are theirs. A carry-over adds to the set, as a search reveal
    /// does; it doesn't reset the outline.
    @Test func testFoldersTheUserOpenedByHandSurvive() {
        let mine: Set<String> = ["/Users/me/Documents/Family", "/Users/me/Documents/Home"]
        let carry = FileTreeView.carryOver(mine, stack: PaneBrowsePath(components: ["Claude"]),
                                           treeRoot: root, tree: [])
        #expect(carry.expanded.isSuperset(of: mine))
        #expect(carry.expanded.count == mine.count + 1)
    }

    /// A pane resting at its root carries nothing, and a nil `deepest` leaves the scroll alone, or
    /// every tab switch would scroll the tree back to its first row.
    @Test func testARestingStackCarriesNothingAndScrollsNowhere() {
        let carry = FileTreeView.carryOver(["/Users/me/Documents/Family"],
                                           stack: PaneBrowsePath(), treeRoot: root, tree: [])
        #expect(carry.deepest == nil)
        #expect(carry.expanded == ["/Users/me/Documents/Family"], "an untouched set, not an emptied one")
    }

    /// A trailing slash on the root would compose `…/Documents//Claude`, which matches no
    /// `FileNode.id`.
    @Test func testTheRootIsNormalisedBeforeTheTrailIsBuilt() {
        let carry = FileTreeView.carryOver([], stack: PaneBrowsePath(components: ["Claude"]),
                                           treeRoot: root + "/", tree: [])
        #expect(carry.expanded == ["/Users/me/Documents/Claude"])
    }

    // MARK: - Below a folder link

    /// Below a folder link a column's path isn't a row id: the walk lists children where the link
    /// leads (`ColumnsBelowALinkTests`), so a composed path would name no row.
    @Test func testFoldersBelowAFolderLinkAreOpenedByTheirRowsIds() {
        func dir(_ path: String, _ children: [FileNode] = []) -> FileNode {
            FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
        }
        let tree = [dir("/r/link", [dir("/r/link/sub", [dir("/t/sub/deeper", [dir("/t/sub/deeper/deepest")])])]),
                    dir("/r/plain", [dir("/r/plain/a")])]
        let carry = FileTreeView.carryOver([], stack: PaneBrowsePath(components: ["link", "sub", "deeper", "deepest"]),
                                           treeRoot: "/r", tree: tree)
        #expect(carry.expanded == ["/r/link", "/r/link/sub", "/t/sub/deeper", "/t/sub/deeper/deepest"])
        #expect(carry.deepest == "/t/sub/deeper/deepest")
        // An ordinary branch of the same tree carries exactly what composition gives.
        #expect(FileTreeView.carryOver([], stack: PaneBrowsePath(components: ["plain", "a"]), treeRoot: "/r",
                                       tree: tree).expanded == ["/r/plain", "/r/plain/a"])
    }

    /// A component the tree doesn't hold (a stack the republish hasn't pruned yet) keeps the path
    /// it composes to.
    @Test func testAComponentTheTreeDoesNotHoldKeepsItsComposedPath() {
        let tree = [FileNode(id: "/r/a", name: "a", isDirectory: true, children: [])]
        let carry = FileTreeView.carryOver([], stack: PaneBrowsePath(components: ["a", "gone"]), treeRoot: "/r",
                                           tree: tree)
        #expect(carry.expanded == ["/r/a", "/r/a/gone"])
        #expect(carry.deepest == "/r/a/gone")
    }

    // MARK: - The call site

    /// The carry-over is reached from an `onAppear` no unit test can drive, so this is a source scan.
    /// It refuses while the tree is still arriving (a `scrollTo` for a row not yet held is silently
    /// dropped, and the latch makes that permanent), and scrolls only when the stack changed, since
    /// the Tree branch appears on every tab switch.
    @Test func testTheTreesArrivalActuallyCarriesTheColumnsOver() throws {
        let source = try SourceText.fileExplorer("FileTreeView.swift")
        let arrival = try SourceText.body(of: "private var paneList: some View", in: source)
        let carry = try SourceText.body(of: "private func carryColumnsIntoTree", in: source)

        #expect(arrival.contains("carryColumnsIntoTree(proxy)"),
                "the Tree branch's arrival no longer carries a parked column stack over")
        // The order matters as much as the call: a search hit is a place asked for by name, and the
        // carry-over must stand down rather than scroll the tree away from it.
        #expect(arrival.contains("search.hit(at: searchHitIndex) == nil"),
                "the carry-over must be gated on there being no search hit to reveal instead")
        #expect(carry.contains("guard !isLoading else { return }"),
                "the carry-over decides from a half-built tree again, and latches the result")
        // A refusal must be re-asked when the load lands, or it is a silent failure. The Columns
        // direction pairs them the same way.
        #expect(arrival.contains("onChange(of: isLoading)"),
                "a carry refused mid-load is never re-asked when the load lands")
        #expect(carry.contains("guard carriedStack != browsePath else { return }"),
                "without this the carry-over re-scrolls on every appearance of the Tree branch")
        // The expansion comes before that gate: idempotent, so right on every appearance. Last, so a
        // missing range stops only this check.
        let gate = try #require(carry.range(of: "guard carriedStack != browsePath"))
        let assignment = try #require(carry.range(of: "expanded = carry.expanded"))
        #expect(assignment.lowerBound < gate.lowerBound,
                "opening the folders is idempotent and belongs ahead of the scroll's gate")
    }
}
