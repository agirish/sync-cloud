import Testing
import Foundation
@testable import FileExplorer

/// Which slot the search writes to.
///
/// `LensWorkspaceView` keeps one query per lens and has two names for "which lens": `lens` is the
/// workspace's (always `.filing` inside Organize, whatever the rail shows), and `effectiveLens`
/// resolves the rail item on top of it. A write keyed on `lens` lands in To File's slot: a chip's ✕
/// would rewrite To File's parked query, and the "Nothing matches" button would clear To File's
/// query and leave the one hiding the rows.
///
/// Source-level, through ``SourceText`` (which names its file and fails when it can't read it),
/// because the only mounted suite with the duplicates apparatus passes `lens: .duplicates`, where
/// the two names are equal.
@Suite struct LensSearchKeyTests {

    static func workspaceSource() throws -> String { try SourceText.fileExplorer("LensWorkspaceView.swift") }

    /// The general rule: a search slot is addressed by `effectiveLens` or by a lens named outright
    /// (`.duplicates` for the reveal's own query, `.storage` when a build starts), never by the
    /// bare `lens` variable, which silently means some other lens's slot.
    @Test func noSearchSlotIsAddressedByTheWorkspacesLens() throws {
        let source = SourceText.codeOnly(try Self.workspaceSource())
        // `[lens,` covers the `[_, default: ""]` subscript form the file uses elsewhere
        // (`searchQueries[.duplicates, default: ""]`), the likeliest way a bare `lens` comes back.
        for spelling in ["searchQueries[lens]",
                         "searchQueries[lens,",
                         "searchExpandedLenses.insert(lens)",
                         "searchExpandedLenses.remove(lens)",
                         "searchExpandedLenses.contains(lens)"] {
            #expect(!source.contains(spelling),
                    "\(spelling) addresses the workspace's lens, not the rail item the user is looking at")
        }
    }

    /// The chip's ✕ edits the query the chip came from.
    @Test func removingAChipEditsTheLensTheChipWasOfferedFor() throws {
        let body = try SourceText.body(of: "private func removeSearchChip(_ word: String) {",
                                                       in: try Self.workspaceSource())
        #expect(body.contains("searchQueries[effectiveLens]"),
                "the ✕ writes back to a different lens's query than the one it read the chips from")
    }

    /// The dead-end's button clears the query hiding the rows, collapses that lens's field, and on
    /// Duplicates resets the type filter, the other thing that can hide them. All three keyed the
    /// same way, or the button half-works. Also the positive half of the ban above, so the ban
    /// cannot pass by the search state having been renamed out from under it.
    @Test func theEmptyStateButtonClearsTheLensItIsShownFor() throws {
        let body = try SourceText.body(
            of: "private func searchHidesAllState(total: Int, noun: String) -> some View {",
            in: try Self.workspaceSource())
        #expect(body.contains("searchQueries[effectiveLens] = \"\""),
                "Clear Search clears a different lens's query than the one it is offered on")
        #expect(body.contains("searchExpandedLenses.remove(effectiveLens)"))
        #expect(body.contains("if effectiveLens == .duplicates { filter = .all }"),
                "the type filter is reset for the workspace's lens, so on Duplicates it never resets")
    }

    /// With a type filter set and no query, the empty state says the filter is the cause rather
    /// than blaming a search that isn't running, and its control names what it will actually do.
    @Test func aFilterOnlyEmptyStateSaysSoRatherThanBlamingASearch() throws {
        let view = try Self.workspaceSource()
        let body = try SourceText.body(
            of: "private func searchHidesAllState(total: Int, noun: String) -> some View {",
            in: view)
        // The cause, not the spelling: the branch is decided by "no query and the type filter is
        // narrowing", and names the filter.
        #expect(body.contains("let filterOnly = query.isEmpty && filterIsNarrowing && total > 0"),
                "the empty state no longer distinguishes a filter-only narrowing from a search")
        // The exact label, quoted, because `"Show All Kinds".contains("Show All")` is true. The
        // filter's own name for that option is "All", so "Kinds" must not appear.
        #expect(body.contains("\"Show All\" : \"Clear Search\""),
                "a filter-only dead-end still offers to clear a search that isn't running")
        #expect(!body.contains("Show All Kinds"), "the button names a choice the filter does not offer")
        #expect(body.contains("filter.label"), "the filter-only message does not name the filter")

        // The cause is resolved before the scope's sentence. `filterOnly` needs an empty query, so
        // sending every empty query to `scopeHidesAllState` would make this branch unreachable
        // under any scope, and blame the scope for rows hidden behind the filter.
        #expect(view.contains("if scopedTotal == 0, let scope {"),
                "a filter-narrowed scoped list still blames the scope, and the branch above is dead there")
        // One predicate, so the chooser and the wording cannot drift apart.
        #expect(view.contains("private var filterIsNarrowing: Bool { effectiveLens == .duplicates && filter != .all }"))
        // Over a scope holding nothing, neither the query nor the filter is the cause: their
        // sentences would read "hides all 0 …" and offer a click that changes nothing.
        #expect(body.contains("total == 1 ? \"\" : \"s\""),
                "the empty state no longer counts what it claims to be hiding")
        #expect(try SourceText.body(of: "private var isFiltered: Bool {", in: view)
                    .contains("filterIsNarrowing"),
                "`isFiltered` restates the filter rule instead of sharing it")
    }

    /// The Refine button names no model: Refine runs on the chat's, read out elsewhere. A pixel
    /// diff can't show that, so the source is read: the title says Claude, and nothing reads a model
    /// setting of Organize's own. Not in the pixel-pinned `FilingRefineControlTests`, so it runs on
    /// every push.
    @Test func theButtonSaysClaudeAndTheModelIsTheChatsNotOrganizes() throws {
        let source = SourceText.codeOnly(try SourceText.fileExplorer("LensWorkspaceView.swift"))
        #expect(source.contains(#"Label("Refine \(batch.count) with Claude…""#))
        #expect(!source.contains("cloudModelDefaultsKey") && !source.contains("usesCloudDefaultsKey"),
                "Organize has no model or switch of its own to read")
        #expect(source.contains("AskClaudeModels.defaultsKey"),
                "the tooltip and Refine Names name the chat's model, read from the setting its menu writes")
    }
}
