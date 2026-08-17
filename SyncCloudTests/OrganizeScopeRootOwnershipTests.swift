import Testing
import Foundation
@testable import SyncCloud

/// Which provider root a scope write is measured against.
///
/// `OrganizeScope.normalizedPath(_:providerRoot:)` answers `""` — the global view — for any folder
/// that is not under the root it is handed. That is correct, and it is why handing it the WRONG
/// root is not a near-miss but a silent wipe: the scope the user had set and the folder they just
/// named both vanish, and it survives relaunch.
///
/// `setOrganizeScope` used to read the focused pane's root itself. Two of its three callers are row
/// context menus, and **a SwiftUI context menu does not move focus** — so a right-click in the pane
/// that did not have focus was answered with the other pane's root.
///
/// These are source assertions because the rule lives in a SwiftUI view body that no unit test can
/// drive. The behaviour they stand for is already covered by `OrganizeScopeNormalizationTests`;
/// what is unprotected without them is which value reaches it, and that is a call-site fact.
@Suite struct OrganizeScopeRootOwnershipTests {

    private static func source(_ name: String) throws -> String {
        // Tests/<this file> -> repo root is two levels up.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("MacApp/\(name)"), encoding: .utf8)
        // A scan that finds nothing is not a scan that finds nothing wrong.
        try #require(!text.isEmpty)
        return text
    }

    /// The row menus aim at their OWN pane. Both of them, named individually — the two closures
    /// live one line apart and a fix applied to only one would look done.
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

    /// And the write itself may not fall back to the focused pane on its own — the property that
    /// stops a fourth caller re-introducing this by simply not thinking about it.
    @Test func theScopeWriteTakesItsRootFromTheCallerOnly() throws {
        let view = try Self.source("ContentView.swift")
        let start = try #require(view.range(of: "func setOrganizeScope("))
        let window = String(view[start.upperBound...].prefix(200))
        #expect(window.contains("providerRoot: String"),
                "setOrganizeScope no longer requires a root, so a call site can inherit the focused pane's again")
        #expect(!window.contains("lensProviderRootExpanded"),
                "setOrganizeScope reads the focused pane's root again")
    }

    /// The palette is the one caller for which the focused pane IS right, so it must still say so
    /// rather than having been swept along with the row menus.
    @Test func thePaletteStillAimsAtTheFocusedPane() throws {
        let host = try Self.source("CommandPaletteHost.swift")
        #expect(host.contains("setOrganizeScope(scope, providerRoot: lensProviderRootExpanded)"))
    }
}
