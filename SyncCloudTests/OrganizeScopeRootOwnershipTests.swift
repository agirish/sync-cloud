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

    /// The row menus aim at their own pane. Both are named, since the closures sit one line apart
    /// and a fix to only one would look done.
    @Test(arguments: [("onOrganizeFolder", "organizeFolderAction("), ("onOrganizeScope", "setOrganizeScope(")])
    func theRowMenusScopeAgainstTheirOwnPanesRoot(closure: String, callee: String) throws {
        let body = try declarationBody(of: "func paneActionDelegate(for pane: PaneContext) -> PaneActionDelegate {",
                                       in: macAppFile("ContentView.swift"))
        let handler = try #require(try CallArguments(of: "PaneActionDelegate(", in: body).value(closure),
                                   "\(closure) is gone from the pane's delegate — this scan checks nothing")
        #expect(try CallArguments(of: callee, in: handler)
                    .passes("providerRoot", "providerRootExpanded(forProviderId: pane.providerId)"),
                "\(closure) does not name the row's own pane: \(handler)")
        #expect(!handler.contains("lensProviderRootExpanded"),
                "\(closure) is back on the FOCUSED pane's root, which a context menu does not move")
    }

    /// The write itself may not fall back to the focused pane, so a new caller can't inherit it by
    /// not thinking about it. The signature, which requires a root, is the one this reads.
    @Test func theScopeWriteTakesItsRootFromTheCallerOnly() throws {
        let body = try declarationBody(of: "func setOrganizeScope(_ path: String?, providerRoot: String) {",
                                       in: macAppFile("ContentView.swift"))
        #expect(!body.contains("lensProviderRootExpanded"), "setOrganizeScope reads the focused pane's root again")
    }
}
