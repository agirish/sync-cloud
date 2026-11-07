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

    /// How many hosting views the column holds (it also holds its keyboard tint).
    private func hosts(in column: NSView) -> Int { column.subviews.filter { $0 is NSHostingView<AnyView> }.count }

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
            #expect(hosts(in: column) == 1, "cycle \(cycle): the host is in the column")
            #expect(parent.childWindows?.isEmpty == true, "cycle \(cycle): the window gave way")

            controller.isPinned = false
            controller.show(content, over: parent, activate: false)
            await settle()
            #expect(hosts(in: column) == 0, "cycle \(cycle): the host left the column")
            #expect(parent.childWindows?.count == 1, "cycle \(cycle): the window is back")
        }
        // One life for what is inside: it kept one state through every move. SwiftUI reports each
        // move as a disappearance and an appearance, so the panel treats those as a move (its
        // `leavingForAnotherWindow`); here the two stay in step, and it ends on screen.
        #expect(probe.states.count == 1, "the view's state was rebuilt \(probe.states.count) times")
        #expect(probe.appeared == probe.disappeared + 1, "appeared \(probe.appeared), disappeared \(probe.disappeared)")
        controller.hide()
        #expect(parent.childWindows?.isEmpty == true)
        #expect(hosts(in: column) == 0)
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
        #expect(hosts(in: column) == 1)
        controller.isSuspended = true
        #expect(column.isPaused && column.alphaValue == 0.5)
        #expect(column.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(hosts(in: column) == 1, "pinned, a busy window leaves the column in place")
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

/// The keys of a pinned panel, which the floating panel's own window used to answer.
@MainActor
@Suite(.serialized) struct AskClaudeColumnKeysTests {

    /// A window the column sits in, with a field inside it, off screen. Created, not deferred, so
    /// events can name it.
    private func windowWithColumn() -> (NSWindow, AskClaudeColumnView, NSTextView, NSView) {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let outside = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let column = AskClaudeColumnView(frame: NSRect(x: 220, y: 0, width: 372, height: 400))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        text.string = "a draft"
        // As a field editor's: typing registers undo, in the stack its enclosing views name.
        text.allowsUndo = true
        column.addSubview(text)
        window.contentView?.addSubview(outside)
        window.contentView?.addSubview(column)
        return (window, column, text, outside)
    }

    private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func theColumnIsFoundFromAnyViewInsideItAndFromNothingOutside() {
        let (window, column, text, outside) = windowWithColumn()
        #expect(AskClaudeColumnView.enclosing(text) === column)
        #expect(AskClaudeColumnView.enclosing(column) === column)
        #expect(AskClaudeColumnView.enclosing(outside) == nil)
        #expect(AskClaudeColumnView.holder(in: window) == nil)
        window.makeFirstResponder(text)
        #expect(AskClaudeColumnView.holder(in: window) === column)
        #expect(column.holdsKeyboard)
        window.makeFirstResponder(outside)
        #expect(!column.holdsKeyboard)
    }

    /// With the keyboard in the column, no chord reaches the file list: not even one the column
    /// has no answer for. A chord it has an answer for gets it.
    @Test func aChordInTheColumnNeverRunsTheFileAction() {
        let (_, column, _, outside) = windowWithColumn()
        let answers = NSView(frame: .zero)
        column.addSubview(answers)
        var file = 0, refused = 0, answered = 0
        TextEditingChord.route(responder: answers, editorAction: { _ in }, readerRefusal: { refused += 1 }, fileAction: { file += 1 })
        #expect(file == 0 && refused == 1, "cut, paste, delete and the transfers are refused there")
        TextEditingChord.route(responder: answers, editorAction: { _ in }, columnAction: { _ in answered += 1 }, fileAction: { file += 1 })
        #expect(file == 0 && answered == 1)
        TextEditingChord.route(responder: outside, editorAction: { _ in }, readerRefusal: { refused += 1 }, fileAction: { file += 1 })
        #expect(file == 1 && refused == 1, "outside the column the file list keeps its chords")
    }

    /// ⌘W with the keyboard in the column closes the panel, ahead of every other meaning.
    @Test func closeInTheColumnClosesThePanelAndNothingElse() {
        var tab = 0, window = 0, column = 0
        CloseTabCommand.run(.closeTab { tab += 1 }, closeColumn: { column += 1 }, closeWindow: { window += 1 })
        #expect(column == 1 && tab == 0 && window == 0)
        CloseTabCommand.run(.closeTab { tab += 1 }, closeWindow: { window += 1 })
        #expect(tab == 1 && column == 1, "without the column, the tab closes as before")
        CloseTabCommand.run(nil, closeWindow: { window += 1 })
        #expect(window == 1)
    }

    /// Esc stops a spoken question, else an edit, else nothing; ⌥Space is the panel's; neither is
    /// the file list's. Out of the column, the keys are left alone.
    @Test func escAndTheTalkKeyAreTheColumnsOnlyWhileItHoldsTheKeyboard() {
        let (window, column, text, outside) = windowWithColumn()
        var talk = 0, escapes = 0
        var voiceActive = false
        column.onTalkKey = { key in
            talk += 1
            if case .cancel = key { return voiceActive }
            return true
        }
        column.onEscape = { escapes += 1; return false }
        let esc = key(53, characters: "\u{1b}", in: window)
        let optionSpace = key(49, characters: " ", modifiers: .option, in: window)

        window.makeFirstResponder(outside)
        #expect(column.handle(keyDown: esc) === esc, "not the column's key when the keyboard is elsewhere")
        #expect(talk == 0)

        window.makeFirstResponder(text)
        #expect(column.handle(keyDown: optionSpace) == nil, "⌥Space starts or sends a question")
        voiceActive = true
        #expect(column.handle(keyDown: esc) == nil, "Esc stops talking")
        #expect(escapes == 0)
        voiceActive = false
        #expect(column.handle(keyDown: esc) == nil, "Esc with nothing to stop is still not the file list's")
        #expect(escapes == 1)

        column.isPaused = true
        #expect(column.handle(keyDown: esc) === esc, "a paused column takes no keys")
    }

    /// The column's typing steps are its own: the window's stack, which holds file moves, is not
    /// the one ⌘Z reaches from a field in it.
    @Test func typingInTheColumnHasItsOwnUndoStack() {
        let (window, column, text, _) = windowWithColumn()
        window.makeFirstResponder(text)
        #expect(text.undoManager === column.undoManager)
        #expect(column.undoManager !== window.undoManager)
        let undo = NSMenuItem(title: "Undo", action: #selector(AskClaudeColumnView.undo(_:)), keyEquivalent: "z")
        #expect(!column.validateUserInterfaceItem(undo), "nothing typed, nothing to undo")
        column.registerTypingStepForTesting("Typing")
        #expect(column.validateUserInterfaceItem(undo))
        #expect(undo.title == "Undo Typing")
    }

    @Test func typingGoesFirstWhenItIsAsNewAsTheLatestSettingsChange() {
        let now = Date()
        #expect(AskClaudeColumnView.typingIsNewer(typingChangedAt: now, settingsLatest: nil))
        #expect(AskClaudeColumnView.typingIsNewer(typingChangedAt: now, settingsLatest: now.addingTimeInterval(-5)))
        #expect(!AskClaudeColumnView.typingIsNewer(typingChangedAt: now.addingTimeInterval(-5), settingsLatest: now))
    }

    /// A pause takes the keyboard out of the column and stops a spoken question.
    @Test func pausingTheColumnTakesTheKeyboardAndStopsTalking() {
        let (window, column, text, _) = windowWithColumn()
        var gone = 0
        column.onGone = { gone += 1 }
        window.makeFirstResponder(text)
        column.isPaused = true
        #expect(gone == 1)
        #expect(!column.holdsKeyboard)
    }
}
