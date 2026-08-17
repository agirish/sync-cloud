import Testing
import Foundation
@testable import FileExplorer
import Sync

/// Flipping a pane from Columns to Tree used to drop the user at the top of a tree rooted at the
/// pane's scope, with nothing on screen acknowledging the four columns they had just walked — the
/// two presentations hold "where you are" in different state (`PaneBrowsePath` against the outline's
/// expansion set), and only one of them was ever written.
///
/// `FileTreeView.carryOver` is that translation, and the stack is read, never consumed: flipping
/// back to Columns has to restore exactly the columns that were there.
@Suite struct PaneColumnCarryOverTests {

    private let root = "/Users/me/Documents"

    @Test func testOpensEveryFolderTheColumnsWereStandingIn() {
        let stack = PaneBrowsePath(components: ["Claude", "Projects", "Investing"])
        let carry = FileTreeView.carryOver([], stack: stack, treeRoot: root)

        #expect(carry.expanded == [
            "/Users/me/Documents/Claude",
            "/Users/me/Documents/Claude/Projects",
            "/Users/me/Documents/Claude/Projects/Investing",
        ])
        #expect(carry.deepest == "/Users/me/Documents/Claude/Projects/Investing",
                "the row brought into view is the folder the deepest column was listing")
    }

    /// The tree's root has no disclosure row, so a path for it in the expansion set is one nothing
    /// can ever match — and `expansionPruned` keeps it forever, being under the root by definition.
    @Test func testTheTreesOwnRootIsNotPutInTheExpansionSet() {
        let carry = FileTreeView.carryOver([], stack: PaneBrowsePath(components: ["Claude"]),
                                           treeRoot: root)
        #expect(!carry.expanded.contains(root))
        #expect(carry.expanded == ["/Users/me/Documents/Claude"])
    }

    /// Folders the user opened by hand are theirs. A carry-over adds to the set, exactly as a search
    /// reveal does — it is not a reset of the outline.
    @Test func testFoldersTheUserOpenedByHandSurvive() {
        let mine: Set<String> = ["/Users/me/Documents/Family", "/Users/me/Documents/Home"]
        let carry = FileTreeView.carryOver(mine, stack: PaneBrowsePath(components: ["Claude"]),
                                           treeRoot: root)
        #expect(carry.expanded.isSuperset(of: mine))
        #expect(carry.expanded.count == mine.count + 1)
    }

    /// A pane resting at its root has nothing to carry, and `deepest` being nil is what tells the
    /// caller to leave the scroll alone. Answering the root here would scroll a tree the user is
    /// already looking at back to its first row on every tab switch.
    @Test func testARestingStackCarriesNothingAndScrollsNowhere() {
        let carry = FileTreeView.carryOver(["/Users/me/Documents/Family"],
                                           stack: PaneBrowsePath(), treeRoot: root)
        #expect(carry.deepest == nil)
        #expect(carry.expanded == ["/Users/me/Documents/Family"], "an untouched set, not an emptied one")
    }

    /// A trailing slash on the root is the difference between `…/Documents/Claude` and
    /// `…/Documents//Claude`, and the second matches no row — the outline keys on `FileNode.id`.
    @Test func testTheRootIsNormalisedBeforeTheTrailIsBuilt() {
        let carry = FileTreeView.carryOver([], stack: PaneBrowsePath(components: ["Claude"]),
                                           treeRoot: root + "/")
        #expect(carry.expanded == ["/Users/me/Documents/Claude"])
    }

    // MARK: - The call site

    /// A rule extracted for testability is one revert from being unused — and this one is reached
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

    /// **The refusal while the tree is still arriving, which no picture here can show.**
    ///
    /// What the guard protects is the SCROLL: a `scrollTo` for a row the list does not hold yet is
    /// silently dropped, and the latch below then makes that failure permanent. An offscreen,
    /// never-key window's scroll position is not a reliable instrument — `PaneColumnsScrollTests`
    /// documents a test that stayed green with the reveal inert — so the render fixture asserts row
    /// ARRIVAL, exactly as the search-reveal suites do, and cannot see this. Removing the guard
    /// leaves that fixture green, which is why the scan exists rather than being redundant with it.
    @Test func testTheCarryRefusesWhileTheTreeIsStillArriving() throws {
        let source = try OrganizeScopeCallSiteTests.source("FileTreeView.swift")
        let carryBody = try OrganizeScopeCallSiteTests.body(of: "private func carryColumnsIntoTree",
                                                           in: source)
        #expect(carryBody.contains("guard !isLoading else { return }"),
                "the carry-over decides from a half-built tree again, and latches the result")
        // Refusing without re-asking is a silent failure with better manners — the pairing is the
        // point, and the Columns direction makes the same one.
        let arrival = try OrganizeScopeCallSiteTests.body(of: "private var paneList: some View",
                                                          in: source)
        #expect(arrival.contains("onChange(of: isLoading)"),
                "a carry refused mid-load is never re-asked when the load lands")
    }

    /// The scroll is gated on the stack having CHANGED, because the Tree branch appears on every tab
    /// switch and pane collapse — not only on a mode flip — and a scroll on each of those yanks a
    /// tree the user has since scrolled somewhere else.
    @Test func testTheScrollIsGatedOnTheStackHavingChanged() throws {
        let source = try OrganizeScopeCallSiteTests.source("FileTreeView.swift")
        let body = try OrganizeScopeCallSiteTests.body(of: "private func carryColumnsIntoTree", in: source)

        #expect(body.contains("guard carriedStack != browsePath else { return }"),
                "without this the carry-over re-scrolls on every appearance of the Tree branch")
        // And the expansion must happen BEFORE that gate — opening folders is idempotent, so it is
        // right on every appearance, and skipping it would leave the tree closed after a tab switch.
        let gate = try #require(body.range(of: "guard carriedStack != browsePath"))
        let assignment = try #require(body.range(of: "expanded = carry.expanded"))
        #expect(assignment.lowerBound < gate.lowerBound,
                "opening the folders is idempotent and belongs ahead of the scroll's gate")
    }
}
