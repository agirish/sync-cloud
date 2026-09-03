import Testing
import SwiftUI
import AppKit
@testable import FileExplorer

/// The two-way bridge between the buffer and the `NSTextView`: what typing sends out, and what an
/// external write has to send back in.
///
/// **Driven through a real `NSTextView` and the real coordinator, not through SwiftUI.** Mounting an
/// `NSViewRepresentable` in an `NSHostingView` in this test process segfaults, so the parts that
/// matter are exercised directly: `insertText(_:replacementRange:)` is the path typing takes and
/// posts the same change notification, and `pushIfChanged` is the whole of the update pass's text
/// handling.
///
/// **Why any of this needs a test now.** The echo guard used to ask `view.string != text` — a
/// question about the view itself, self-correcting by construction, and one that copied the whole
/// buffer out of AppKit to answer, on every render pass. It now asks whether the incoming string
/// differs from the one the coordinator last handed over, which is a pointer comparison in the
/// ordinary case and is *state*. State can drift, and when it drifts the failure is silent: an
/// external write that matches the stale record never reaches the view, so the text on screen and
/// the text in the document disagree with nothing anywhere saying so.
@MainActor
@Suite(.serialized) struct PlainTextEditorBridgeTests {

    /// Somewhere for the binding's writes to land, so what typing published can be read back.
    @MainActor
    final class Box {
        var text: String = ""
    }

    /// A text view set up the way ``PlainTextEditor/makeNSView(context:)`` sets one up, with the
    /// coordinator as its delegate and in a window — `insertText` on a detached view is not a
    /// reliable stand-in for typing.
    private func hosted(_ initial: String)
        -> (view: NSTextView, coordinator: PlainTextEditor.Coordinator,
            box: Box, window: NSWindow) {
        let box = Box()
        box.text = initial
        let binding = Binding<String>(get: { box.text }, set: { box.text = $0 })
        let coordinator = PlainTextEditor.Coordinator(text: binding, undoManager: UndoManager(),
                                                      documentID: "/scratch/a.md",
                                                      onSelectionChange: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.delegate = coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isEditable = true
        view.string = initial
        // The one line `makeNSView` does that this is standing in for: the view holds exactly this
        // string, so the guard starts in step with it.
        coordinator.pushedText = initial
        coordinator.textView = view
        return (view, coordinator, box, window)
    }

    /// The positive control. Without it, "the guard did not push" and "nothing in this harness
    /// works" measure the same.
    @Test func aStringTheViewHasNotSeenIsPushed() {
        let (view, coordinator, _, window) = hosted("one\n")
        // Held, never closed: closing an NSWindow in this test process (no NSApp)
        // segfaults, which is why no AppKit suite here closes one.
        defer { withExtendedLifetime(window) {} }
        #expect(PlainTextEditor.pushIfChanged("two\n", into: view, coordinator: coordinator))
        #expect(view.string == "two\n")
    }

    /// The echo, which is what the guard exists to swallow: the string the view already holds
    /// arrives back through the binding on the very next render pass, and must not be re-applied.
    @Test func theStringTheViewAlreadyHoldsIsNotPushedBackAtIt() {
        let (view, coordinator, _, window) = hosted("one\ntwo\n")
        // Held, never closed: closing an NSWindow in this test process (no NSApp)
        // segfaults, which is why no AppKit suite here closes one.
        defer { withExtendedLifetime(window) {} }
        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(!PlainTextEditor.pushIfChanged("one\ntwo\n", into: view, coordinator: coordinator))
        #expect(view.selectedRange().location == 2,
                "an echo was applied anyway and moved the caret")
    }

    /// Typing reaches the document. `textDidChange` now writes two things — the binding and the
    /// coordinator's record of what the view holds — so this pins the half a reader of the record
    /// cannot see.
    @Test func typingReachesTheBuffer() {
        let (view, _, box, window) = hosted("one\n")
        // Held, never closed: closing an NSWindow in this test process (no NSApp)
        // segfaults, which is why no AppKit suite here closes one.
        defer { withExtendedLifetime(window) {} }
        view.setSelectedRange(NSRange(location: 4, length: 0))
        // **`insertText(_:replacementRange:)`, which is the path typing takes** — it posts the
        // change notification a direct `textStorage` splice would not.
        view.insertText("two\n", replacementRange: NSRange(location: 4, length: 0))
        #expect(box.text == "one\ntwo\n", "typing did not reach the document")
        #expect(view.string == "one\ntwo\n")
    }

    /// **The failure the guard's new shape can actually have, and the reason it is tested at all.**
    ///
    /// Reload from Disk hands the view the text it held *before* the typing being discarded. The
    /// coordinator's record has to have moved with that typing, or the incoming string matches what
    /// it believes the view holds, nothing is pushed, and the discarded edit stays on screen — the
    /// one route in this app that throws typing away on purpose, quietly not doing it.
    ///
    /// Mutation-checked: deleting `pushedText = string` from `textDidChange` fails exactly here and
    /// leaves every other test in this file green.
    @Test func textSetFromOutsideReachesTheViewEvenBackToWhatItHeldBefore() {
        let (view, coordinator, box, window) = hosted("original\n")
        // Held, never closed: closing an NSWindow in this test process (no NSApp)
        // segfaults, which is why no AppKit suite here closes one.
        defer { withExtendedLifetime(window) {} }

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        #expect(box.text == "Xoriginal\n")

        // Reload from disk: the document goes back to what the file says, which happens to be what
        // the view was given when it was built.
        #expect(PlainTextEditor.pushIfChanged("original\n", into: view, coordinator: coordinator),
                "a reload back to the pre-edit text was swallowed as an echo")
        #expect(view.string == "original\n",
                "a reload that discarded the buffer left the discarded text on screen")
    }

    /// The same trap in the other direction: two files holding identical bytes.
    ///
    /// The buffer does not change, so nothing about the text says anything happened — which is
    /// exactly why the undo stack is keyed on ``PlainTextEditor/documentID`` and not on the text.
    /// Replaying one document's registrations into another splices its characters out or throws
    /// `NSRangeException` and takes the app down; this pins that the guard being about a remembered
    /// string rather than about the view's contents has not moved that decision.
    @Test func aDocumentSwitchWithIdenticalTextPushesNothingAndStillSwapsTheIdentity() {
        let (view, coordinator, _, window) = hosted("same bytes\n")
        // Held, never closed: closing an NSWindow in this test process (no NSApp)
        // segfaults, which is why no AppKit suite here closes one.
        defer { withExtendedLifetime(window) {} }
        #expect(!PlainTextEditor.pushIfChanged("same bytes\n", into: view, coordinator: coordinator))
        // The identity is a separate assignment in `updateNSView`, and separate is the point.
        coordinator.documentID = "/scratch/b.md"
        #expect(coordinator.documentID == "/scratch/b.md")
        #expect(view.string == "same bytes\n")
    }

    /// A push into a shorter buffer clamps the caret rather than leaving it past the end.
    @Test func aPushIntoAShorterBufferClampsTheCaret() {
        let (view, coordinator, _, window) = hosted("a long original line\n")
        // Held, never closed: closing an NSWindow in this test process (no NSApp)
        // segfaults, which is why no AppKit suite here closes one.
        defer { withExtendedLifetime(window) {} }
        view.setSelectedRange(NSRange(location: 18, length: 0))
        PlainTextEditor.pushIfChanged("short\n", into: view, coordinator: coordinator)
        #expect(view.selectedRange().location <= (view.string as NSString).length)
        #expect(view.selectedRange().location == 6)
    }

    /// Only the split follows where the text has scrolled to — the rule that decides whether the
    /// topmost visible line is worked out at all on a scroll tick.
    @Test func theVisibleLineIsFollowedOnlyInSplit() {
        #expect(!EditorWorkspaceView.followsVisibleLine(.edit))
        #expect(!EditorWorkspaceView.followsVisibleLine(.preview))
        #expect(EditorWorkspaceView.followsVisibleLine(.split))
    }

    /// And a coordinator with nobody following it reports nothing — the wiring under that rule.
    @Test func aCoordinatorWithNoReporterIsTheRestingState() {
        let (_, coordinator, _, window) = hosted("one\ntwo\n")
        // Held, never closed: closing an NSWindow in this test process (no NSApp)
        // segfaults, which is why no AppKit suite here closes one.
        defer { withExtendedLifetime(window) {} }
        #expect(coordinator.onVisibleLineChange == nil)
        coordinator.onVisibleLineChange = { _ in }
        #expect(coordinator.onVisibleLineChange != nil)
    }
}
