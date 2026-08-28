@testable import SyncCloud
import Sync
import Testing
import Foundation

/// **The two doors that re-point a pane at a different root, read off `ContentView`'s source.**
///
/// Both live in `onChange` closures on a `View` with `@State`, so no test can call them: the
/// polarity of `retargetPane(isLeft:)` and the scope handed to the Settings teardown are decided in
/// the one place a running test cannot reach. `FolderSidebarWiringTests` exists for the same reason
/// and this suite borrows its instrument — read one named file, strip comments so a mention in
/// prose cannot satisfy a check, and require a known-present anchor so a scan that finds nothing
/// fails loudly instead of passing.
///
/// **What each scan is standing in for.**
///
/// - *The polarity.* `retargetPane` now takes `isLeft`, and both handlers are otherwise mirror
///   images — the same four calls in the same order. Flipping one boolean re-homes the pane the
///   user did NOT switch and leaves the one they did switch showing another source's tree, with
///   every package suite green. `PaneSideChoice` was extracted for exactly this failure ("dropping
///   the `!` opened both halves on the pane the user aimed at… with the whole app suite green"),
///   and it cannot help here: `Sync` is below `MacApp` and cannot see it.
/// - *The scope, spent twice.* `paneRootEdits` answers which pane's Location moved, and the answer
///   has to reach BOTH `invalidateComparisonState(reloading:)` and the rescan. Drop a pane's tree
///   here and fail to walk it there and that pane renders blank until something else refreshes it;
///   walk a pane whose root never moved and the bug this whole change removed is back. The contract
///   was written as a doc comment on `invalidateComparisonState(reloading:)` and checked by nothing.
@Suite struct PaneRetargetWiringTests {

    private static func contentViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView.swift — this scan would be vacuous")
        try #require(raw.count > 5000, "ContentView.swift is implausibly short — the scan is vacuous")
        return SyncCloudTests.strippingComments(raw)
    }

    /// The source between two markers. Both are `#require`d, so a rename that moves the region
    /// fails the scan rather than silently narrowing it to nothing.
    private static func region(from opening: String, to closing: String, in source: String) throws -> String {
        let start = try #require(source.range(of: opening), "`\(opening)` is gone — this scan would be vacuous")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: closing), "`\(opening)` is never followed by `\(closing)`")
        return String(rest[..<end.lowerBound])
    }

    // MARK: - The source menu: one handler per pane, and the polarity has to match

    @Test(arguments: [(pane: "left", isLeft: "true", opening: ".onChange(of: leftProviderId) { _, newId in",
                       closing: ".onChange(of: rightProviderId) { _, newId in"),
                      (pane: "right", isLeft: "false", opening: ".onChange(of: rightProviderId) { _, newId in",
                       closing: ".modifier(BrowseTabPersistence(")])
    func eachProviderHandlerRetargetsItsOwnPane(pane: String, isLeft: String, opening: String, closing: String) throws {
        let body = try Self.region(from: opening, to: closing, in: try Self.contentViewSource())

        // The anchor: this handler is the user-switch path, not one of the suppressed ones.
        #expect(body.contains("PaneProviderChange.decide("),
                "the \(pane) handler no longer consumes the suppression counters — the region read here is not the user-switch path")

        #expect(body.contains("syncManager.retargetPane(isLeft: \(isLeft),"),
                "the \(pane)-provider handler does not retarget the \(pane) pane; a flipped polarity re-homes the pane the user did not switch")
        let opposite = isLeft == "true" ? "false" : "true"
        #expect(!body.contains("retargetPane(isLeft: \(opposite)"),
                "the \(pane)-provider handler retargets the OTHER pane")
    }

    /// The landing is the switched pane's own source, not the sibling's — the second half of the
    /// polarity, and the half a boolean flip alone would not disturb.
    @Test func eachProviderHandlerLandsOnTheNewSourcesOpeningFolder() throws {
        let source = try Self.contentViewSource()
        let handlers = [(".onChange(of: leftProviderId) { _, newId in", ".onChange(of: rightProviderId) { _, newId in"),
                        (".onChange(of: rightProviderId) { _, newId in", ".modifier(BrowseTabPersistence(")]
        for (opening, closing) in handlers {
            let body = try Self.region(from: opening, to: closing, in: source)
            #expect(body.contains("landing: settings.openAtIfReachable(for: newId)"),
                    "\(opening) re-homes its pane somewhere other than the source it just switched to")
        }
    }

    // MARK: - Settings: the same scope to the teardown and to the rescan

    @Test func theLocationEditSpendsOneScopeOnBothTheTeardownAndTheRescan() throws {
        let body = try Self.region(from: "if let edited = Self.paneRootEdits(",
                                   to: "\n        .modifier(SettingsEngineMirrors(",
                                   in: try Self.contentViewSource())

        #expect(body.contains("syncManager.invalidateComparisonState(reloading: edited)"),
                "the Location-edit teardown drops trees on a scope other than the one paneRootEdits computed")
        #expect(body.contains("refreshAction(reloading: edited)"),
                "the rescan after a Location edit does not use the scope the teardown used — a pane whose tree was dropped and not walked renders blank")

        // The unscoped spellings are the regression, not merely an alternative: either one alone
        // reintroduces the whole-window teardown for an edit to one source.
        #expect(!body.contains("invalidateComparisonState()"),
                "the Location edit is back to dropping BOTH panes' trees")
        #expect(!body.contains("refreshAction()"),
                "the Location edit is back to re-walking BOTH panes")
    }

    /// The scoped reload is the only re-walk in the app that announces neither a cause nor a pane,
    /// so the line that does both is part of the wiring rather than decoration. `describedPanes` is
    /// asserted by name because `String(describing:)` yields `leftOnly` — a case name, not something
    /// a person reading `~/sync-cloud.log` has been told the meaning of.
    @Test func theLocationEditSaysWhichPaneItIsRewalkingAndWhy() throws {
        let body = try Self.region(from: "if let edited = Self.paneRootEdits(",
                                   to: "\n        .modifier(SettingsEngineMirrors(",
                                   in: try Self.contentViewSource())
        #expect(body.contains("Logger.shared.info("),
                "a Location edit re-walks a pane and writes nothing to the log saying so")
        #expect(body.contains("edited.describedPanes"),
                "the line names the scope by its case name rather than by the panes it means")
    }
}
