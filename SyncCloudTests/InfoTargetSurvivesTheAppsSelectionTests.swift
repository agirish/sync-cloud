import Testing
import Foundation
@testable import SyncCloud

/// **The app's own selection does not retire a Get Info target** (TE47's payment, 2026-09-25).
///
/// A selection change in the left pane clears `infoPath`, so the inspector follows the new
/// selection. The owed selection (TE47) is paid when the pane's tree publishes — possibly after the
/// user has used a rail row's Get Info on another file — and that payment is a selection change the
/// user did not make: it jumped the inspector to the document. The payment is marked
/// (`editorPaneSelectionPaid`) before it is written; the clear reads the mark.
@Suite struct InfoTargetSurvivesTheAppsSelectionTests {

    @Test func theAppsOwnWriteKeepsTheTarget() {
        #expect(!ContentView.leftSelectionClearsInfoTarget(["/c/notes.md"], paidSelection: "/c/notes.md"))
    }

    @Test func everyOtherChangeClearsIt() {
        #expect(ContentView.leftSelectionClearsInfoTarget(["/c/notes.md"], paidSelection: nil))
        #expect(ContentView.leftSelectionClearsInfoTarget(["/c/other.md"], paidSelection: "/c/notes.md"))
        #expect(ContentView.leftSelectionClearsInfoTarget(["/c/notes.md", "/c/other.md"], paidSelection: "/c/notes.md"))
        #expect(ContentView.leftSelectionClearsInfoTarget([], paidSelection: "/c/notes.md"))
    }

    /// The clear is read in the selection handler BEFORE the one-click open consumes the mark, and
    /// the unconditional left-pane clear is gone; the right pane's stays.
    @Test func theClearReadsTheMarkBeforeItIsConsumed() throws {
        let content = try EditorDivergenceWiringTests.source("ContentView.swift")
        let start = try #require(content.range(of: ".onChange(of: syncManager.selectedLeftPaths) { _, paths in"))
        let handler = content[start.upperBound...].prefix(400)
        let clear = try #require(handler.range(of: "clearInfoTargetAfterLeftSelection(paths)"),
                                 "the left pane's selection no longer clears the Get Info target at all")
        let open = try #require(handler.range(of: "openSelectedPaneFileInEditor(paths)"))
        #expect(clear.lowerBound < open.lowerBound, "the mark is consumed before the clear reads it")
        #expect(!content.contains(".onChange(of: syncManager.selectedLeftPaths) { _, _ in infoPath = nil }"),
                "an unconditional clear is back — the app's own write clears the target again")
        #expect(content.contains(".onChange(of: syncManager.selectedRightPaths) { _, paths in clearInfoTargetAfterRightSelection(paths) }"),
                "the right pane's selection no longer reaches the Get Info target's clear")
        let body = try EditorNewFilePaneWiringTests.body(of: "func clearInfoTargetAfterLeftSelection(_ paths: Set<String>) {",
                                                         in: "ContentView.swift")
        #expect(body.contains("paidSelection: editorPaneSelectionPaid"))
    }

    /// **The right pane's half** (2026-09-26). Paying the debt now clears the right pane whatever
    /// it holds, as a left-pane click would — and a Get Info target used on a rail row while the
    /// debt waited was retired by that clear, the same jump the left pane's marker exists to stop.
    /// The clear is marked; the user's own changes there, and the marker left unconsumed by
    /// anything but an emptying change, still clear it.
    @Test func theAppsClearOfTheRightPaneKeepsTheTarget() {
        #expect(!ContentView.rightSelectionClearsInfoTarget([], clearWasPaid: true))
        #expect(ContentView.rightSelectionClearsInfoTarget([], clearWasPaid: false))
        #expect(ContentView.rightSelectionClearsInfoTarget(["/d/x.md"], clearWasPaid: false))
        #expect(ContentView.rightSelectionClearsInfoTarget(["/d/x.md"], clearWasPaid: true),
                "a selection the user made in the right pane was taken for the app's clear")
    }

    /// The marker is one-shot — read, then lowered, before the rule is asked — so it cannot outlive
    /// the change it announced and swallow the user's own later clear.
    @Test func theRightMarkerIsConsumedByTheChangeItAnnounced() throws {
        let body = try EditorNewFilePaneWiringTests.body(of: "func clearInfoTargetAfterRightSelection(_ paths: Set<String>) {",
                                                         in: "ContentView.swift")
        let read = try #require(body.range(of: "let paid = editorPaneRightClearPaid"))
        let lower = try #require(body.range(of: "editorPaneRightClearPaid = false"),
                                 "the marker is never lowered — the user's next clear would keep a stale target")
        let rule = try #require(body.range(of: "Self.rightSelectionClearsInfoTarget(paths, clearWasPaid: paid)"))
        #expect(read.lowerBound < lower.lowerBound && lower.lowerBound < rule.lowerBound)
        #expect(body.contains("{ infoPath = nil }"))
    }
}
