@testable import SyncCloud
import Sync
import Testing
import Foundation

/// **Entering a lens leaves the left pane where it is — and Compare still gets its comparisons.**
///
/// Browse, Organize's source rail and Compare's left pane are one pane over one folder. Entering
/// Organize used to re-home it to the provider root, so a folder open in Browse was gone on the way
/// back, and Organize always opened on the whole source. The pane now keeps its folder across every
/// switch, in both directions.
///
/// That re-home was also the one pane move that skipped the two-pane comparison (a flag raised and
/// lowered around its `focusOn`), and the comparison it skipped was owed to Compare. With no move
/// there is nothing to skip: every pane move compares, and the only opt-out left is Edit's re-read
/// after a file it wrote, whose debt Compare still settles.
///
/// `ContentView` is a `View` with `@State` and cannot be instantiated, so the wiring is read off its
/// own source, comments stripped, each check anchored on something that must be present so a stale
/// scan fails loudly rather than passing.
@Suite struct LensEntryContinuityTests {

    private static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(file)")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read \(file) — this scan would be vacuous")
        try #require(raw.count > 5000, "\(file) is implausibly short — the scan is vacuous")
        // The shared lexer: this cut every line at its first `//`, inside a string or not.
        return sourceCodeOnly(raw)
    }

    /// One member's body, to its own closing brace — the shared
    /// ``declarationBody(of:in:sourceLocation:)``, asked whitespace-insensitively (``CodeText``).
    /// Structural rather than a character budget, for the reason `FolderSidebarOpenTargetingTests`
    /// gives: a budget is a window that truncates under an unrelated edit and then fails a test
    /// about something else. It replaced a regex that ended at the next line opening a `func` or
    /// `var` at four spaces, which read on through a `let`, an `init` or a nested type, and to the
    /// end of the file after the last member.
    private static func body(of declaration: String, in source: String,
                             sourceLocation: SourceLocation = #_sourceLocation) throws -> CodeText {
        CodeText(try declarationBody(of: declaration, in: source, sourceLocation: sourceLocation))
    }

    /// **Entering a lens shows the rail and moves no pane.** Anchored on the rail override, which the
    /// function must still write — the scan below is aimed at the right body, not at nothing — and
    /// then required to hold no pane move of any kind: the provider-root `focusOn` it used to end
    /// with, or any other way of re-pointing the left pane.
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

    /// **Every pane move compares.** The refresh handler used to skip the comparison for the one
    /// move the lens entry made; with no such move it has nothing to tell apart, and a flag that
    /// could only ever be false would be a way for the next edit to strip comparisons silently.
    @Test func everyPaneMoveCompares() throws {
        let code = try Self.source("ContentView.swift")
        #expect(code.contains(".onReceive(syncManager.refreshSubject) { scope in"),
                "the refresh handler moved — the check below is aimed at nothing")
        #expect(code.contains("refreshAction(reloading: scope)"),
                "the refreshSubject handler no longer reloads the scope it was sent")
        #expect(!code.contains("isReHomingForLensEntry"),
                "the lens-entry flag is back, with no move left for it to describe")
        #expect(code.contains("reloading: reloading, comparing: comparing)"),
                "refreshAction no longer passes the decision through to the manager")
    }

    /// **Every caller compares but one**: a file operation, a forced rescan, a provider switch and
    /// ordinary navigation all reach `refreshAction` without naming `comparing`, and its default is
    /// `true`. Edit's re-read after a file it wrote itself is the one opt-out (TE47 review), and it
    /// lives outside this file.
    @Test func skippingTheComparisonIsOptInAtExactlyOneCallSite() throws {
        let code = try Self.source("ContentView.swift")
        #expect(code.contains("comparing: Bool = true"),
                "the parameter no longer defaults to comparing, so every caller silently lost its scan")
        #expect(!code.contains("comparing: !") && !code.contains("comparing: false"),
                "ContentView opts a refresh out of its comparison again — only Edit's re-read is meant to")
        // The one other opt-out, in Edit (TE47 review): its re-read after a file it made itself
        // compares only in Compare, and owes the comparison anywhere else.
        let editor = try Self.source("ContentView+Editor.swift")
        let reread = try Self.body(of: "func rereadPanesAfterEditorWrite(_ path: String) {", in: editor)
        #expect(reread.contains("if selectedWorkspace == .compare {")
                && reread.contains("refreshAction(reloading: scope, comparing: false)"),
                "Edit's re-read no longer compares only in Compare")
        #expect(editor.components(separatedBy: "comparing: false").count - 1 == 1
                && !editor.contains("comparing: !"),
                "Edit opts out of the comparison somewhere else too")
    }

    /// **A skipped comparison is owed, not cancelled.** Edit's re-read outside Compare reloads a
    /// pane without comparing, so the differences in hand can describe files as they were before the
    /// write. Entering Compare runs no scan of its own (`presentLensRail` early-returns for Compare,
    /// which has no lens), so without a debt to settle the differences list would draw stale rows
    /// under correct pane headers — worse than the "not scanned" card.
    @Test func theSkippedComparisonIsRecordedAndSettledOnEnteringCompare() throws {
        let code = try Self.source("ContentView.swift")
        let refresh = try Self.body(of: "func refreshAction(reloading:", in: code)
        #expect(refresh.contains("owedComparison.skipped = OwedComparison.skippedByARefresh"),
                "a refresh that skips its comparison does not record the debt, so Compare would show a comparison of a folder the left pane was moved off")

        // The one record and the one payment are `OwedComparisonTests`; what matters here is that
        // a skipped comparison's debt, alone, is settled with a comparison of the folders the panes are on.
        #expect(ContentView.OwedComparison(skipped: ContentView.OwedComparison.skippedByARefresh)
                    .payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .compare(because: ContentView.OwedComparison.skippedByARefresh),
                "a skipped comparison alone is not paid with a comparison")
        let settle = try Self.body(of: "func payOwedComparisonIfNeeded() {", in: code)
        #expect(settle.contains("syncManager.scanDirectories("),
                "the debt is settled with something other than a comparison")
        #expect(settle.contains("leftPath: currentLeftPath"),
                "the settling scan is aimed at a path the panes are not on")

        // The `if`'s own braces, where it was the next 80 characters.
        let arrive = try Self.body(of: "if workspace == .compare {", in: code)
        #expect(arrive.contains("payOwedComparisonIfNeeded()"),
                "nothing settles the debt on the way into Compare — the one workspace that displays a comparison")
    }

    /// And it is settled from `onChange(of: selectedWorkspace)` rather than from the bar's binding,
    /// because every programmatic switch — `show(_:)`, the duplicate-review handoff — assigns the
    /// workspace directly and goes around that binding. Compare is exactly where those land.
    @Test func theSettleRidesTheWorkspaceChangeNotTheBarBinding() throws {
        let code = try Self.source("ContentView.swift")
        let binding = try Self.body(of: "var workspaceSelection: Binding<Workspace> {", in: code)
        #expect(!binding.contains("payOwedComparisonIfNeeded"),
                "the settle hangs off the workspace bar, so ⌘K and the duplicate-review handoff into Compare skip it")
        #expect(binding.contains("presentLensRail(for: newWorkspace)"),
                "the workspace bar no longer shows the source rail on entry into a lens")
    }
}
