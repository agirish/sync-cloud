import Testing
import Foundation
import Sync
@testable import SyncCloud

/// The app's own selection doesn't retire a Get Info target. A left-pane selection change clears
/// the left pane's target (`infoTargets`) so its Info follows the selection. The owed pane selection is paid when the
/// pane's tree publishes, possibly after the user used a rail row's Get Info on another file, and
/// unmarked it would jump the inspector to the document. The payment is marked
/// (`editorPaneSelectionPaid`) before it is written, and the clear reads the mark.
@Suite struct InfoTargetSurvivesTheAppsSelectionTests {

    @Test func theAppsOwnWriteKeepsTheTarget() {
        #expect(!ContentView.leftSelectionClearsInfoTarget(["/c/notes.md"], paidSelection: "/c/notes.md", otherPane: []))
    }

    @Test func everyOtherChangeClearsIt() {
        #expect(ContentView.leftSelectionClearsInfoTarget(["/c/notes.md"], paidSelection: nil, otherPane: []))
        #expect(ContentView.leftSelectionClearsInfoTarget(["/c/other.md"], paidSelection: "/c/notes.md", otherPane: []))
        #expect(ContentView.leftSelectionClearsInfoTarget(["/c/notes.md", "/c/other.md"], paidSelection: "/c/notes.md", otherPane: []))
        #expect(ContentView.leftSelectionClearsInfoTarget([], paidSelection: "/c/notes.md", otherPane: []))
        // A selection the person made here clears it whatever the other pane holds.
        #expect(ContentView.leftSelectionClearsInfoTarget(["/c/other.md"], paidSelection: nil, otherPane: ["/d/x.md"]))
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
        #expect(!content.contains(".onChange(of: syncManager.selectedLeftPaths) { _, _ in infoTargets.clear(isLeft: true) }"),
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
        #expect(!ContentView.rightSelectionClearsInfoTarget([], clearWasPaid: true, otherPane: []))
        #expect(ContentView.rightSelectionClearsInfoTarget([], clearWasPaid: false, otherPane: []))
        #expect(ContentView.rightSelectionClearsInfoTarget(["/d/x.md"], clearWasPaid: false, otherPane: []))
        #expect(ContentView.rightSelectionClearsInfoTarget(["/d/x.md"], clearWasPaid: true, otherPane: []),
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
        let rule = try #require(body.range(of: "Self.rightSelectionClearsInfoTarget(paths, clearWasPaid: paid, otherPane: syncManager.selectedLeftPaths)"))
        #expect(read.lowerBound < lower.lowerBound && lower.lowerBound < rule.lowerBound)
        #expect(body.contains("{ infoTargets.clear(isLeft: false) }"))
    }

    /// Each pane keeps its own Get Info target: the left pane's selection retires the left's, the
    /// right's the right's, and neither touches the other.
    @Test func eachPaneKeepsItsOwnTarget() throws {
        var targets = PaneInfoTargets()
        targets.aim("/L/a.pdf", isLeft: true)
        targets.aim("/R/b.pdf", isLeft: false)
        #expect(targets.path(isLeft: true) == "/L/a.pdf" && targets.path(isLeft: false) == "/R/b.pdf")
        targets.clear(isLeft: false)
        #expect(targets.path(isLeft: true) == "/L/a.pdf", "the right pane's selection took the left pane's target")
        #expect(targets.path(isLeft: false) == nil)
        targets.aim("/R/b.pdf", isLeft: false)
        targets.clear(isLeft: true)
        #expect(targets.path(isLeft: false) == "/R/b.pdf", "the left pane's selection took the right pane's target")
        // The node read off the disk lands only on the side, and the path, it was read for.
        let node = FileNode(id: "/R/b.pdf", name: "b.pdf", isDirectory: false)
        targets.found(node, for: "/R/b.pdf", isLeft: true)
        #expect(targets.node(isLeft: true) == nil && targets.node(isLeft: false) == nil)
        targets.found(node, for: "/R/b.pdf", isLeft: false)
        #expect(targets.node(isLeft: false)?.id == "/R/b.pdf")
        targets.aim("/R/c.pdf", isLeft: false)
        #expect(targets.node(isLeft: false) == nil, "a new target kept the old one's node")
        targets.clearAll()
        #expect(targets.path(isLeft: true) == nil && targets.path(isLeft: false) == nil)

        // The window: each selection handler clears its own side, and Get Info aims the side that
        // holds the path.
        let left = try EditorNewFilePaneWiringTests.body(of: "func clearInfoTargetAfterLeftSelection(_ paths: Set<String>) {",
                                                         in: "ContentView.swift")
        #expect(left.contains("infoTargets.clear(isLeft: true)") && !left.contains("isLeft: false"))
        let show = CodeText(try declarationBody(of: "func showInfo(for path: String) {", in: macAppFile("ContentView.swift")))
        #expect(show.contains("let isLeft = paneInfoTargetIsLeft(for: path)"))
        #expect(show.contains("infoTargets.aim(path, isLeft: isLeft)"))
        #expect(show.contains("infoTargets.found(node, for: path, isLeft: isLeft)"))
    }

    /// Stands in for `FileSyncManager`'s selection properties.
    @MainActor private final class Selections: PaneSelectionState {
        var selectedLeftPaths: Set<String> = []
        var selectedRightPaths: Set<String> = []
        var lastSelectionSurface: SelectionSurface? = nil
    }

    /// The whole chain: a click in one pane goes through `applySelectionWrite`, which clears the
    /// other pane's selection a turn later, and each pane's change reaches its own rule as the
    /// window's handlers pass it (the other pane's selection read live). The other pane's Get Info
    /// target survives that clear; a click in the pane itself still retires it.
    @MainActor @Test func aClickInTheOtherPaneKeepsThisPanesTarget() throws {
        let state = Selections(), sequencer = PaneSelectionSequencer()
        var queued: [() -> Void] = []
        var targets = PaneInfoTargets()
        // What the window's `onChange` handlers do with each pane's new selection.
        func publish(isLeft: Bool) {
            let clears = isLeft
                ? ContentView.leftSelectionClearsInfoTarget(state.selectedLeftPaths, paidSelection: nil,
                                                            otherPane: state.selectedRightPaths)
                : ContentView.rightSelectionClearsInfoTarget(state.selectedRightPaths, clearWasPaid: false,
                                                             otherPane: state.selectedLeftPaths)
            if clears { targets.clear(isLeft: isLeft) }
        }
        func click(_ paths: Set<String>, isLeft: Bool) {
            let before = (state.selectedLeftPaths, state.selectedRightPaths)
            PaneLogic.applySelectionWrite(paths, isLeft: isLeft, state: state, sequencer: sequencer,
                                          schedule: { queued.append($0) })
            if state.selectedLeftPaths != before.0 { publish(isLeft: true) }
            if state.selectedRightPaths != before.1 { publish(isLeft: false) }
            let pending = queued
            queued = []
            for block in pending {
                let mid = (state.selectedLeftPaths, state.selectedRightPaths)
                block()
                if state.selectedLeftPaths != mid.0 { publish(isLeft: true) }
                if state.selectedRightPaths != mid.1 { publish(isLeft: false) }
            }
        }

        // Compare: the right pane has a row selected and Get Info on it; then a click on the left.
        click(["/R/b.pdf"], isLeft: false)
        targets.aim("/R/b.pdf", isLeft: false)
        targets.aim("/L/a.pdf", isLeft: true)
        click(["/L/c.pdf"], isLeft: true)
        #expect(state.selectedRightPaths.isEmpty, "the fixture never cleared the right pane, so it tests nothing")
        #expect(targets.path(isLeft: false) == "/R/b.pdf", "the left pane's click took the right pane's Get Info target")
        #expect(targets.path(isLeft: true) == nil, "the left pane's own click kept its old target")

        // And the other way round.
        targets.aim("/L/a.pdf", isLeft: true)
        click(["/R/d.pdf"], isLeft: false)
        #expect(state.selectedLeftPaths.isEmpty)
        #expect(targets.path(isLeft: true) == "/L/a.pdf", "the right pane's click took the left pane's Get Info target")
        #expect(targets.path(isLeft: false) == nil, "the right pane's own click kept its old target")

        // The window's handlers pass the other pane's live selection.
        let left = try EditorNewFilePaneWiringTests.body(of: "func clearInfoTargetAfterLeftSelection(_ paths: Set<String>) {",
                                                         in: "ContentView.swift")
        #expect(try CallArguments(of: "Self.leftSelectionClearsInfoTarget(", in: left.normalized)
                    .passes("otherPane", "syncManager.selectedRightPaths"))
        let right = try EditorNewFilePaneWiringTests.body(of: "func clearInfoTargetAfterRightSelection(_ paths: Set<String>) {",
                                                          in: "ContentView.swift")
        #expect(try CallArguments(of: "Self.rightSelectionClearsInfoTarget(", in: right.normalized)
                    .passes("otherPane", "syncManager.selectedLeftPaths"))
    }
}
