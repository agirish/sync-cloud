import Testing
import Foundation
@testable import FileExplorer
import Sync

/// Flipping a pane from Columns to Tree opens the folders the columns were standing in. The two
/// presentations hold "where you are" in different state (`PaneBrowsePath` against the outline's
/// expansion set), and without a translation the user would land at the top of the tree with
/// nothing acknowledging the columns they had walked.
///
/// `FileTreeView.carryOver` is that translation, and the stack is read, never consumed: flipping
/// back to Columns has to restore exactly the columns that were there.
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

    /// The tree's root has no disclosure row, so a path for it in the expansion set matches
    /// nothing, and `expansionPruned` would keep it forever, being under the root by definition.
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

    /// A pane resting at its root has nothing to carry, and `deepest` being nil is what tells the
    /// caller to leave the scroll alone. Answering the root here would scroll a tree the user is
    /// already looking at back to its first row on every tab switch.
    @Test func testARestingStackCarriesNothingAndScrollsNowhere() {
        let carry = FileTreeView.carryOver(["/Users/me/Documents/Family"],
                                           stack: PaneBrowsePath(), treeRoot: root, tree: [])
        #expect(carry.deepest == nil)
        #expect(carry.expanded == ["/Users/me/Documents/Family"], "an untouched set, not an emptied one")
    }

    /// A trailing slash on the root is the difference between `…/Documents/Claude` and
    /// `…/Documents//Claude`, and the second matches no row, since the outline keys on
    /// `FileNode.id`.
    @Test func testTheRootIsNormalisedBeforeTheTrailIsBuilt() {
        let carry = FileTreeView.carryOver([], stack: PaneBrowsePath(components: ["Claude"]),
                                           treeRoot: root + "/", tree: [])
        #expect(carry.expanded == ["/Users/me/Documents/Claude"])
    }

    // MARK: - Below a folder link

    /// The Tree opens rows by id, and below a folder link a column's path isn't one. The walk lists
    /// `/r/link/sub`'s children where the link leads (`ColumnsBelowALinkTests` measures it on a
    /// real link), so a composed `/r/link/sub/deeper` would name no row: the Tree would open down
    /// to `sub` and scroll nowhere.
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

    /// A rule extracted for testability is one revert from being unused, and this one is reached
    /// from a SwiftUI `onAppear` no unit test can drive. Source-level, with the blind spot that
    /// implies; the helper it borrows fails loudly rather than scanning an empty haystack.
    @Test func testTheTreesArrivalActuallyCarriesTheColumnsOver() throws {
        let source = try OrganizeScopeCallSiteTests.source("FileTreeView.swift")
        let body = try OrganizeScopeCallSiteTests.body(of: "private var paneList: some View", in: source)

        #expect(body.contains("carryColumnsIntoTree(proxy)"),
                "the Tree branch's arrival no longer carries a parked column stack over")
        // The order matters as much as the call: a search hit is a place asked for by name, and the
        // carry-over must stand down rather than scroll the tree away from it.
        #expect(body.contains("search.hit(at: searchHitIndex) == nil"),
                "the carry-over must be gated on there being no search hit to reveal instead")
    }

    /// The refusal while the tree is still arriving, which no picture here can show. The guard
    /// protects the scroll: a `scrollTo` for a row the list doesn't hold yet is silently dropped,
    /// and the latch then makes that permanent. The render fixture asserts row arrival, since an
    /// offscreen, never-key window's scroll position isn't a reliable instrument, so it stays green
    /// with the guard removed. That is why this scan exists.
    @Test func testTheCarryRefusesWhileTheTreeIsStillArriving() throws {
        let source = try OrganizeScopeCallSiteTests.source("FileTreeView.swift")
        let carryBody = try OrganizeScopeCallSiteTests.body(of: "private func carryColumnsIntoTree",
                                                           in: source)
        #expect(carryBody.contains("guard !isLoading else { return }"),
                "the carry-over decides from a half-built tree again, and latches the result")
        // A refusal must be re-asked when the load lands, or it is a silent failure. The Columns
        // direction pairs them the same way.
        let arrival = try OrganizeScopeCallSiteTests.body(of: "private var paneList: some View",
                                                          in: source)
        #expect(arrival.contains("onChange(of: isLoading)"),
                "a carry refused mid-load is never re-asked when the load lands")
    }

    /// The scroll is gated on the stack having changed, because the Tree branch appears on every
    /// tab switch and pane collapse, not only on a mode flip, and scrolling on each would yank a
    /// tree the user has since scrolled elsewhere.
    @Test func testTheScrollIsGatedOnTheStackHavingChanged() throws {
        let source = try OrganizeScopeCallSiteTests.source("FileTreeView.swift")
        let body = try OrganizeScopeCallSiteTests.body(of: "private func carryColumnsIntoTree", in: source)

        #expect(body.contains("guard carriedStack != browsePath else { return }"),
                "without this the carry-over re-scrolls on every appearance of the Tree branch")
        // And the expansion must happen before that gate: opening folders is idempotent, so it is
        // right on every appearance, and skipping it would leave the tree closed after a tab
        // switch.
        let gate = try #require(body.range(of: "guard carriedStack != browsePath"))
        let assignment = try #require(body.range(of: "expanded = carry.expanded"))
        #expect(assignment.lowerBound < gate.lowerBound,
                "opening the folders is idempotent and belongs ahead of the scroll's gate")
    }
}
