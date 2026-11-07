import Testing
import Foundation
@testable import SyncCloud

/// The app's own selection doesn't retire a Get Info target. A left-pane selection change clears
/// `infoPath` so the inspector follows the selection. The owed pane selection is paid when the
/// pane's tree publishes, possibly after the user used a rail row's Get Info on another file, and
/// unmarked it would jump the inspector to the document. The payment is marked
/// (`editorPaneSelectionPaid`) before it is written, and the clear reads the mark.
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

    /// The selection handler reads the mark before the one-click open consumes it, and there is no
    /// unconditional left-pane clear; the right pane's goes through its own rule.
    @Test func theClearReadsTheMarkBeforeItIsConsumed() throws {
        let source = try macAppFile("ContentView.swift")
        let content = CodeText(source)
        // The handler's own closure, brace-bounded.
        let handler = CodeText(try declarationBody(of: ".onChange(of: syncManager.selectedLeftPaths) { _, paths in",
                                                   in: source))
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
        #expect(try CallArguments(of: "Self.leftSelectionClearsInfoTarget(", in: body.normalized)
                    .passes("paidSelection", "editorPaneSelectionPaid"))
    }

    /// The right pane's half. Paying the debt clears the right pane, as a left-pane click would, and
    /// unmarked that clear would retire a Get Info target used on a rail row while the debt waited.
    /// The clear is marked; the user's own changes there still clear the target.
    @Test func theAppsClearOfTheRightPaneKeepsTheTarget() {
        #expect(!ContentView.rightSelectionClearsInfoTarget([], clearWasPaid: true))
        #expect(ContentView.rightSelectionClearsInfoTarget([], clearWasPaid: false))
        #expect(ContentView.rightSelectionClearsInfoTarget(["/d/x.md"], clearWasPaid: false))
        #expect(ContentView.rightSelectionClearsInfoTarget(["/d/x.md"], clearWasPaid: true),
                "a selection the user made in the right pane was taken for the app's clear")
    }

    /// The marker is one-shot (read, then lowered, before the rule is asked), so it can't outlive
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
