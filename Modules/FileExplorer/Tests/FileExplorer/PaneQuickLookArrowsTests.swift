import Testing
import AppKit
import Quartz
import Design
@testable import FileExplorer

/// Pins `PaneQuickLookArrows`: while Quick Look holds the keys and follows the pane, ↑ and ↓ move
/// the pane's selection; any other preview, key or focus keeps them where they were.
/// `.serialized` because `followsPane` is one static the cases share.
@MainActor
@Suite(.serialized) struct PaneQuickLookArrowsTests {

    typealias Fixture = PaneSearchTreeRevealTests

    /// A pane in a window, a row selected, its list holding the window's keyboard.
    private func focusedPane(_ mode: PaneViewMode) async -> (Fixture.Box, NSWindow, NSTableView)? {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: mode, tree: Fixture.tallTree())
        let ready = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.tables(window.contentView!).first.map(PaneListKeyFocus.isRegistered) == true
        }
        guard ready.held, let table = Fixture.tables(window.contentView!).first else {
            Issue.record("\(mode): no registered table after \(ready.pumps) pumps")
            return nil
        }
        table.selectRowIndexes(IndexSet([4]), byExtendingSelection: false)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { box.selection.count == 1 }
        guard window.makeFirstResponder(table), box.selection.count == 1 else {
            Issue.record("\(mode): could not select row 4 and focus its list")
            return nil
        }
        return (box, window, table)
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let chars = code == 125 ? "\u{F701}" : code == 126 ? "\u{F700}" : " "
        return NSEvent.keyEvent(with: .keyDown, location: .zero,
                                modifierFlags: flags.union([.function, .numericPad]),
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: 0, context: nil,
                                characters: chars, charactersIgnoringModifiers: chars,
                                isARepeat: false, keyCode: code)!
    }

    private var panel: QLPreviewPanel { QLPreviewPanel.shared() }

    @Test("↓ with a pane-following preview open moves the pane's selection; with another preview it doesn't",
          arguments: [PaneViewMode.tree, .columns])
    func downMovesTheSelection(_ mode: PaneViewMode) async {
        guard let (box, window, _) = await focusedPane(mode) else { return }
        defer { PaneQuickLookArrows.followsPane = false }
        let before = box.selection

        // Control: a preview that does not follow the pane keeps the key.
        PaneQuickLookArrows.followsPane = false
        #expect(!PaneQuickLookArrows.forward(key(125), keyWindow: panel, mainWindow: window),
                "\(mode): a preview that doesn't follow the pane gave up ↓")
        _ = await LayoutPumpWait.pump(window, upTo: 3) { box.selection != before }
        #expect(box.selection == before, "\(mode): the selection moved with nothing forwarded — the control cannot fail")

        PaneQuickLookArrows.followsPane = true
        #expect(PaneQuickLookArrows.forward(key(125), keyWindow: panel, mainWindow: window),
                "\(mode): ↓ was not handed to the pane")
        let moved = await LayoutPumpWait.pump(window, upTo: 5) {
            box.selection.count == 1 && box.selection != before
        }
        #expect(moved.held, "\(mode): ↓ did not move the selection (still \(box.selection))")

        let after = box.selection
        #expect(PaneQuickLookArrows.forward(key(126), keyWindow: panel, mainWindow: window))
        let back = await LayoutPumpWait.pump(window, upTo: 5) { box.selection == before }
        #expect(back.held, "\(mode): ↑ did not move back from \(after) to \(before)")
    }

    @Test("The panel keeps ⇧-arrows, other keys, and keys when it isn't the key window")
    func refusals() async {
        guard let (_, window, table) = await focusedPane(.tree) else { return }
        PaneQuickLookArrows.followsPane = true
        defer { PaneQuickLookArrows.followsPane = false }

        // The positive case first, so every refusal below differs from it in one thing only.
        #expect(PaneQuickLookArrows.target(for: key(125), keyWindow: panel, mainWindow: window) === table)

        #expect(PaneQuickLookArrows.target(for: key(125, .shift), keyWindow: panel, mainWindow: window) == nil,
                "⇧↓ would extend a selection the preview cannot show")
        #expect(PaneQuickLookArrows.target(for: key(125, .command), keyWindow: panel, mainWindow: window) == nil)
        #expect(PaneQuickLookArrows.target(for: key(49), keyWindow: panel, mainWindow: window) == nil,
                "Space is the panel's: it closes the preview")
        #expect(PaneQuickLookArrows.target(for: key(125), keyWindow: window, mainWindow: window) == nil,
                "with the pane's own window key, its list gets ↓ the normal way")
        #expect(PaneQuickLookArrows.target(for: key(125), keyWindow: panel, mainWindow: nil) == nil)
    }

    @Test("A list nobody registered as a pane list is not a target")
    func unregisteredListIsNotATarget() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let table = NSTableView()
        window.contentView = table
        PaneQuickLookArrows.followsPane = true
        defer { PaneQuickLookArrows.followsPane = false }
        #expect(window.makeFirstResponder(table))
        #expect(!PaneListKeyFocus.isRegistered(table))
        #expect(PaneQuickLookArrows.target(for: key(125), keyWindow: panel, mainWindow: window) == nil)
    }
}
