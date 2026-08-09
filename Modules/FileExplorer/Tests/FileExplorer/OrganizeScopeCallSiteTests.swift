import Testing
import Foundation
@testable import FileExplorer

/// **The call sites.** `OrganizeScopeFilter` and `ScopeChipLabel` are both extracted for
/// testability, and a rule extracted for testability is one revert away from being unused — a
/// perfectly green predicate suite proves nothing if the view stopped calling it.
///
/// These are source-level assertions, which is a blunt instrument with a known blind spot: a source
/// scan is not a behavioural test and has passed before with the bug present. Two habits keep it
/// honest here — each check **names the file it reads and fails if that file cannot be found**
/// (so a rename cannot silently empty the haystack), and each asserts a string whose absence is
/// exactly the regression it is guarding against, not merely that some related word appears.
@Suite struct OrganizeScopeCallSiteTests {

    /// The module's own source directory, located from this test file rather than from a working
    /// directory — `swift test` does not promise one.
    static let sourceDir: URL = {
        URL(fileURLWithPath: #filePath)                     // …/Tests/FileExplorer/<this>.swift
            .deletingLastPathComponent()                    // …/Tests/FileExplorer
            .deletingLastPathComponent()                    // …/Tests
            .deletingLastPathComponent()                    // …/FileExplorer (package)
            .appendingPathComponent("Sources/FileExplorer")
    }()

    static func source(_ name: String) throws -> String {
        let url = sourceDir.appendingPathComponent(name)
        // The non-vacuity guard: a missing file must FAIL, never yield an empty haystack in which
        // every `contains` check quietly answers false and every `!contains` quietly answers true.
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — the scan below would be vacuous")
        #expect(text.count > 500, "\(name) is implausibly short")
        return text
    }

    // MARK: The predicate is actually called

    @Test func tidyViewFiltersEveryLensThroughTheScopePredicate() throws {
        let tidy = try Self.source("TidyView.swift")
        // One call per filterable set. Losing any one of these is a lens that silently stops
        // narrowing while the other five keep doing so — the exact inconsistency this feature
        // exists to remove.
        let calls = tidy.components(separatedBy: "OrganizeScopeFilter.").count - 1
        #expect(calls >= 10,
                "only \(calls) OrganizeScopeFilter call(s) in TidyView — a lens has stopped scoping")
    }

    @Test func restructureRoutesThroughFilteredRowsRatherThanTheManager() throws {
        let tidy = try Self.source("TidyView.swift")
        // The specific bug: `restructureContent()` read `syncManager.structureFindings` directly,
        // which is why no filter could reach it. It takes `rows` now.
        #expect(tidy.contains("restructureContent(rows:"))
        #expect(tidy.contains("RestructureLens(findings: rows.structure"))
        #expect(tidy.contains("aboutAncestor: rows.structureAboutAncestor"))
    }

    @Test func theScopeChipIsDrawnFromLensSummaryNotFromOneArm() throws {
        let tidy = try Self.source("TidyView.swift")
        // The rail already made this mistake: drawn inside `organizeSummary`, it reached only the
        // filing apparatus, so two of the six lenses rendered without it. The chip must be hoisted
        // above the switch in `lensSummary`.
        let summary = try #require(tidy.range(of: "private func lensSummary(rows: FilteredRows)"))
        let organizeSummary = try #require(tidy.range(of: "private func organizeSummary(rows:"))
        let chipDraw = try #require(tidy.range(of: "if lens != .storage { scopeChip }"),
                                    "the scope chip is no longer drawn from lensSummary")
        #expect(chipDraw.lowerBound > summary.lowerBound)
        #expect(chipDraw.lowerBound < organizeSummary.lowerBound,
                "the scope chip has drifted into organizeSummary, which two lenses never reach")
    }

    @Test func theChipViewIsTheOneTheTestsRender() throws {
        let tidy = try Self.source("TidyView.swift")
        // `OrganizeScopeChipTests` renders `ScopeChipLabel`. If TidyView ever inlines its own chip
        // again, those pixel assertions would be measuring a view nothing shows.
        #expect(tidy.contains("ScopeChipLabel("))
    }

    // MARK: The badges and the overview are scoped too

    @Test func railCountsAreScoped() throws {
        let tidy = try Self.source("TidyView.swift")
        let range = try #require(tidy.range(of: "private func railCount(_ item: OrganizeLens)"))
        let body = String(tidy[range.lowerBound...].prefix(2200))
        #expect(body.contains("OrganizeScopeFilter.matches"),
                "rail badges are counting the global list again — 126 beside a list of 3")
        #expect(!body.contains("case .restructure: return 0"),
                "the restructure badge is hard-wired to 0 again")
    }

    @Test func theOverviewNamesTheScopeAndNotTheLastScannedFolder() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("scopeLabel: scope?.name"))
        // The thing it must NOT go back to: the root one lens happened to walk.
        #expect(!tidy.contains(
            "scopeLabel: syncManager.filingScanFolder.map { ($0 as NSString).lastPathComponent }"))
    }

    // MARK: The inbox root-swap is gone, and the path resolution is not

    @Test func theInboxIsOfferedAsAScopeShortcut() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("OrganizeOverview.InboxShortcut"))
        #expect(tidy.contains("inboxShortcut: inboxShortcut"))
        let overview = try Self.source("OrganizeOverview.swift")
        #expect(overview.contains("Inbox (\\(shortcut.name))"),
                "the inbox offer no longer names the inbox folder")
    }
}
