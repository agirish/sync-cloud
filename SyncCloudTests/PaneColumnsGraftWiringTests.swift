@testable import SyncCloud
import Testing
import Foundation

/// **That the graft chain is actually connected**, end to end, in the app.
///
/// `onNeedChildren` is defaulted to a no-op at both hops — `PaneColumnsView` and `FileTreeView` —
/// so that the many test call sites predating it keep compiling. That default is also the exact
/// shape of a silent break: drop the app's wiring and every test still passes, every build still
/// succeeds, and the only symptom is a column that stays blank on a large tree, which is the state
/// the node budget was introduced to avoid. Nothing else in the suite can see the difference,
/// because the budget only engages on trees too big to put in a fixture.
///
/// Scanned against the app's own source for `FolderSidebarWiringTests`' reason: `ContentView` is a
/// `View` with `@State` and cannot be instantiated here.
@Suite struct PaneColumnsGraftWiringTests {

    static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read \(relative) — this scan would be vacuous")
        try #require(raw.count > 3000, "\(relative) is implausibly short — the scan is vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    static func appSource() throws -> String { try source("MacApp/ContentView.swift") }

    @Test func theScanCanSeeAKnownSymbol() throws {
        #expect(try Self.appSource().contains("onColumnNavigate:"),
                "the scan cannot see the pane's own call site, so nothing below means anything")
    }

    /// The app's `FileTreeView` must hand the request to the manager. Both halves are asserted:
    /// that the parameter is passed at all, and that what it is passed reaches
    /// `loadColumnChildren` — a closure wired to something else would satisfy the first alone.
    @Test func thePaneWiresTheRequestToTheManager() throws {
        let code = try Self.appSource()
        #expect(code.contains("onNeedChildren:"),
                "the pane no longer passes onNeedChildren — it defaults to a no-op, so columns past the node budget stay blank")
        #expect(code.contains("syncManager.loadColumnChildren(atPath:"),
                "onNeedChildren is wired to something other than loadColumnChildren")
    }

    /// **The "being read" set is wired too, and to the same pane.**
    ///
    /// `graftsInFlight` is what separates a directory *being* read from one that *could not* be —
    /// both are an empty child list plus an unexplored mark, and the column called both of them
    /// "Can't be read". It defaults to `[]`, so dropping it puts that false caption back over every
    /// graft for as long as the listing runs, with nothing failing. Wired to the wrong side it is
    /// worse than absent: the other pane's spinner appears over this pane's folder.
    @Test func theBeingReadSetIsWiredToThisPaneToo() throws {
        let code = try Self.appSource()
        #expect(code.contains("graftsInFlight: syncManager.columnGraftsInFlightPaths(isLeft: pane.isLeft)"),
                "the pane cannot tell a directory being read from one that could not be, and says “Can’t be read” for both")
    }

    /// **The side must be the pane's own.** Wired to the wrong side, the request grafts into the
    /// other pane's tree — where the path is very likely absent, so `grafting` returns nil, nothing
    /// happens, and the column stays blank with no error anywhere. A hardcoded `true` would look
    /// correct in Browse, which has one pane, and fail only in Compare's right-hand pane.
    @Test func theRequestCarriesTheRequestingPanesSide() throws {
        let code = try Self.appSource()
        #expect(code.contains("loadColumnChildren(atPath: $0, isLeft: pane.isLeft)"),
                "the graft request does not carry the requesting pane's own side")
    }
}
