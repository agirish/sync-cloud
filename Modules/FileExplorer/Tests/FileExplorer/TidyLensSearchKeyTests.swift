import Testing
import Foundation
@testable import FileExplorer

/// **Which slot the search writes to.**
///
/// `TidyView` keeps one query per lens, and it has two names for "which lens": `lens` is the
/// *workspace's* — always `.filing` inside Organize, whatever the rail is showing — and
/// `effectiveLens` resolves the rail item on top of it. Every read has always used the resolved
/// one. Two writes used the workspace's, and the fold that turned Duplicates and Rules from
/// workspaces into rail items turned that from a distinction without a difference into the only
/// reachable case:
///
///   * a chip's ✕ removed nothing from the list in front of you and overwrote To File's parked
///     query with the duplicates query minus one word;
///   * the "Nothing matches" dead-end's button cleared To File's query, collapsed To File's search
///     field, left the query that was actually hiding the rows standing, and never reset the type
///     filter — so the empty state redrew unchanged on every click.
///
/// Neither could be seen by the suites: the only test mounting the duplicates apparatus passes
/// `lens: .duplicates`, a configuration the app can no longer produce, in which the two names are
/// equal and both bugs vanish. So these are source-level, using the harness in
/// ``OrganizeScopeCallSiteTests`` — which names its file and fails when it cannot be read.
@Suite struct TidyLensSearchKeyTests {

    static func tidy() throws -> String { try OrganizeScopeCallSiteTests.source("TidyView.swift") }

    /// The general rule, which is what makes this more than two spot checks: a search slot is
    /// addressed either by `effectiveLens` or by a lens **named outright** (`.duplicates` for the
    /// reveal's own query, `.storage` when a build starts). Never by the bare `lens` variable —
    /// that is the one spelling that silently means "some other lens's slot".
    @Test func noSearchSlotIsAddressedByTheWorkspacesLens() throws {
        let source = OrganizeScopeCallSiteTests.codeOnly(try Self.tidy())
        for spelling in ["searchQueries[lens]",
                         "searchExpandedLenses.insert(lens)",
                         "searchExpandedLenses.remove(lens)",
                         "searchExpandedLenses.contains(lens)"] {
            #expect(!source.contains(spelling),
                    "\(spelling) addresses the workspace's lens, not the rail item the user is looking at")
        }
    }

    /// The positive half of the same claim, so the test above cannot pass by the search state
    /// having been renamed out from under it.
    @Test func theSearchSlotIsAddressedByTheResolvedLens() throws {
        let source = try Self.tidy()
        #expect(source.contains("searchQueries[effectiveLens]"),
                "no query slot is keyed on the resolved lens — has the search state been renamed?")
        #expect(source.contains("searchExpandedLenses.remove(effectiveLens)"))
    }

    /// The chip's ✕ edits the query the chip came from.
    @Test func removingAChipEditsTheLensTheChipWasOfferedFor() throws {
        let body = try OrganizeScopeCallSiteTests.body(of: "private func removeSearchChip(_ word: String) {",
                                                       in: try Self.tidy())
        #expect(body.contains("searchQueries[effectiveLens]"),
                "the ✕ writes back to a different lens's query than the one it read the chips from")
    }

    /// The dead-end's button clears the query that is hiding the rows, collapses that lens's field,
    /// and — on Duplicates — resets the type filter, which is the other thing that can be hiding
    /// them. All three keyed the same way, or the button half-works.
    @Test func theEmptyStateButtonClearsTheLensItIsShownFor() throws {
        let body = try OrganizeScopeCallSiteTests.body(
            of: "private func searchHidesAllState(total: Int, noun: String) -> some View {",
            in: try Self.tidy())
        #expect(body.contains("searchQueries[effectiveLens] = \"\""),
                "Clear Search clears a different lens's query than the one it is offered on")
        #expect(body.contains("searchExpandedLenses.remove(effectiveLens)"))
        #expect(body.contains("if effectiveLens == .duplicates { filter = .all }"),
                "the type filter is reset for the workspace's lens, so on Duplicates it never resets")
    }

    /// **The filter-only narrowing has its own sentence.** With a type filter set and no query at
    /// all, the old wording asserted a search that was not running and offered to clear it. The
    /// cause is resolved first, and the control names what it will actually do.
    @Test func aFilterOnlyEmptyStateSaysSoRatherThanBlamingASearch() throws {
        let body = try OrganizeScopeCallSiteTests.body(
            of: "private func searchHidesAllState(total: Int, noun: String) -> some View {",
            in: try Self.tidy())
        #expect(body.contains("let filterOnly = query.isEmpty && effectiveLens == .duplicates && filter != .all"),
                "the empty state no longer distinguishes a filter-only narrowing from a search")
        #expect(body.contains("Show All Kinds"),
                "a filter-only dead-end still offers to clear a search that isn't running")
    }
}
