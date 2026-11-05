import Testing
import Foundation

/// Where the pane says it is, at the call sites. `PaneCombinedPathTests` proves the rule
/// (`FileSyncManager.paneLocation(isLeft:drawsColumns:)` and the four navigation entry points) but
/// not that the header asks it: one reverted line in `ContentView.swift` would put the breadcrumb
/// back on the bare scope+stack join with those tests green.
///
/// So a source scan, as in `TidyScanRootTests`: the read fails loudly on an empty haystack, and each
/// check pins an argument whole, not its ingredients. A flipped `isLeft` is invisible to every
/// behavioural test, since the manager never learns which pane the app meant.
@Suite struct PaneLocationCallSiteTests {

    private static func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)      // …/SyncCloudTests/<this>.swift
            .deletingLastPathComponent()               // …/SyncCloudTests
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("MacApp/\(name)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — every check below would be vacuous")
        try #require(text.count > 500, "\(name) is implausibly short — the checks would be near-vacuous")
        return text
    }

    /// One declaration's body, bounded by its closing brace, not a character count: a fixed window
    /// runs past a short body into the next member and answers about the wrong text.
    private static func body(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "`\(declaration)` is gone — this scan would read nothing")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for `\(declaration)`")
        return String(rest[..<end.lowerBound])
    }

    /// The header's path. `mode` is the resolved presentation, so a Tree pane reads out its scope
    /// and a Columns pane its scope joined with the open columns.
    @Test func theHeadersPathAsksForTheLocationThePresentationActuallyShows() throws {
        let body = try Self.body(of: "func paneContext(isLeft: Bool) -> PaneContext {",
                                 in: try Self.source("ContentView.swift"))
        #expect(body.contains(
                    "relativePath: syncManager.paneLocation(isLeft: isLeft, drawsColumns: mode == .columns)"),
                """
                the header's path is no longer resolved through the presentation — a Tree pane \
                will name the folder its parked columns stopped in
                """)
        // The arrows must be enabled from the same answer their press acts on, or `‹` lights up for
        // a move that changes nothing on screen.
        #expect(body.contains(
                    "canGoBack: syncManager.canGoBack(isLeft: isLeft, drawsColumns: mode == .columns)"),
                "`‹` is enabled without regard to the presentation")
        #expect(body.contains(
                    "canGoForward: syncManager.canGoForward(isLeft: isLeft, drawsColumns: mode == .columns)"),
                "`›` is enabled without regard to the presentation")
    }

    /// And what pressing them does. `pane.viewMode`, not a fresh read: the row was laid out from
    /// that context, so a click can't be resolved against a mode it wasn't drawn in.
    @Test func theArrowsAndTheCrumbsActOnTheSamePresentationTheyWereDrawnIn() throws {
        let source = try Self.source("ContentView.swift")
        for call in ["onBack: { syncManager.goBack(isLeft: isLeft, drawsColumns: pane.viewMode == .columns) }",
                     "onForward: { syncManager.goForward(isLeft: isLeft, drawsColumns: pane.viewMode == .columns) }"] {
            #expect(source.contains(call), "missing or altered: \(call)")
        }
        #expect(source.contains("drawsColumns: pane.viewMode == .columns) },"),
                """
                a crumb click no longer carries the pane's presentation — in Tree it would write \
                to a column stack the pane draws nowhere, and land on nothing at all
                """)
    }

    /// A linked crumb click is two moves, and each pane answers for its own presentation. Both
    /// arguments pinned whole: swapped, each pane is driven through the other's mode, which no
    /// behavioural test can see.
    @Test func aLinkedClickAsksEachPaneAboutItself() throws {
        let body = try Self.body(of: "func navigateBothPanes(toCombinedPath combined: String, from isLeft: Bool) {",
                                 in: try Self.source("ContentView.swift"))
        #expect(body.contains("drawsColumns: paneDrawsColumns(isLeft: isLeft)"),
                "the clicked pane is no longer asked about its own presentation")
        #expect(body.contains("otherDrawsColumns: paneDrawsColumns(isLeft: !isLeft)"),
                "the sibling is asked about the CLICKED pane's presentation (the `!` is gone)")
    }

    /// The strip asks the header's question, about the same pane. Written `!isLeft`, the chips
    /// would resolve through the sibling's presentation and every chip test would still pass, since
    /// they call `PaneTabChips.items` directly.
    @Test func theTabStripResolvesThroughItsOwnPanesPresentation() throws {
        let body = try Self.body(of: "func paneTabItems(isLeft: Bool) -> [PaneTabStrip.Item] {",
                                 in: try Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains(
                    "livePath: syncManager.paneLocation(isLeft: isLeft, drawsColumns: paneDrawsColumns(isLeft: isLeft))"),
                "the active chip's path is no longer resolved through this pane's presentation")
        #expect(body.contains("drawsColumns: paneDrawsColumns(isLeft: isLeft),"),
                "the parked chips are no longer resolved through this pane's presentation")
    }

    /// Nothing in the app may take the bare scope+stack join for a readout.
    /// `combinedRelativePath` stays, since a tab's stored location wants both halves, but it
    /// mustn't describe what a pane is showing.
    @Test func nothingReadsTheBareJoinForAReadoutAnyMore() throws {
        let source = try Self.source("ContentView.swift")
        #expect(!source.contains("syncManager.combinedRelativePath("),
                "ContentView is reading the bare scope+stack join again — that is the reported bug")
    }
}
