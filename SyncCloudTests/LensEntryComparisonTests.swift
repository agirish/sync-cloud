@testable import SyncCloud
import Sync
import Testing
import Foundation

/// **Entering a lens no longer drags a two-pane comparison behind it — and Compare still gets one.**
///
/// `presentLensRail` re-homes the source rail to the provider root on every entry into a lens. That
/// is a pane move, a pane move sends `refreshSubject`, and this view turned that into a
/// `refreshTreesAndScan` — which walked BOTH providers and diffed them, on the way into a workspace
/// that draws one tree and no differences (`FileTreeView` empties the difference index for every
/// single-source workspace, so the rows rendered nowhere). The editor makes it fire every time,
/// because it points the rail at the open file's folder.
///
/// `RefreshWithoutComparingTests` in the `Sync` package proves what `comparing: false` does. What
/// is left is the wiring, and `ContentView` is a `View` with `@State` and cannot be instantiated —
/// so it is read off its own source, comments stripped, each check anchored on something that must
/// be present so a stale scan fails loudly rather than passing.
@Suite struct LensEntryComparisonTests {

    private static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/\(file)")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read \(file) — this scan would be vacuous")
        try #require(raw.count > 5000, "\(file) is implausibly short — the scan is vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// One member's body, from its declaration to the next member declared at the type's own
    /// indentation. Structural rather than a character budget, for the reason
    /// `FolderSidebarOpenTargetingTests` gives: a budget is a window that truncates under an
    /// unrelated edit and then fails a test about something else.
    private static func body(of declaration: String, in source: String,
                             sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — this scan is aimed at nothing",
                                 sourceLocation: sourceLocation)
        let rest = String(source[start.upperBound...])
        let end = rest.range(of: #"\n {4}(@\w+ )?(private |internal )?(static )?(func|var) "#,
                             options: .regularExpression)
        return end.map { String(rest[..<$0.lowerBound]) } ?? rest
    }

    /// **The flag is raised and lowered around the one `focusOn`, in that order.**
    ///
    /// The lowering is the load-bearing half. `focusOn` no-ops when the pane is already at the root
    /// — the ordinary lens→lens entry — so nothing is sent and nothing consumes the flag; left
    /// standing it would strip the comparison off the *next*, unrelated navigation, which is a
    /// stale differences list in Compare with nothing on screen to explain it.
    @Test func theReHomeFlagIsRaisedAndLoweredAroundTheFocusCall() throws {
        let code = try Self.source("ContentView.swift")
        let body = try Self.body(of: "func presentLensRail(for workspace: Workspace) {", in: code)

        let raise = try #require(body.range(of: "sidebarRefresh.isReHomingForLensEntry = true"),
                                 "the lens entry no longer marks its re-home, so it walks and diffs both providers again")
        let focus = try #require(body.range(of: "syncManager.focusOn(relativePath: \"\", isLeft: true)"),
                                 "the re-home is gone — this scan is aimed at nothing")
        let lower = try #require(body.range(of: "sidebarRefresh.isReHomingForLensEntry = false"),
                                 "the flag is never lowered — a lens→lens entry, where focusOn no-ops, leaves it set and the next navigation silently loses its comparison")
        #expect(raise.lowerBound < focus.lowerBound,
                "the flag is raised after the move it is meant to describe")
        #expect(focus.lowerBound < lower.lowerBound,
                "the flag is lowered before the move can consume it")
    }

    /// **The refresh handler is where the flag is read**, because it is the only place that knows
    /// both which panes moved (the subject's payload) and which workspace the move was for.
    @Test func theRefreshHandlerAsksTheFlagRatherThanAlwaysComparing() throws {
        let code = try Self.source("ContentView.swift")
        #expect(code.contains("refreshAction(reloading: scope, comparing: !sidebarRefresh.isReHomingForLensEntry)"),
                "the refreshSubject handler compares unconditionally again, so entering a lens still diffs both providers")
        #expect(code.contains("reloading: reloading, comparing: comparing)"),
                "refreshAction no longer passes the decision through to the manager")
    }

    /// **Every other caller still compares**, which is what makes this a narrowing rather than a
    /// change of behaviour: a file operation, a forced rescan, a provider switch and ordinary
    /// navigation all reach `refreshAction` without naming `comparing`, and its default is `true`.
    /// Edit's re-read after a file it wrote itself is the one opt-out outside this file (TE47 review).
    @Test func skippingTheComparisonIsOptInAtExactlyOneCallSite() throws {
        let code = try Self.source("ContentView.swift")
        #expect(code.contains("comparing: Bool = true"),
                "the parameter no longer defaults to comparing, so every caller silently lost its scan")
        let optOuts = code.components(separatedBy: "comparing: !").count - 1
        #expect(optOuts == 1,
                "\(optOuts) call sites opt out of the comparison; exactly one — the lens-entry re-home — is meant to")
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

    /// **A skipped comparison is owed, not cancelled.** The pane focus has moved, so the
    /// differences in hand describe a folder the left pane is no longer on. Nothing scanned on
    /// entering Compare before this change (`presentLensRail` early-returns for Compare, which has
    /// no lens), so without a debt to settle the differences list would draw stale rows under
    /// correct pane headers — worse than the "not scanned" card.
    @Test func theSkippedComparisonIsRecordedAndSettledOnEnteringCompare() throws {
        let code = try Self.source("ContentView.swift")
        let refresh = try Self.body(of: "func refreshAction(reloading:", in: code)
        #expect(refresh.contains("owedComparison.skipped = OwedComparison.skippedByARefresh"),
                "a refresh that skips its comparison does not record the debt, so Compare would show a comparison of a folder the left pane was moved off")

        // The one record and the one payment are `OwedComparisonTests`; what matters here is that
        // a lens entry's debt, alone, is settled with a comparison of the folders the panes are on.
        #expect(ContentView.OwedComparison(skipped: ContentView.OwedComparison.skippedByARefresh)
                    .payment(leftFolder: "/c", rightFolder: "/d", links: [:])
                == .compare(because: ContentView.OwedComparison.skippedByARefresh),
                "a skipped comparison alone is not paid with a comparison")
        let settle = try Self.body(of: "func payOwedComparisonIfNeeded() {", in: code)
        #expect(settle.contains("syncManager.scanDirectories("),
                "the debt is settled with something other than a comparison")
        #expect(settle.contains("leftPath: currentLeftPath"),
                "the settling scan is aimed at a path the panes are not on")

        let arrive = try #require(code.range(of: "if workspace == .compare {"),
                                  "nothing runs on the way into Compare")
        #expect(code[arrive.upperBound...].prefix(80).contains("payOwedComparisonIfNeeded()"),
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
    }
}
