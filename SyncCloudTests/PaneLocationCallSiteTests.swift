import Testing
import Foundation

/// **Where the pane says it is, at the call sites.**
///
/// `FileSyncManager.paneLocation(isLeft:drawsColumns:)` and the four navigation entry points are
/// pinned by `PaneCombinedPathTests`, which is a behavioural suite and proves the RULE. It cannot
/// prove the header asks it — a revert of one line in `ContentView.swift` puts the breadcrumb back
/// on the bare scope+stack join with every one of those tests still green, which is the state this
/// whole change started from.
///
/// Source-level, therefore, with the blind spot that implies. Two habits keep it honest, both taken
/// from `TidyScanRootTests`: the read fails loudly rather than scanning an empty haystack, and every
/// check pins a ternary or an argument WHOLE rather than asserting that its ingredients appear
/// somewhere. The flipped-`isLeft` mistake is invisible to every behavioural test in the package —
/// the manager never learns which pane the app meant to ask about.
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

    /// One declaration's body, bounded by its closing brace rather than a character count — a fixed
    /// window runs past a short body into the next member and answers about the wrong text.
    private static func body(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "`\(declaration)` is gone — this scan would read nothing")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for `\(declaration)`")
        return String(rest[..<end.lowerBound])
    }

    /// The reported bug's own line: the header's path. `mode` is the resolved presentation, so a
    /// Tree pane reads out its scope and a Columns pane its scope joined with the open columns.
    @Test func theHeadersPathAsksForTheLocationThePresentationActuallyShows() throws {
        let body = try Self.body(of: "func paneContext(isLeft: Bool) -> PaneContext {",
                                 in: try Self.source("ContentView.swift"))
        #expect(body.contains(
                    "relativePath: syncManager.paneLocation(isLeft: isLeft, drawsColumns: mode == .columns)"),
                """
                the header's path is no longer resolved through the presentation — a Tree pane \
                will name the folder its parked columns stopped in
                """)
        // The arrows have to be enabled from the same answer their press acts on, or `‹` lights up
        // for a move that changes nothing on screen.
        #expect(body.contains(
                    "canGoBack: syncManager.canGoBack(isLeft: isLeft, drawsColumns: mode == .columns)"),
                "`‹` is enabled without regard to the presentation")
        #expect(body.contains(
                    "canGoForward: syncManager.canGoForward(isLeft: isLeft, drawsColumns: mode == .columns)"),
                "`›` is enabled without regard to the presentation")
    }

    /// And what pressing them does. `pane.viewMode` rather than a fresh read: the row was laid out
    /// from that same context, so a click cannot be resolved against a mode it was not drawn in.
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
    /// arguments pinned whole: swapping them drives each pane through the other's mode, which no
    /// behavioural test in the package can see.
    @Test func aLinkedClickAsksEachPaneAboutItself() throws {
        let body = try Self.body(of: "func navigateBothPanes(toCombinedPath combined: String, from isLeft: Bool) {",
                                 in: try Self.source("ContentView.swift"))
        #expect(body.contains("drawsColumns: paneDrawsColumns(isLeft: isLeft)"),
                "the clicked pane is no longer asked about its own presentation")
        #expect(body.contains("otherDrawsColumns: paneDrawsColumns(isLeft: !isLeft)"),
                "the sibling is asked about the CLICKED pane's presentation (the `!` is gone)")
    }

    /// The strip asks the same question the header does, and about the SAME pane. `paneTabItems`
    /// takes an `isLeft` and hands it to `paneDrawsColumns`; written `!isLeft` the chips would be
    /// resolved through the sibling's presentation, and every behavioural chip test would still pass
    /// — they call `PaneTabChips.items` directly and never learn which pane the app asked about.
    @Test func theTabStripResolvesThroughItsOwnPanesPresentation() throws {
        let body = try Self.body(of: "func paneTabItems(isLeft: Bool) -> [PaneTabStrip.Item] {",
                                 in: try Self.source("ContentView+PaneTabs.swift"))
        #expect(body.contains(
                    "livePath: syncManager.paneLocation(isLeft: isLeft, drawsColumns: paneDrawsColumns(isLeft: isLeft))"),
                "the active chip's path is no longer resolved through this pane's presentation")
        #expect(body.contains("drawsColumns: paneDrawsColumns(isLeft: isLeft),"),
                "the parked chips are no longer resolved through this pane's presentation")
    }

    /// The negative, as an absence: nothing in the app may take the bare scope+stack join for a
    /// readout again. `combinedRelativePath` is not deleted — a tab's stored location genuinely
    /// wants both halves — it simply has no business describing what a pane is showing.
    @Test func nothingReadsTheBareJoinForAReadoutAnyMore() throws {
        let source = try Self.source("ContentView.swift")
        #expect(!source.contains("syncManager.combinedRelativePath("),
                "ContentView is reading the bare scope+stack join again — that is the reported bug")
    }
}
