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
        let summary = try #require(tidy.range(of: "private func lensSummary(rows: FilteredRows,"),
                                   "lensSummary is gone — this scan would be vacuous")
        let organizeSummary = try #require(tidy.range(of: "private func organizeSummary(rows:"))
        let chipDraw = try #require(tidy.range(of: "if lens != .storage { scopeChip("),
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
        let start = try #require(tidy.range(of: "private var railCounts: RailCounts {"),
                                 "railCounts is gone — this scan would be vacuous")
        let rest = tidy[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for railCounts")
        let body = String(rest[..<end.lowerBound])

        // **Each of the six, by name.** A bare `body.contains("OrganizeScopeFilter.matches")` was
        // the first version and it let a real mutation through: dropping the scope from `renames`
        // alone leaves the other five calls in place, so the check still passed while the Renames
        // badge went back to reporting 126 beside a list of three. One lens quietly un-scoping is
        // exactly the inconsistency this whole feature exists to remove, so every lens is asserted
        // separately.
        let scoped: [(String, String)] = [
            ("toFile", "syncManager.filingSuggestions.count { OrganizeScopeFilter.matches($0, scope: scope) }"),
            ("duplicates", "syncManager.duplicateGroups.count { OrganizeScopeFilter.matches($0, scope: scope) }"),
            ("names", "syncManager.riskyNames.count { OrganizeScopeFilter.matches($0, scope: scope) }"),
            ("renames", "syncManager.renamePlans.count { OrganizeScopeFilter.matches($0, scope: scope) }"),
            ("rules", "syncManager.automationRules.count { OrganizeScopeFilter.matches($0, scope: scope) }"),
        ]
        for (lens, call) in scoped {
            #expect(body.contains(call),
                    "the \(lens) badge is counting the global list again — a number beside a list it does not describe")
        }
        // Restructure counts through `relation` rather than `matches`, and `.inside` ONLY: an
        // ancestor finding is shown in the lens but is not work in this subtree, so a badge that
        // counted it would promise something here that is not here.
        #expect(body.contains("OrganizeScopeFilter.relation(of: $0, profileRoot: profileRoot, scope: scope) == .inside"),
                "the restructure badge is unscoped, or counting ancestor findings as work in the scope")
        #expect(!body.contains("case .restructure: return 0"),
                "the restructure badge is hard-wired to 0 again")
    }

    /// The counts are resolved ONCE and handed to both consumers — the same property `FilteredRows`
    /// exists for, and the reason this stopped being twelve scoped passes per render.
    @Test func theRailCountsAreResolvedOncePerRender() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("let counts = railCounts"))
        #expect(tidy.contains("badge: counts.badge"),
                "the width arithmetic is recomputing the badges instead of reading the resolved counts")
        #expect(!tidy.contains("private var railBadgeCount"),
                "railBadgeCount is back — that is the second independent pass over all six lists")
        // And the per-render profile walk behind the chip's folder count is resolved with them.
        #expect(tidy.contains("let scopeFolders = scopeFolderCount"))
    }

    @Test func theOverviewNamesTheScopeAndNotTheLastScannedFolder() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("scopeLabel: scope?.name"))
        // The thing it must NOT go back to: the root one lens happened to walk.
        #expect(!tidy.contains(
            "scopeLabel: syncManager.filingScanFolder.map { ($0 as NSString).lastPathComponent }"))
    }

    // MARK: The two defects the installed build turned up

    @Test func theReaimButtonSaysItCLEARSTheScopeAtTheProviderRoot() throws {
        // Found by installing and looking: scoped to Legal with the pane at the provider root, the
        // button read `Organize "Documents"` and promised "Every lens narrows to it" — while
        // clicking it widens to the whole tree. The action was always right; only the words lied,
        // which is the shape of defect a green suite is least likely to catch.
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("private var reaimClearsScope: Bool"))
        #expect(tidy.contains("reaimClearsScope ? \"Organize everything\""))
        // And the promise must be swapped with the label, not left behind on it.
        #expect(tidy.contains(".help(reaimClearsScope"))
    }

    @Test func anEmptyScopedListBlamesTheScopeAndNotTheSearch() throws {
        // The other one: the Rules lens under a scope offered "The current search hides all 1 rule.
        // Clear it to see the results again" with a Clear Search button, while no search was
        // running. Wrong cause, and an action that could not fix it.
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("private func scopeHidesAllState"))
        #expect(tidy.contains("private func searchHidesAllState"))
        // The chooser: a live query owns the emptiness, otherwise the scope does.
        #expect(tidy.contains("if query.isEmpty, let scope {"))
        // And the scoped state must state the outside total and offer the clearing action —
        // "0 here" reading as "0 anywhere" is the whole complaint.
        #expect(tidy.contains("elsewhere in the tree"))
        #expect(tidy.contains("\"Organize Everything\""))
    }

    // MARK: No apply-all button may render a zero

    /// **Every apply-all button gates on having something to apply.**
    ///
    /// Their callers gate on the GLOBAL list (`!syncManager.renamePlans.isEmpty`) while the rows
    /// they are handed are the narrowed ones, so the two disagree whenever a narrowing empties a
    /// lens the tree still has entries for. With a search that was a corner — the content card says
    /// "nothing matches" right beside it — but a scope makes it ordinary, and `renameAllButton` was
    /// the one of the four with no guard: it rendered a prominent, enabled **"Rename 0 files"**.
    ///
    /// A source scan, because these are private `@ViewBuilder`s on a view SwiftUI will not let a
    /// test drive. It is bounded by each declaration's own closing brace rather than a character
    /// count, and it fails if a declaration cannot be found at all — a scan that quietly matches
    /// nothing passes just as green as one that proves something.
    @Test func everyApplyAllButtonGuardsAgainstAnEmptyList() throws {
        let tidy = try Self.source("TidyView.swift")
        let expected: [(decl: String, guardText: String)] = [
            ("private func fixAllButton(_ risky: [RiskyName]) -> some View {", "if !risky.isEmpty {"),
            ("private func fileAllButton(_ filing: [FilingSuggestion]) -> some View {", "if !batch.isEmpty {"),
            ("private func applyAllButton(_ groups: [DuplicateGroup]) -> some View {", "if !batch.isEmpty {"),
            // Counts FILES, not plans: a plan whose steps are all applied is still a plan, so
            // `!plans.isEmpty` would leave the same zero-labelled button standing.
            ("private func renameAllButton(_ plans: [RenamePlan]) -> some View {", "if files > 0 {"),
        ]
        for (decl, guardText) in expected {
            let start = try #require(tidy.range(of: decl), "\(decl) is gone — this scan is vacuous")
            let rest = tidy[start.upperBound...]
            let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(decl)")
            let body = String(rest[..<end.lowerBound])
            #expect(body.contains(guardText),
                    "\(decl) has no empty-list guard — it can render an apply button labelled 0")
        }
    }

    // MARK: A pointed question is not answered through somebody else's scope

    @Test func theDuplicateRevealClearsAScopeThatWouldHideIt() throws {
        let tidy = try Self.source("TidyView.swift")
        // The outcome is resolved against the whole group list and the rows are drawn through the
        // scoped one; without this the two disagree and a named file comes back as "no copies".
        #expect(tidy.contains("OrganizeScopeFilter.revealClearsScope(revealedPath: request.path"))
        // Inside the `outcome != .waiting` branch, so a still-scanning handoff does not thrash the
        // scope before it has an answer.
        let start = try #require(tidy.range(of: "if outcome != .waiting {"))
        let rest = tidy[start.upperBound...]
        let end = try #require(rest.range(of: "\n        }"))
        #expect(String(rest[..<end.lowerBound]).contains("revealClearsScope"),
                "the scope clear has moved outside the answered-outcome branch")
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
