import Testing
import AppKit
@testable import SyncCloud

/// ⌘K borrows the caret; closing has to give it back. The Go-to field lives in the host window's
/// toolbar, so opening it takes first responder from whatever the user was using. Unrestored, the
/// window itself is left first responder and the file pane ignores arrow keys and type-select
/// until clicked. The restore lives on the host, which sees the palette close while the caret is
/// still in the field; by the field's own teardown AppKit has already dropped the field editor.
@Suite @MainActor struct GoToCaretHandoffTests {

    private func window() -> NSWindow {
        // Parked far off every display: this suite makes real windows, and none may appear over
        // whatever the user is doing.
        let w = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 400, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    /// A view that can hold the caret as its own first responder, standing in for the pane's table.
    /// Editable `NSTextField`s won't do: a window has one field editor shared by all its text fields,
    /// so `window.firstResponder` is the same `NSTextView` whichever field is edited, and an identity
    /// check on it would pass before and after any restore.
    private final class FocusTarget: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func focusable(_ host: NSWindow) -> FocusTarget {
        let view = FocusTarget(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        host.contentView?.addSubview(view)
        return view
    }

    @Test func theCaretGoesBackToWhoeverHadItBeforeTheFieldOpened() throws {
        let host = window()
        let pane = focusable(host)
        #expect(host.makeFirstResponder(pane))
        let previous = try #require(host.firstResponder)
        #expect(previous === pane, "the fixture never focused the stand-in pane")

        // The field takes it, as ⌘K does.
        let goTo = focusable(host)
        #expect(host.makeFirstResponder(goTo))
        #expect(host.firstResponder === goTo, "the fixture never moved the caret off the pane")

        ContentView.restoreCaret(to: previous, in: host, caretIsInField: true)
        #expect(host.firstResponder === previous,
                "the caret was not handed back — the pane will not answer arrow keys until it is clicked")
    }

    /// The refusal matters as much as the restore. Every close path runs this, including the one
    /// where the user clicked into a pane to close the palette, which already says where focus goes.
    @Test func aCaretTheUserHasAlreadyMovedIsLeftWhereTheyPutIt() throws {
        let host = window()
        let previous = focusable(host)
        let chosen = focusable(host)
        #expect(host.makeFirstResponder(chosen))
        let before = try #require(host.firstResponder)
        #expect(before === chosen, "the fixture never focused what the user chose")
        #expect(previous !== chosen, "the two stand-ins are the same view — this could not fail")

        ContentView.restoreCaret(to: previous, in: host, caretIsInField: false)
        #expect(host.firstResponder === before,
                "closing the palette yanked the caret off what the user had just clicked")
    }

    /// A remembered responder whose view has gone would move the caret somewhere invisible, which
    /// is worse than the window keeping it.
    @Test func aRememberedViewThatHasLeftTheWindowIsNotRestoredTo() throws {
        let host = window()
        let goTo = focusable(host)
        #expect(host.makeFirstResponder(goTo))
        let holding = try #require(host.firstResponder)
        #expect(holding === goTo, "the fixture never focused the stand-in field")

        // Torn down while the field was open: a pane the user closed.
        let gone = focusable(host)
        gone.removeFromSuperview()
        #expect(gone.window == nil, "the stand-in never left the window — the guard under test is not exercised")

        ContentView.restoreCaret(to: gone, in: host, caretIsInField: true)
        #expect(host.firstResponder === holding,
                "the caret was handed to a view that is no longer in the window")
    }

    /// Nothing to restore to is not a reason to disturb anything.
    @Test func nothingRememberedMeansNothingMoves() throws {
        let host = window()
        let goTo = focusable(host)
        #expect(host.makeFirstResponder(goTo))
        let holding = try #require(host.firstResponder)
        #expect(holding === goTo, "the fixture never focused the stand-in field")

        ContentView.restoreCaret(to: nil, in: host, caretIsInField: true)
        #expect(host.firstResponder === holding)
    }

    // MARK: Who was holding it

    /// A window has one field editor, so remembering the first responder remembers nothing. While
    /// the user types in a pane's Find field the first responder is the shared `NSTextView`, which
    /// ⌘K then re-binds to the Go-to field; restoring it would hand the caret to the object that
    /// already has it, and the pane's field would never get it back. So the field being edited is
    /// what is remembered.
    @Test func whatIsRememberedIsTheFieldBeingEditedAndNotTheSharedEditor() throws {
        let host = window()
        let paneField = NSTextField(string: "invoice")
        let goTo = NSTextField(string: "")
        for field in [paneField, goTo] {
            field.isEditable = true
            host.contentView?.addSubview(field)
        }
        #expect(host.makeFirstResponder(paneField))

        let remembered = try #require(ContentView.caretHolder(in: host))
        #expect(remembered === paneField,
                "⌘K remembered the window's field editor rather than the field being typed into")

        // ⌘K takes it, which re-binds the one editor to the Go-to field.
        #expect(host.makeFirstResponder(goTo))
        #expect(host.firstResponder !== paneField, "the fixture never moved the caret off the pane's field")

        ContentView.restoreCaret(to: remembered, in: host, caretIsInField: true)
        let editor = try #require(host.firstResponder as? NSTextView, "nothing is being edited after the restore")
        #expect(editor.delegate === paneField,
                "the caret went back to the shared editor rather than to the pane's field — the user's search field stays dead")
    }

    /// A responder that is not a field editor is already the thing to restore, and is returned
    /// untouched: the common case, a file pane's table.
    @Test func aPlainResponderIsRememberedAsItself() throws {
        let host = window()
        let pane = focusable(host)
        #expect(host.makeFirstResponder(pane))
        #expect(ContentView.caretHolder(in: host) === pane,
                "a pane holding the caret was resolved to something else")
    }

    /// The two-argument form is what the close path calls, and it must route through the rule above
    /// rather than carry a second copy (`CommandPaletteHost.swift`).
    @Test func theClosePathCallsTheRuleRatherThanRepeatingIt() throws {
        let text = try macAppFile("CommandPaletteHost.swift")
        #expect(text.contains("Self.restoreCaret(to: caretWasWith, in: host)"),
                "the palette's close path no longer hands the caret back — closing ⌘K will leave the window focusing nothing")
        #expect(text.contains("let caretWasWith = Self.caretHolder(in: host)"),
                "nothing records who held the caret before the field opened, so there is nothing to restore to")
        #expect(text.contains("restoreCaret(to: previous, in: host, caretIsInField: caretIsInTheGoToField(host))"),
                "the live path no longer asks the same rule the tests pin")
    }
}
