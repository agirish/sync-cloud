import AppKit
import SwiftUI
import Testing
import Design
@testable import SyncCloud

/// What a view in the panel's hosting view lived through, counted from inside it.
@MainActor
private final class ColumnProbe {
    var states: Set<UUID> = []
    var appeared = 0
    var disappeared = 0
}

private struct ColumnProbeView: View {
    let probe: ColumnProbe
    @State private var token = UUID()

    var body: some View {
        Color.clear
            .onAppear { probe.appeared += 1; probe.states.insert(token) }
            .onDisappear { probe.disappeared += 1 }
    }
}

/// The pinned panel and the floating panel share one hosting view: pinning moves it into the
/// window's column and unpinning moves it back, and nothing inside is rebuilt on the way.
@MainActor
@Suite(.serialized) struct AskClaudeColumnTests {

    private func offscreenWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1000, height: 760),
                 styleMask: [.borderless], backing: .buffered, defer: true)
    }

    private func settle() async { for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(10)) } }

    @Test func pinningAndUnpinningMovesOneHostWithoutRebuildingIt() async throws {
        let parent = offscreenWindow()
        let columnWindow = offscreenWindow()
        let column = AskClaudeColumnView(frame: NSRect(x: 628, y: 0, width: 372, height: 760))
        columnWindow.contentView?.addSubview(column)
        let probe = ColumnProbe()
        let controller = AskClaudeWindowController()
        controller.container = NSRect(x: -30_000, y: -30_000, width: 1000, height: 720)
        controller.panelRect = CGRect(x: 10, y: 300, width: 372, height: 400)
        column.controller = controller
        let content = AnyView(ColumnProbeView(probe: probe))

        controller.isPinned = false
        controller.show(content, over: parent, activate: false)
        await settle()
        #expect(parent.childWindows?.count == 1)

        for cycle in 1...20 {
            controller.isPinned = true
            controller.columnView = column
            controller.show(content, over: parent, activate: false)
            await settle()
            #expect(column.subviews.count == 1, "cycle \(cycle): the host is in the column")
            #expect(parent.childWindows?.isEmpty == true, "cycle \(cycle): the window gave way")

            controller.isPinned = false
            controller.show(content, over: parent, activate: false)
            await settle()
            #expect(column.subviews.isEmpty, "cycle \(cycle): the host left the column")
            #expect(parent.childWindows?.count == 1, "cycle \(cycle): the window is back")
        }
        // One life for what is inside: it kept one state through every move. SwiftUI reports each
        // move as a disappearance and an appearance, so the panel treats those as a move (its
        // `leavingForAnotherWindow`); here the two stay in step, and it ends on screen.
        #expect(probe.states.count == 1, "the view's state was rebuilt \(probe.states.count) times")
        #expect(probe.appeared == probe.disappeared + 1, "appeared \(probe.appeared), disappeared \(probe.disappeared)")
        controller.hide()
        #expect(parent.childWindows?.isEmpty == true)
        #expect(column.subviews.isEmpty)
    }

    /// Busy while pinned: the column stays where it is, dimmed and deaf, and comes back as it was.
    @Test func aBusyWindowPausesTheColumnInsteadOfRemovingIt() async throws {
        let parent = offscreenWindow()
        let columnWindow = offscreenWindow()
        let column = AskClaudeColumnView(frame: NSRect(x: 628, y: 0, width: 372, height: 760))
        columnWindow.contentView?.addSubview(column)
        let probe = ColumnProbe()
        let controller = AskClaudeWindowController()
        column.controller = controller
        controller.isPinned = true
        controller.columnView = column
        controller.show(AnyView(ColumnProbeView(probe: probe)), over: parent, activate: false)
        await settle()
        #expect(column.subviews.count == 1)
        controller.isSuspended = true
        #expect(column.isPaused && column.alphaValue == 0.5)
        #expect(column.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(column.subviews.count == 1, "pinned, a busy window leaves the column in place")
        controller.isSuspended = false
        #expect(!column.isPaused && column.alphaValue == 1)
        #expect(probe.states.count == 1 && probe.appeared == probe.disappeared + 1)
        controller.hide()
    }

    /// The inner edge's drag, held to the panel's width range and to the room there is.
    @Test func theColumnsDragWidthIsHeldToItsRangeAndTheRoom() {
        // Dragging left widens it.
        #expect(AskClaudePanel.pinnedDragWidth(base: 372, translation: -50) == 422)
        #expect(AskClaudePanel.pinnedDragWidth(base: 372, translation: 50) == 322)
        #expect(AskClaudePanel.pinnedDragWidth(base: 372, translation: 500) == 300)
        #expect(AskClaudePanel.pinnedDragWidth(base: 372, translation: -900) == 720)
        // Less room than the range allows: the room wins, never under the minimum.
        #expect(AskClaudePanel.pinnedDragWidth(base: 372, translation: -200, room: 500) == 500)
        #expect(AskClaudePanel.pinnedDragWidth(base: 372, translation: -200, room: 250) == 300)
    }
}
