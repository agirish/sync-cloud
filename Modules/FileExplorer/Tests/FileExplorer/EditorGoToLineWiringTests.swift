import Testing
import SwiftUI
import AppKit
import Design
@testable import FileExplorer
import FileExplorerTestSupport

/// Go to Line, from the press to the caret. The field on its own (focus, Return, Escape), then a
/// mounted workspace: Text ▸ Go to Line…'s request opens the field, and Return closes it and puts
/// Source's caret on the line. `EditorGoToLineTests` tests the rules; this connects them, so a
/// revert at any call site turns it red.
@MainActor
@Suite(.serialized) struct EditorGoToLineWiringTests: EditorPopoverRig {

    // MARK: The rig (`EditorPopoverRig`)

    private func dismiss(_ window: NSWindow) {
        for popover in popovers() { popover.orderOut(nil) }
        window.orderOut(nil)
        spin(window, 3)
    }

    // MARK: The field alone

    final class Heard {
        var went: [EditorGoToLine.Target] = []
        var cancels = 0
    }

    private func mountField(_ heard: Heard) -> NSWindow {
        let host = NSHostingView(rootView: EditorGoToLineField(lineCount: 12,
                                                               onGo: { heard.went.append($0) },
                                                               onCancel: { heard.cancels += 1 }))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        return window(for: host)
    }

    /// It takes focus as it appears, Return goes with what was typed, and junk goes nowhere.
    @Test func theFieldTakesFocusAndReturnGoes() throws {
        let heard = Heard()
        let window = mountField(heard)
        defer { dismiss(window) }
        let editor = try #require(window.firstResponder as? NSTextView,
                                  "the field did not take focus — first responder \(String(describing: window.firstResponder))")
        editor.insertText("0", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin(window, 3)
        #expect(heard.went.isEmpty, "junk went to \(heard.went)")
        editor.selectAll(nil)
        editor.insertText("3:2", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin(window, 3)
        #expect(heard.went == [EditorGoToLine.Target(line: 3, column: 2)], "Return sent \(heard.went)")
        #expect(heard.cancels == 0)
    }

    /// Escape closes it, and goes nowhere.
    @Test func escapeCloses() throws {
        let heard = Heard()
        let window = mountField(heard)
        defer { dismiss(window) }
        let editor = try #require(window.firstResponder as? NSTextView, "the field did not take focus")
        editor.insertText("3", replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        spin(window, 3)
        #expect(heard.cancels == 1, "Escape cancelled \(heard.cancels) times")
        #expect(heard.went.isEmpty)
    }

    // MARK: A mounted workspace

    /// Five lines, the caret starting on the first — so line 3 and the last line are both somewhere
    /// the caret is not.
    static let text = "first\nsecond\nthird line\nfourth\nfifth and last\n"

    private struct Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let defaults: UserDefaults
        let document: EditorDocument
        let editor: NSTextView
        var caret: EditorCaret { EditorCaret.at(utf16Offset: editor.selectedRange().location, in: editor.string) }
    }

    private func mountWorkspace() throws -> Mounted {
        let document = try TestTextFiles.document(named: "lines.txt", text: Self.text)
        let defaults = ScratchDefaults("EditorGoToLineWiringTests")
        let host = NSHostingView(rootView: AnyView(EditorWorkspaceView.fixture(document: document, mode: .edit)
            .editorTestDefaults(defaults)))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = window(for: host)
        spin(window, 20)
        let editor = try #require(EditorTestRigs.textView(in: host), "no text view mounted — this test sees nothing")
        return Mounted(host: host, window: window, defaults: defaults, document: document, editor: editor)
    }

    /// Text ▸ Go to Line…'s press, as the app makes it: the request counter goes up by one.
    private func pressGoToLine(_ mounted: Mounted, request: Int) {
        mounted.host.rootView = AnyView(EditorWorkspaceView.fixture(document: mounted.document, mode: .edit,
                                                                    goToLineRequest: request)
            .editorTestDefaults(mounted.defaults))
        spin(mounted.window)
    }

    /// Types into the open field and presses Return.
    private func go(_ typed: String, in mounted: Mounted) throws {
        let popover = try #require(popovers().first, "no field is up to type in")
        let field = try #require(popover.firstResponder as? NSTextView, "the field did not take focus")
        field.insertText(typed, replacementRange: field.selectedRange())
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin(mounted.window)
    }

    /// The menu's press opens the field, once per press; Return closes it and puts the caret on
    /// the line and column typed.
    @Test func goingClosesTheFieldAndMovesTheCaret() throws {
        let mounted = try mountWorkspace()
        defer { dismiss(mounted.window) }
        try #require(mounted.caret == EditorCaret(line: 1, column: 1), "the caret started at \(mounted.caret)")
        #expect(popovers().isEmpty, "a field was up before anything asked for one")
        pressGoToLine(mounted, request: 1)
        #expect(popovers().count == 1, "the press opened \(popovers().count) fields")
        try go("3:2", in: mounted)
        #expect(mounted.caret == EditorCaret(line: 3, column: 2), "the caret went to \(mounted.caret)")
        #expect(popovers().isEmpty, "the field stayed up after going")
    }

    /// A line past the end with no column lands on the last line. A request without a column is a
    /// heading's, which finds no line 400 and goes nowhere, so going must always carry one.
    @Test func aLinePastTheEndLandsOnTheLastLine() throws {
        let mounted = try mountWorkspace()
        defer { dismiss(mounted.window) }
        try #require(mounted.caret == EditorCaret(line: 1, column: 1), "the caret started at \(mounted.caret)")
        pressGoToLine(mounted, request: 1)
        try go("400", in: mounted)
        #expect(mounted.caret == EditorCaret(line: 5, column: 1), "the caret went to \(mounted.caret)")
    }
}
