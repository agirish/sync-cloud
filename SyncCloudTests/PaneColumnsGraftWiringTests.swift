@testable import SyncCloud
import Testing
import Foundation

/// The graft chain is connected end to end in the app. `onNeedChildren` defaults to a no-op at
/// both hops (`PaneColumnsView` and `FileTreeView`) so test call sites compile without it, which
/// means dropping the app's wiring breaks nothing visible except a column that stays blank on a
/// large tree. The node budget only engages on trees too big for a fixture, so only this scan sees
/// it. A source scan, as in `FolderSidebarWiringTests`: `ContentView` can't be instantiated here.
@Suite struct PaneColumnsGraftWiringTests {

    static func source(_ relative: String) throws -> String { sourceCodeOnly(try repoFile(relative)) }

    static func appSource() throws -> String { try source("MacApp/ContentView.swift") }

    /// The app's `FileTreeView` must hand the request to the manager: the parameter is passed, and
    /// reaches `loadColumnChildren`, since a closure wired elsewhere would satisfy the first alone.
    @Test func thePaneWiresTheRequestToTheManager() throws {
        let code = try Self.appSource()
        #expect(code.contains("onNeedChildren:"),
                "the pane no longer passes onNeedChildren — it defaults to a no-op, so columns past the node budget stay blank")
        #expect(code.contains("syncManager.loadColumnChildren(atPath:"),
                "onNeedChildren is wired to something other than loadColumnChildren")
    }

    /// The "being read" set is wired too, to the same pane. `graftsInFlight` tells a directory
    /// being read from one that couldn't be (both are an empty child list and an unexplored mark).
    /// It defaults to `[]`, so dropping it would caption every graft "Can't be read" while it lists;
    /// wired to the wrong side, the other pane's spinner shows over this pane's folder.
    @Test func theBeingReadSetIsWiredToThisPaneToo() throws {
        let code = try Self.appSource()
        #expect(code.contains("graftsInFlight: syncManager.columnGraftsInFlightPaths(isLeft: pane.isLeft)"),
                "the pane cannot tell a directory being read from one that could not be, and says “Can’t be read” for both")
    }

    /// The side must be the pane's own. Wired to the wrong side, the request grafts into the other
    /// pane's tree, where the path is likely absent, so the column stays blank with no error. A
    /// hardcoded `true` would look right in Browse and fail only in Compare's right pane.
    @Test func theRequestCarriesTheRequestingPanesSide() throws {
        let code = try Self.appSource()
        #expect(code.contains("loadColumnChildren(atPath: $0, isLeft: pane.isLeft, passive: $1)"),
                "the graft request does not carry the requesting pane's own side, or drops whether it is a scroll past")
    }
}
