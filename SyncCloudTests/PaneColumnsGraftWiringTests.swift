@testable import SyncCloud
import Testing
import Foundation

/// The graft chain is connected end to end in the app. `onNeedChildren` defaults to a no-op at
/// both hops (`PaneColumnsView`, `FileTreeView`), so dropping the app's wiring only leaves a column
/// blank on a tree too large for a fixture, which only this scan sees. A source scan, as in
/// `FolderSidebarWiringTests`: `ContentView` can't be instantiated here.
@Suite struct PaneColumnsGraftWiringTests {
    static func source(_ relative: String) throws -> String { sourceCodeOnly(try repoFile(relative)) }

    static func appSource() throws -> String { try source("MacApp/ContentView.swift") }

    /// The app's `FileTreeView` hands the request to the manager for its own pane's side. Dropped,
    /// columns past the node budget stay blank; on the wrong side, the graft lands in the other pane's
    /// tree. A hardcoded `true` would look right in Browse and fail only in Compare's right pane.
    @Test func thePaneWiresTheRequestToTheManagerForItsOwnSide() throws {
        let call = try CallArguments(of: "FileTreeView(", in: try Self.appSource())
        #expect(call.passes("onNeedChildren", "{ syncManager.loadColumnChildren(atPath: $0, isLeft: pane.isLeft, passive: $1) }"),
                "the pane's graft request is missing, reaches something other than loadColumnChildren, or names the wrong side")
    }

    /// `graftsInFlight` is wired to the same pane: it tells a directory being read from one that
    /// couldn't be. It defaults to `[]`, so dropped, every graft says "Can't be read" while it lists;
    /// on the wrong side, the other pane's spinner shows over this pane's folder.
    @Test func theBeingReadSetIsWiredToThisPaneToo() throws {
        let code = try Self.appSource()
        #expect(code.contains("graftsInFlight: syncManager.columnGraftsInFlightPaths(isLeft: pane.isLeft)"),
                "the pane cannot tell a directory being read from one that could not be, and says “Can’t be read” for both")
    }
}
