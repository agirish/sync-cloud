@testable import SyncCloud
import Sync
import Testing
import Foundation

/// Entering a lens leaves the left pane where it is, and Compare still gets its comparisons.
/// Browse, Organize's source rail and Compare's left pane are one pane over one folder, which keeps
/// its folder across every switch, both ways; re-homing it on entry would lose the folder open in
/// Browse. Every pane move compares; the one opt-out is Edit's re-read after its own write, whose
/// debt Compare settles. `ContentView` can't be instantiated, so the wiring is read off its source,
/// comments stripped, each check anchored on something that must be present.
@Suite struct LensEntryContinuityTests {

    private static func source(_ file: String) throws -> String { sourceCodeOnly(try macAppFile(file)) }

    /// One member's body, to its own closing brace: the shared
    /// ``declarationBody(of:in:sourceLocation:)``, asked whitespace-insensitively (``CodeText``).
    /// Structural, not a character budget, which an unrelated edit could truncate (as
    /// `FolderSidebarOpenTargetingTests` explains).
    private static func body(of declaration: String, in source: String,
                             sourceLocation: SourceLocation = #_sourceLocation) throws -> CodeText {
        CodeText(try declarationBody(of: declaration, in: source, sourceLocation: sourceLocation))
    }

    /// Entering a lens shows the rail and moves no pane. Anchored on the rail override, which the
    /// function must still write, so the scan is aimed at the right body; then no pane move of any
    /// kind may appear (a `focusOn`, or any other way of re-pointing the left pane).
    @Test func enteringALensLeavesTheLeftPaneWhereItIs() throws {
        let code = try Self.source("ContentView.swift")
        let body = try Self.body(of: "func presentLensRail(for workspace: Workspace) {", in: code)
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
        let code = try Self.source("ContentView.swift")
        #expect(code.contains(".onReceive(syncManager.refreshSubject) { scope in"),
                "the refresh handler moved — the check below is aimed at nothing")
        #expect(code.contains("refreshAction(reloading: scope)"),
                "the refreshSubject handler no longer reloads the scope it was sent")
        #expect(code.contains("reloading: reloading, comparing: comparing)"),
                "refreshAction no longer passes the decision through to the manager")
    }

    /// Every caller compares but one: file operations, forced rescans, provider switches and
    /// navigation reach `refreshAction` without naming `comparing`, which defaults to `true`. Edit's
    /// re-read after a file it wrote is the one opt-out, and lives outside this file.
    @Test func skippingTheComparisonIsOptInAtExactlyOneCallSite() throws {
        let code = try Self.source("ContentView.swift")
        #expect(code.contains("comparing: Bool = true"),
                "the parameter no longer defaults to comparing, so every caller silently lost its scan")
        #expect(!code.contains("comparing: !") && !code.contains("comparing: false"),
                "ContentView opts a refresh out of its comparison again — only Edit's re-read is meant to")
        // The one opt-out, in Edit: its re-read after its own write compares only in Compare, and
        // owes the comparison anywhere else.
        let editor = try Self.source("ContentView+Editor.swift")
        let reread = try Self.body(of: "func rereadPanesAfterEditorWrite(_ path: String, writer: String = \"Edit wrote\", comparesInCompare: Bool = true) {", in: editor)
        #expect(reread.contains("if selectedWorkspace == .compare, comparesInCompare {")
                && reread.contains("refreshAction(reloading: scope, comparing: false)"),
                "Edit's re-read no longer compares only in Compare")
        #expect(editor.components(separatedBy: "comparing: false").count - 1 == 1
                && !editor.contains("comparing: !"),
                "Edit opts out of the comparison somewhere else too")
    }

    /// A skipped comparison is owed, not cancelled. Edit's re-read outside Compare reloads a pane
    /// without comparing, so the differences in hand can describe files as they were before the
    /// write. Entering Compare runs no scan of its own (`presentLensRail` returns early for it), so
    /// without the debt the list would draw stale rows under correct headers, worse than "not
    /// scanned".
    @Test func theSkippedComparisonIsRecordedAndSettledOnEnteringCompare() throws {
        let code = try Self.source("ContentView.swift")
        let refresh = try Self.body(of: "func refreshAction(reloading:", in: code)
        #expect(refresh.contains("owedComparison.skipped = OwedComparison.skippedByARefresh"),
                "a refresh that skips its comparison does not record the debt, so Compare would show a comparison of a folder the left pane was moved off")

        // The record and payment rules are `OwedComparisonTests`; here, a skipped comparison's debt
        // alone is settled with a comparison of the folders the panes are on.
        #expect(ContentView.OwedComparison(skipped: ContentView.OwedComparison.skippedByARefresh)
                    .payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .compare(because: ContentView.OwedComparison.skippedByARefresh),
                "a skipped comparison alone is not paid with a comparison")
        let settle = try Self.body(of: "func payOwedComparisonIfNeeded() {", in: code)
        #expect(settle.contains("syncManager.scanDirectories("),
                "the debt is settled with something other than a comparison")
        #expect(settle.contains("leftPath: currentLeftPath"),
                "the settling scan is aimed at a path the panes are not on")

        // The `if`'s own braces.
        let arrive = try Self.body(of: "if workspace == .compare {", in: code)
        #expect(arrive.contains("payOwedComparisonIfNeeded()"),
                "nothing settles the debt on the way into Compare — the one workspace that displays a comparison")
    }

    /// The debt is settled from `onChange(of: selectedWorkspace)`, not the bar's binding: every
    /// programmatic switch (`show(_:)`, the duplicate-review handoff) assigns the workspace
    /// directly, around the binding, and Compare is where those land.
    @Test func theSettleRidesTheWorkspaceChangeNotTheBarBinding() throws {
        let code = try Self.source("ContentView.swift")
        let binding = try Self.body(of: "var workspaceSelection: Binding<Workspace> {", in: code)
        #expect(!binding.contains("payOwedComparisonIfNeeded"),
                "the settle hangs off the workspace bar, so ⌘K and the duplicate-review handoff into Compare skip it")
        #expect(binding.contains("presentLensRail(for: newWorkspace)"),
                "the workspace bar no longer shows the source rail on entry into a lens")
    }
}
