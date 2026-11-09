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

/// The dock holds one hosting view for the panel, and puts it in whichever column view is on screen,
/// and nothing inside is rebuilt on the way.
@MainActor
@Suite(.serialized) struct AskClaudeColumnTests {

    private func offscreenWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1000, height: 760),
                 styleMask: [.borderless], backing: .buffered, defer: true)
    }

    private func settle() async { for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(10)) } }

    /// How many hosting views the column holds.
    private func hosts(in column: NSView) -> Int { column.subviews.filter { $0 is NSHostingView<AnyView> }.count }

    /// The column is one slot, but SwiftUI builds it a new column view whenever it comes back: from
    /// being tucked away over a narrow window, or when the surface style changes its frame. The dock
    /// moves its one hosting view into whichever column view it is handed. Each move SwiftUI reports
    /// as a disappearance and an appearance, which the panel treats as a move, so what lives in it
    /// (the draft, a running voice) is built once. Mutation: the dock building a host per column view
    /// must fail the state count.
    @Test func theHostMovesBetweenColumnViewsWithoutRebuilding() async throws {
        let window = offscreenWindow()
        let first = AskClaudeColumnView(frame: NSRect(x: 628, y: 0, width: 372, height: 760))
        let second = AskClaudeColumnView(frame: NSRect(x: 628, y: 0, width: 372, height: 760))
        window.contentView?.addSubview(first)
        window.contentView?.addSubview(second)
        let probe = ColumnProbe()
        let dock = AskClaudeDock()
        first.controller = dock
        second.controller = dock
        let content = AnyView(ColumnProbeView(probe: probe))

        dock.columnView = first
        dock.show(content)
        await settle()
        #expect(hosts(in: first) == 1)

        for cycle in 1...20 {
            dock.columnView = second
            await settle()
            #expect(hosts(in: second) == 1 && hosts(in: first) == 0, "cycle \(cycle): the host is in the new column view")
            dock.columnView = first
            await settle()
            #expect(hosts(in: first) == 1 && hosts(in: second) == 0, "cycle \(cycle): the host is back in the first")
        }
        #expect(probe.states.count == 1, "the view's state was rebuilt \(probe.states.count) times")
        #expect(probe.appeared == probe.disappeared + 1, "appeared \(probe.appeared), disappeared \(probe.disappeared)")
        dock.hide()
        #expect(hosts(in: first) == 0 && hosts(in: second) == 0)
    }

    /// Busy: the column stays where it is, dimmed and deaf, and comes back as it was.
    @Test func aBusyWindowPausesTheColumnInsteadOfRemovingIt() async throws {
        let window = offscreenWindow()
        let column = AskClaudeColumnView(frame: NSRect(x: 628, y: 0, width: 372, height: 760))
        window.contentView?.addSubview(column)
        let probe = ColumnProbe()
        let dock = AskClaudeDock()
        column.controller = dock
        dock.columnView = column
        dock.show(AnyView(ColumnProbeView(probe: probe)))
        await settle()
        #expect(hosts(in: column) == 1)
        dock.isSuspended = true
        #expect(column.isPaused && column.alphaValue == 0.5)
        #expect(column.hitTest(NSPoint(x: 10, y: 10)) == nil)
        #expect(hosts(in: column) == 1, "a busy window leaves the column in place")
        dock.isSuspended = false
        #expect(!column.isPaused && column.alphaValue == 1)
        #expect(probe.states.count == 1 && probe.appeared == probe.disappeared + 1)
        dock.hide()
    }

    /// Over the workspace a click outside the column tucks it away, and the click still goes where it
    /// was aimed. Inside it, or when docked, nothing is tucked.
    @Test func aClickOutsideAnOverlaidColumnTucksItAway() async throws {
        // Created, not deferred, so events can name it.
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1000, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let column = AskClaudeColumnView(frame: NSRect(x: 628, y: 0, width: 372, height: 760))
        window.contentView?.addSubview(column)
        var tucks = 0
        column.onTuck = { tucks += 1 }
        func click(at point: NSPoint) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
            // The column's monitor calls this for every click in its window; called directly here.
            column.tuckIfOutside(event)
        }
        column.tucksOnOutsideClick = false
        click(at: NSPoint(x: 100, y: 100))
        #expect(tucks == 0, "a docked column tucked")
        column.tucksOnOutsideClick = true
        click(at: NSPoint(x: 800, y: 100))
        #expect(tucks == 0, "a click inside the column tucked it")
        click(at: NSPoint(x: 100, y: 100))
        #expect(tucks == 1, "a click in the workspace did not tuck the overlaid column")
        // The resize handle reaches past the column's leading edge: a press there drags the column.
        click(at: NSPoint(x: 628 - 5, y: 100))
        #expect(tucks == 1, "a press on the column's resize handle tucked it")
        click(at: NSPoint(x: 628 - AskClaudeColumnView.resizeHandleThickness - 2, y: 100))
        #expect(tucks == 2, "a click just past the handle did not tuck the column")
    }

    /// ◨ is in the toolbar, and a press on it must reach the toggle with the column still open, or
    /// it untucks a column it means to close. So a press in the titlebar or toolbar, or at the
    /// window's edge where a resize starts, is not a click in the workspace and tucks nothing.
    @Test func aPressInTheTitlebarOrAtTheWindowsEdgeDoesNotTuck() throws {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1000, height: 760),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        let layout = window.contentLayoutRect
        // The harness: a titlebar the content runs under, or there is nothing above the workspace.
        try #require(layout.maxY < content.bounds.maxY - 10, "no titlebar over the content: \(layout) in \(content.bounds)")
        let column = AskClaudeColumnView(frame: NSRect(x: 628, y: 0, width: 372, height: content.bounds.height))
        content.addSubview(column)
        column.tucksOnOutsideClick = true
        var tucks = 0
        column.onTuck = { tucks += 1 }
        func click(at point: NSPoint) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)!
            column.tuckIfOutside(event)
        }
        click(at: NSPoint(x: 900, y: layout.maxY + 4))
        #expect(tucks == 0, "a press in the toolbar, over the column, tucked it")
        click(at: NSPoint(x: 100, y: layout.maxY + 4))
        #expect(tucks == 0, "a press in the titlebar tucked the column")
        click(at: NSPoint(x: 2, y: 300))
        #expect(tucks == 0, "a press on the window's left edge tucked the column")
        click(at: NSPoint(x: 300, y: 2))
        #expect(tucks == 0, "a press on the window's bottom edge tucked the column")
        // The control: a press in the workspace itself still tucks it.
        click(at: NSPoint(x: 300, y: 300))
        #expect(tucks == 1, "a click in the workspace did not tuck the column")
    }

    /// Only this window's edge holds the room rule still: another window's live resize (Settings,
    /// Activity, a second main window) is not this one's. A resize under way when the anchor leaves
    /// its window is let go, so the rule is never left frozen.
    @Test func onlyThisWindowsLiveResizeHoldsTheRoomRule() {
        let window = offscreenWindow()
        let other = offscreenWindow()
        let anchor = AskClaudeDockAnchor.AnchorView(frame: .zero)
        var seen: [Bool] = []
        anchor.onLiveResize = { seen.append($0) }
        window.contentView?.addSubview(anchor)
        let center = NotificationCenter.default
        center.post(name: NSWindow.willStartLiveResizeNotification, object: other)
        center.post(name: NSWindow.didEndLiveResizeNotification, object: other)
        #expect(seen.isEmpty, "another window's resize reached this one: \(seen)")
        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        #expect(seen == [true])
        center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        #expect(seen == [true, false])
        center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        anchor.removeFromSuperview()
        #expect(seen == [true, false, true, false], "a resize left under way when the anchor went")
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

    /// The lazy stack's boundary moves 12 rows at a time, so a row crosses into it (and loses its
    /// state) once every 12 new items, and the plain stack keeps 12 to 23 rows.
    @Test func theLazyBoundaryMovesInWholeSteps() {
        let recent = AskClaudePanel.recentRows
        #expect(recent == 12)
        let counts = [0, 1, 11, 12, 13, 23, 24, 25, 35, 36, 47, 48, 200]
        #expect(counts.map { AskClaudePanel.lazyRowCount($0) } == [0, 0, 0, 0, 0, 0, 12, 12, 12, 24, 24, 36, 180])
        var crossings = 0
        for count in 1...240 {
            let lazy = AskClaudePanel.lazyRowCount(count)
            if lazy != AskClaudePanel.lazyRowCount(count - 1) { crossings += 1 }
            #expect(lazy % recent == 0)
            if count >= recent { #expect((recent...(2 * recent - 1)).contains(count - lazy), "\(count)") }
        }
        // 24, 36, … 240: 19 moves over 240 items, not one per item.
        #expect(crossings == 19)
    }
}

/// The column's keys: typing, undo, ⌘W, Esc and ⌥Space, answered wherever in it the keyboard is.
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
