import Testing
import Foundation

/// Two app-target call sites from the v6.1 Browse review, which no package test can reach: the
/// rules behind them are tested in their packages, and these check the app still hands them the
/// right thing. Read with comments stripped, so a comment quoting the call cannot satisfy a scan.
@Suite struct BrowseReviewWiringTests {

    /// The Sync History window's Undo Last Run hands back the manager's refusal for that window to
    /// show (`SyncHistoryView`'s alert), from the asking entry point that never sets the main
    /// window's banner. `SyncRunUndoGuardTests` covers the manager; this covers the hand-off.
    ///
    /// The closure is read whole (brace-matched), and must BE the call: a fixed-length window
    /// stopped short of an added `return nil` — measured, it passed with the refusal dropped.
    @Test func syncHistoryGetsTheRefusalBack() throws {
        let app = try LinkedMoveTranslationTests.repoFile("MacApp/SyncCloudApp.swift")
        #expect(app.components(separatedBy: "onUndoLastSyncRun:").count == 2,
                "Undo Last Run is wired in more than one place, or none — this reads the first")
        let action = try LinkedMoveTranslationTests.body(of: "onUndoLastSyncRun:", in: app)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(action.hasPrefix("syncManager.undoLastSyncRunAskingFirst("),
                "Undo Last Run's closure no longer hands back the refusal from the asking entry point")
        #expect(!action.contains("return"), "Undo Last Run's refusal is dropped before Sync History sees it")
    }

    /// Crumbs drive the other pane only where there is one: a one-pane workspace passes nil, which
    /// is what `PaneBreadcrumb` reads as "no second pane" (`PaneBreadcrumbHelpTests`).
    @Test func onePaneWorkspacesPassNoSecondPane() throws {
        let view = LinkedMoveTranslationTests.codeOnly(try LinkedMoveTranslationTests.repoFile("MacApp/ContentView.swift"))
        let argument = try #require(view.range(of: "onNavigateBoth:"),
                                    "ContentView no longer hands the crumbs onNavigateBoth")
        let value = view[argument.upperBound...].prefix(160)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(value.hasPrefix("layoutMode == .singleSource ? nil :"),
                "a one-pane workspace hands the crumbs a second pane — ⌥-click would drive the hidden one")
        #expect(view.components(separatedBy: "onNavigateBoth:").count == 2,
                "a second onNavigateBoth: site — check it passes nil in one-pane workspaces too")
    }
}
