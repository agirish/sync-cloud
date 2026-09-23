import Testing
import AppKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// Pins `PaneListKeyFocus`: a click in a pane list hands that list the keyboard.
///
/// **Every mounted test starts by taking focus AWAY.** A test window is not a real one: AppKit makes
/// the first key view in it the first responder on its own, so a freshly mounted pane already has
/// its table focused — the one state the app never reaches, and the reason every headless probe of
/// the ⇧↑ report passed while the app ignored the key. `unfocused(_:)` puts the window where the
/// app's is after a click, and asserts it got there, so no assertion below can pass on the harness's
/// gift.
///
/// `.serialized` because first responder is per-window state these tests move deliberately, and
/// because key events sent through a shared `NSApp` by parallel tests land in each other's windows —
/// which once produced a false reproduction of this very bug.
@MainActor
@Suite(.serialized) struct PaneListKeyFocusTests {

    typealias Fixture = PaneSearchTreeRevealTests

    // MARK: - Harness

    /// A pane mounted in a window, with its first list resolved and registered.
    private func mountedPane(_ mode: PaneViewMode) async -> (Fixture.Box, NSWindow, NSTableView)? {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: mode, tree: Fixture.tallTree())
        let ready = await LayoutPumpWait.pump(window, upTo: 5) {
            Fixture.tables(window.contentView!).first.map(PaneListKeyFocus.isRegistered) == true
        }
        guard ready.held, let table = Fixture.tables(window.contentView!).first else {
            Issue.record("\(mode): no registered table after \(ready.pumps) pumps")
            return nil
        }
        return (box, window, table)
    }

    /// Puts focus on the window itself — the app's state after a click — and proves it.
    private func unfocused(_ window: NSWindow) -> Bool {
        window.makeFirstResponder(nil)
        return window.firstResponder === window
    }

    private func key(_ code: UInt16, shift: Bool, in window: NSWindow) -> NSEvent {
        let chars = code == 125 ? "\u{F701}" : "\u{F700}"
        var flags: NSEvent.ModifierFlags = [.function, .numericPad]
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window.windowNumber, context: nil,
                                characters: chars, charactersIgnoringModifiers: chars,
                                isARepeat: false, keyCode: code)!
    }

    /// A left mouse-up at the centre of `row`, in window coordinates — what the monitor receives.
    private func mouseUp(onRow row: Int, of table: NSTableView, in window: NSWindow) -> NSEvent {
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    // MARK: - The outcome

    /// **The report, end to end, with its own control.** ⇧↓ sent to the window does nothing while
    /// the window holds focus — the app as it was — and extends the selection once a click on a
    /// row has gone through the monitor's path.
    @Test("A click on a row gives the list the keyboard, and ⇧↓ then extends the selection",
          arguments: [PaneViewMode.tree, .columns])
    func clickThenShiftArrowExtends(_ mode: PaneViewMode) async {
        guard let (box, window, table) = await mountedPane(mode) else { return }
        table.selectRowIndexes(IndexSet([4]), byExtendingSelection: false)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { box.selection.count == 1 }
        #expect(unfocused(window), "\(mode): could not put focus on the window")

        // Control: the app before the fix. The key reaches the window and is dropped.
        window.sendEvent(key(125, shift: true, in: window))
        _ = await LayoutPumpWait.pump(window, upTo: 3) { box.selection.count > 1 }
        #expect(box.selection.count == 1,
                "\(mode): ⇧↓ extended with the WINDOW focused — the control cannot fail, so nothing below proves anything")

        // The click, through the monitor's own entry point, with the deferral run in line.
        PaneListKeyFocus.noteMouseUp(mouseUp(onRow: 4, of: table, in: window), schedule: { $0() })
        #expect(window.firstResponder === table, "\(mode): the click did not give the list focus")

        window.sendEvent(key(125, shift: true, in: window))
        let extended = await LayoutPumpWait.pump(window, upTo: 5) { box.selection.count == 2 }
        #expect(extended.held,
                "\(mode): ⇧↓ after the click should select two rows (\(extended.pumps) pumps, got \(box.selection.count))")
    }

    // MARK: - Where the claim stops

    /// A caret in a field inside the list keeps the keys. The field sits in a REGISTERED table, so
    /// the field check is the only thing that can refuse — without that ordering, an unregistered
    /// table would return nil for its own reason and this would pass with the check deleted.
    @Test("A click into an editable field inside the list does not take its keys")
    func editableFieldKeepsTheClick() async {
        guard let (_, _, table) = await mountedPane(.tree) else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        field.isEditable = true
        table.addSubview(field)
        defer { field.removeFromSuperview() }

        #expect(PaneListKeyFocus.target(forHit: table) === table, "control: the table itself is a target")
        #expect(PaneListKeyFocus.target(forHit: field) == nil)

        field.isEditable = false
        #expect(PaneListKeyFocus.target(forHit: field) === table,
                "a label that cannot be edited is just row content, and the click is the list's")
    }

    /// The same protection after the fact: a field editor already inside the table is a descendant,
    /// and the claim leaves it alone.
    @Test("The claim leaves a caret already inside the list where it is")
    func claimLeavesADescendantResponder() async {
        guard let (_, window, table) = await mountedPane(.tree) else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        field.isEditable = true
        table.addSubview(field)
        defer { field.removeFromSuperview() }

        #expect(unfocused(window))
        #expect(window.makeFirstResponder(field), "the fixture needs a caret in the field")
        let editor = window.firstResponder
        #expect((editor as? NSView)?.isDescendant(of: table) == true, "the caret should sit inside the table")

        #expect(PaneListKeyFocus.claim(table, in: window) == false)
        #expect(window.firstResponder === editor)
    }

    @Test("A table nobody registered is not a target")
    func unregisteredTableIsIgnored() {
        let stray = NSTableView(frame: .zero)
        #expect(!PaneListKeyFocus.isRegistered(stray))
        #expect(PaneListKeyFocus.target(forHit: stray) == nil)
        #expect(PaneListKeyFocus.target(forHit: nil) == nil)
    }

    @Test("Claiming a list already focused changes nothing")
    func claimIsIdempotent() async {
        guard let (_, window, table) = await mountedPane(.tree) else { return }
        #expect(unfocused(window))
        #expect(PaneListKeyFocus.claim(table, in: window))
        #expect(PaneListKeyFocus.claim(table, in: window) == false)
        #expect(window.firstResponder === table)
    }

    // MARK: - The call site

    /// **Every list a Columns pane opens is registered, not only the first.** The resolver once
    /// reached only column 0 (`PaneListResolver`'s doc has the measurement); a claim that worked in
    /// the root column and nowhere a user had drilled to would look fixed in exactly the place anyone
    /// tries it first.
    @Test("Every column of a Columns pane registers its list")
    func everyColumnRegisters() async {
        let box = Fixture.Box()
        let window = Fixture.mount(box, viewMode: .columns)
        _ = await LayoutPumpWait.pump(window, upTo: 5) { !Fixture.tables(window.contentView!).isEmpty }
        // Drill two deep so three columns are open: root → Documents → Finance.
        box.browsePath = PaneBrowsePath(components: ["Documents", "Finance"])
        let settled = await LayoutPumpWait.pump(window, upTo: 10) {
            let tables = Fixture.tables(window.contentView!)
            return tables.count == 3 && tables.allSatisfy(PaneListKeyFocus.isRegistered)
        }
        let tables = Fixture.tables(window.contentView!)
        #expect(settled.held,
                "want 3 columns, all registered; got \(tables.count), registered \(tables.map(PaneListKeyFocus.isRegistered)) after \(settled.pumps) pumps")
    }
}
