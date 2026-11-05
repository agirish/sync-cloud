import Testing
import Foundation
@testable import SyncCloud

/// Which provider root a scope write is measured against.
/// `OrganizeScope.normalizedPath(_:providerRoot:)` answers `""` (the global view) for a folder
/// outside the root it is handed, so the wrong root silently wipes the scope and the folder just
/// named, and that survives relaunch.
///
/// **A SwiftUI context menu does not move focus**, so the row menus must pass their own pane's
/// root, not the focused pane's. Source assertions, because the call sites live in a view body;
/// `OrganizeScopeNormalizationTests` covers the normalization itself.
@Suite struct OrganizeScopeRootOwnershipTests {

    private static func source(_ name: String) throws -> String {
        // Tests/<this file> -> repo root is two levels up.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("MacApp/\(name)"), encoding: .utf8)
        // A scan that finds nothing is not a scan that finds nothing wrong.
        try #require(!text.isEmpty)
        return text
    }

    /// The row menus aim at their own pane. Both are named, since the closures sit one line apart
    /// and a fix to only one would look done.
    @Test func theRowMenusScopeAgainstTheirOwnPanesRoot() throws {
        let view = try Self.source("ContentView.swift")
        for closure in ["onOrganizeFolder:", "onOrganizeScope:"] {
            let start = try #require(view.range(of: closure),
                                     "\(closure) is gone from ContentView — this scan checks nothing")
            let window = String(view[start.upperBound...].prefix(220))
            #expect(window.contains("providerRootExpanded(forProviderId: pane.providerId)"),
                    "\(closure) does not name the row's own pane; window was:\n\(window)")
            #expect(!window.contains("lensProviderRootExpanded"),
                    "\(closure) is back on the FOCUSED pane's root, which a context menu does not move")
        }
    }

    /// The write itself may not fall back to the focused pane, so a new caller can't inherit it by
    /// not thinking about it.
    @Test func theScopeWriteTakesItsRootFromTheCallerOnly() throws {
        let view = try Self.source("ContentView.swift")
        let start = try #require(view.range(of: "func setOrganizeScope("))
        let window = String(view[start.upperBound...].prefix(200))
        #expect(window.contains("providerRoot: String"),
                "setOrganizeScope no longer requires a root, so a call site can inherit the focused pane's again")
        #expect(!window.contains("lensProviderRootExpanded"),
                "setOrganizeScope reads the focused pane's root again")
    }

    /// The palette is the one caller for which the focused pane is right, so it must still say so.
    @Test func thePaletteStillAimsAtTheFocusedPane() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("setOrganizeScope(scope, providerRoot: lensProviderRootExpanded)"))
    }
}
