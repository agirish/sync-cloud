@testable import SyncCloud
import Sync
import Testing
import Foundation

/// Entering a lens leaves the left pane where it is, and Compare still gets its comparisons.
/// Browse, Organize's source rail and Compare's left pane are one pane that keeps its folder across
/// every switch. Every pane move compares, except Edit's re-read after its own write, whose debt
/// Compare settles. Read off `ContentView`'s source, each check anchored.
@Suite struct LensEntryContinuityTests {

    /// Entering a lens shows the rail (the anchor) and moves no pane: no `focusOn`, nor any other
    /// way of re-pointing the left pane.
    @Test func enteringALensLeavesTheLeftPaneWhereItIs() throws {
        let code = try macAppCode("ContentView.swift")
        let body = try memberBody("func presentLensRail(for workspace: Workspace) {", in: code)
        #expect(body.contains("TopPaneVisibility.settingOverride("),
                "presentLensRail no longer shows the rail — this scan is aimed at the wrong body")
        for move in ["focusOn(", "retargetPane(", "leftBrowsePath", "leftRelativePath", "isReHomingForLensEntry"] {
            #expect(!body.contains(move),
                    "entering a lens touches the left pane again (`\(move)`) — a folder open in Browse is lost on the way back from Organize")
        }
    }

    /// Every pane move compares. A lens-entry flag that skipped the comparison would have no move
    /// left to describe, and could only let a later edit strip comparisons silently.
    @Test func everyPaneMoveCompares() throws {
        let code = try macAppCode("ContentView.swift")
        #expect(code.contains(".onReceive(syncManager.refreshSubject) { scope in"),
                "the refresh handler moved — the check below is aimed at nothing")
        #expect(code.contains("refreshAction(reloading: scope)"),
                "the refreshSubject handler no longer reloads the scope it was sent")
    }

    /// Every caller compares but one: `refreshAction`'s `comparing` defaults to `true`, and Edit's
    /// re-read after its own write is the one opt-out.
    @Test func skippingTheComparisonIsOptInAtExactlyOneCallSite() throws {
        let code = try macAppCode("ContentView.swift")
        #expect(code.contains("comparing: Bool = true"),
                "the parameter no longer defaults to comparing, so every caller silently lost its scan")
        #expect(!code.contains("comparing: !") && !code.contains("comparing: false"),
                "ContentView opts a refresh out of its comparison again — only Edit's re-read is meant to")
        // The one opt-out is Edit's re-read (`OwedComparisonTests`), and only that one.
        let editor = try macAppCode("ContentView+Editor.swift")
        #expect(editor.components(separatedBy: "comparing: false").count - 1 == 1
                && !editor.contains("comparing: !"),
                "Edit opts out of the comparison somewhere else too")
    }

    /// The debt is settled from `onChange(of: selectedWorkspace)`, not the bar's binding, since
    /// programmatic switches into Compare (`show(_:)`, the duplicate-review handoff) bypass it.
    @Test func theSettleRidesTheWorkspaceChangeNotTheBarBinding() throws {
        let code = try macAppCode("ContentView.swift")
        let binding = try memberBody("var workspaceSelection: Binding<Workspace> {", in: code)
        #expect(!binding.contains("payOwedComparisonIfNeeded"),
                "the settle hangs off the workspace bar, so ⌘K and the duplicate-review handoff into Compare skip it")
        #expect(binding.contains("presentLensRail(for: newWorkspace)"),
                "the workspace bar no longer shows the source rail on entry into a lens")
    }
}
