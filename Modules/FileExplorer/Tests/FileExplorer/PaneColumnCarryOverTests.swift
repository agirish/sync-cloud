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

    /// `main` reads these two out of `OrganizeScopeCallSiteTests`, the hardened source-scan helper
    /// this line does not carry. Kept local rather than dropped: the scans below are what pin the
    /// ORDER of the arrival and the scroll's gate, neither of which a picture can show. Both
    /// guards that make a source scan honest are kept — an unreadable file fails rather than
    /// yielding an empty haystack, and a declaration that has been renamed fails rather than
    /// scanning nothing.
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)               // …/Tests/FileExplorer/<this>.swift
            .deletingLastPathComponent()                        // …/Tests/FileExplorer
            .deletingLastPathComponent()                        // …/Tests
            .deletingLastPathComponent()                        // …/FileExplorer (package)
            .appendingPathComponent("Sources/FileExplorer/FileTreeView.swift")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read FileTreeView.swift — the scans below would be vacuous")
        try #require(text.count > 500, "FileTreeView.swift is implausibly short — the scans would be near-vacuous")
        return text
    }

    /// One declaration's body, bounded by its closing brace rather than by a character count — a
    /// fixed window runs past a short body into the next member and answers about the wrong text.
    private func body(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "`\(declaration)` is gone — this scan would read nothing")
        var depth = 0
        var index = start.upperBound
        var opened = false
        while index < source.endIndex {
            if source[index] == "{" { depth += 1; opened = true }
            if source[index] == "}" {
                depth -= 1
                if opened, depth == 0 { return String(source[start.upperBound...index]) }
            }
            index = source.index(after: index)
        }
        throw CarryScanError.unterminated(declaration)
    }

    private enum CarryScanError: Error { case unterminated(String) }

    /// A rule extracted for testability is one revert from being unused — and this one is reached
    /// from a SwiftUI `onAppear` no unit test can drive. Source-level, with the blind spot that
    /// implies; the helper above fails loudly rather than scanning an empty haystack.
    @Test func testTheTreesArrivalActuallyCarriesTheColumnsOver() throws {
        let source = try source()
        let body = try body(of: "private var paneList: some View", in: source)

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
        let carryBody = try body(of: "private func carryColumnsIntoTree", in: try source())
        #expect(carryBody.contains("guard !isLoading else { return }"),
                "the carry-over decides from a half-built tree again, and latches the result")
        // Refusing without re-asking is a silent failure with better manners — the pairing is the
        // point, and the Columns direction makes the same one.
        let arrival = try body(of: "private var paneList: some View", in: try source())
        #expect(arrival.contains("onChange(of: isLoading)"),
                "a carry refused mid-load is never re-asked when the load lands")
    }

    /// The scroll is gated on the stack having CHANGED, because the Tree branch appears on every tab
    /// switch and pane collapse — not only on a mode flip — and a scroll on each of those yanks a
    /// tree the user has since scrolled somewhere else.
    @Test func testTheScrollIsGatedOnTheStackHavingChanged() throws {
        let source = try source()
        let body = try body(of: "private func carryColumnsIntoTree", in: source)

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
