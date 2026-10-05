import Testing
import SwiftUI
import AppKit
@testable import FileExplorer

/// The two-way bridge between the buffer and the `NSTextView`: what an edit to the text sends out,
/// and what a write from outside has to send back in.
///
/// **The bridge is the document's text storage now** (TE67.0, ``EditorSourceStorage``). The text
/// view is built around it rather than owning one, the buffer is published from its edits rather
/// than from the view's `textDidChange`, and a write to the buffer from outside is taken into it. So
/// what these pin moved with it: the old echo guard (`pushIfChanged` against a remembered string)
/// is gone, because nothing is pushed back at the view it came from; the identity of the storage is
/// what a document switch changes.
///
/// **Driven through a real `NSTextView` and the real coordinator**, built as `makeNSView` builds it:
/// the factory's view, re-pointed at the storage by ``PlainTextEditor/show(_:in:)``.
@MainActor
@Suite(.serialized) struct PlainTextEditorBridgeTests {

    struct Hosted {
        let view: NSTextView
        let coordinator: PlainTextEditor.Coordinator
        let source: EditorSourceStorage
        let buffer: EditorBuffer
        let undo: UndoManager
        let window: NSWindow
    }

    /// A text view set up the way ``PlainTextEditor/makeNSView(context:)`` sets one up, around a
    /// storage the buffer follows, with the coordinator as its delegate and in a window —
    /// `insertText` on a detached view is not a reliable stand-in for typing.
    private func hosted(_ initial: String) -> Hosted {
        let buffer = EditorBuffer()
        buffer.text = initial
        let source = EditorSourceStorage(text: initial)
        buffer.follow(source)
        let undo = UndoManager()
        let coordinator = PlainTextEditor.Coordinator(source: source, undoManager: undo,
                                                      documentID: "/scratch/a.md",
                                                      onSelectionChange: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.isRichText = false
        view.allowsUndo = true
        view.isEditable = true
        view.font = PlainTextEditor.font(scale: 1)
        PlainTextEditor.show(source, in: view)
        coordinator.textView = view
        view.delegate = coordinator
        return Hosted(view: view, coordinator: coordinator, source: source, buffer: buffer,
                      undo: undo, window: window)
    }

    /// One run-loop turn: what ends an event, and closes its undo group.
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    // MARK: The view is built around the document's storage

    /// **TextKit 2, around the shared storage.** Re-pointing the factory's view must not drop it to
    /// TextKit 1 — reading `layoutManager` would, for good — and the view must edit the storage it
    /// was handed, not one of its own.
    @Test func theViewIsOnTextKit2AndShowsTheSharedStorage() {
        let rig = hosted("one\n")
        defer { withExtendedLifetime(rig.window) {} }
        #expect(rig.view.textLayoutManager != nil, "re-pointing the view dropped it to TextKit 1")
        #expect(rig.view.textStorage === rig.source.textStorage, "the view shows a storage of its own")
        #expect(rig.view.string == "one\n")
    }

    /// **The storage is styled exactly as `view.string = text` styled it** — run for run, with the
    /// same typing attributes — so a reader cannot tell the shared storage from the old private one.
    /// Measured against the old construction in the same process rather than against literals.
    @Test func theSharedStorageIsStyledAsTheOldAssignmentStyledIt() {
        let text = "hello\nwörld 日本 é\n"
        let rig = hosted(text)
        defer { withExtendedLifetime(rig.window) {} }

        let oldScroll = NSTextView.scrollableTextView()
        rig.window.contentView?.addSubview(oldScroll)
        let old = oldScroll.documentView as! NSTextView
        old.isRichText = false
        old.allowsUndo = true
        old.font = PlainTextEditor.font(scale: 1)
        old.string = text

        func runs(_ storage: NSTextStorage) -> [String] {
            var out: [String] = []
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                out.append("\(range) \(NSDictionary(dictionary: attrs))")
            }
            return out
        }
        #expect(runs(rig.source.textStorage) == runs(old.textStorage!))
        #expect(NSDictionary(dictionary: rig.view.typingAttributes) == NSDictionary(dictionary: old.typingAttributes))
        #expect(rig.view.textColor == old.textColor, "the text colour is not the one the old view drew in")
    }

    /// **Building a view over a storage adds nothing to its history.** A mode switch builds one
    /// over a document with typing in its stack; a mount that registered a step would put a
    /// do-nothing ⌘Z in front of the typing. Counted, not inferred from `canUndo` — an empty group
    /// reads as undoable.
    @Test func mountingAViewOverAStorageRegistersNoUndo() {
        final class Counting: UndoManager {
            var registrations = 0
            override func registerUndo(withTarget target: Any, selector: Selector, object: Any?) {
                registrations += 1
                super.registerUndo(withTarget: target, selector: selector, object: object)
            }
        }
        let undo = Counting()
        let source = EditorSourceStorage(text: "a document with words in it\n")
        let editor = PlainTextEditor(source: source, isEditable: true, fontScale: 1,
                                     documentID: "/a/b.md", undoManager: undo)
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { withExtendedLifetime(window) {} }
        host.layoutSubtreeIfNeeded()
        spin()
        #expect(source.textView?.textStorage === source.textStorage, "the editor did not mount over the storage")
        #expect(undo.registrations == 0, "mounting a view over a storage registered \(undo.registrations) undo actions")
    }

    // MARK: Out: every edit to the storage reaches the buffer

    @Test func typingReachesTheBuffer() {
        let rig = hosted("one\n")
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.setSelectedRange(NSRange(location: 4, length: 0))
        // **`insertText(_:replacementRange:)`, which is the path typing takes.**
        rig.view.insertText("two\n", replacementRange: NSRange(location: 4, length: 0))
        #expect(rig.buffer.text == "one\ntwo\n", "typing did not reach the document")
        #expect(rig.source.text == "one\ntwo\n")
    }

    /// **Typing published to the buffer is not taken back into the storage.** That would be the old
    /// echo, at the model's level: a whole-storage replace per keystroke, with the caret thrown to
    /// wherever AppKit puts it and every range on the stack left stale.
    @Test func typingIsNotTakenBackIntoTheStorage() {
        let rig = hosted("one two\n")
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.setSelectedRange(NSRange(location: 3, length: 0))
        rig.view.insertText("X", replacementRange: NSRange(location: 3, length: 0))
        #expect(rig.view.selectedRange() == NSRange(location: 4, length: 0),
                "the caret moved after a keystroke — the edit was pushed back at the view")
        spin()
        rig.undo.undo()
        #expect(rig.view.string == "one two\n", "the keystroke could not be undone")
    }

    /// **⌘Z reaches the buffer.** On TextKit 2 an `NSTextView` undo sends no `textDidChange`
    /// (measured 2026-10-04), which the buffer used to follow alone. Mutation: publish from
    /// `textDidChange` only and this fails with the typing still in the buffer.
    @Test func undoReachesTheBuffer() {
        let rig = hosted("one\n")
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.setSelectedRange(NSRange(location: 4, length: 0))
        rig.view.insertText("two", replacementRange: NSRange(location: 4, length: 0))
        spin()
        let typed = rig.buffer.textVersion
        rig.undo.undo()
        #expect(rig.view.string == "one\n")
        #expect(rig.buffer.text == rig.view.string, "⌘Z reverted the screen and left the typing in the document")
        #expect(rig.buffer.textVersion != typed, "⌘Z did not bump the version the preview and autosave key on")
        let undone = rig.buffer.textVersion
        rig.undo.redo()
        #expect(rig.buffer.text == "one\ntwo", "⇧⌘Z did not reach the document")
        #expect(rig.buffer.textVersion != undone, "⇧⌘Z did not bump the version")
    }

    /// **An edit from outside the text, and its undo, reach the document while a word is being
    /// composed.** A tick in Split can land mid-composition. Measured: AppKit ends the composition
    /// when its storage is edited from outside, keeping the word as typed — so the word is committed
    /// text from then on, and the document must be what is on screen. The hold-back for marked text
    /// waits for a `textDidChange` that neither an outside edit nor a TextKit 2 undo sends; it must
    /// catch neither. Mutation: publish only from `textDidChange` while marked text is up.
    @Test func anOutsideEditAndItsUndoReachTheDocumentMidComposition() {
        let rig = hosted("- [ ] a\n")
        defer { withExtendedLifetime(rig.window) {} }
        rig.window.makeFirstResponder(rig.view)
        rig.view.setSelectedRange(NSRange(location: 8, length: 0))
        rig.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(rig.view.hasMarkedText(), "fixture: no composition in progress")
        #expect(rig.buffer.text == "- [ ] a\n", "a half-composed word reached the document")
        spin()

        rig.source.replace(NSRange(location: 3, length: 1), with: "x", undoManager: rig.undo)
        #expect(rig.view.string == "- [x] a\nに", "fixture: the tick or the word is not on screen")
        #expect(rig.buffer.text == rig.view.string, "a tick mid-composition left the document behind the screen")
        spin()
        rig.undo.undo()
        #expect(rig.view.string.hasPrefix("- [ ] a"), "fixture: ⌘Z did not take the tick back")
        #expect(rig.buffer.text == rig.view.string, "⌘Z mid-composition left the document behind the screen")
    }

    /// **A tick lands on its checkbox while a word is being composed above it.** The published text
    /// leaves the half-composed word out and the storage holds it, so a range measured on the one
    /// and applied to the other lands that many characters early — here, on the `[` instead of the
    /// space inside it. Mutation: measure the tick on `source.text`.
    @Test func aTickLandsOnItsBoxWhileAWordIsComposedAboveIt() {
        let rig = hosted("abc\n- [ ] x\n")
        defer { withExtendedLifetime(rig.window) {} }
        rig.window.makeFirstResponder(rig.view)
        rig.view.setSelectedRange(NSRange(location: 3, length: 0))
        rig.view.setMarkedText("ずっと", selectedRange: NSRange(location: 3, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(rig.view.hasMarkedText(), "fixture: no composition in progress")
        #expect(rig.source.text == "abc\n- [ ] x\n", "fixture: the published text holds the composition")

        #expect(EditorWorkspaceView.toggleTask(onLine: 2, in: rig.source, undoManager: rig.undo))
        #expect(rig.view.string == "abcずっと\n- [x] x\n", "the tick landed off its checkbox")
        #expect(rig.buffer.text == rig.view.string)
    }

    /// **⌘Z while a word is being composed takes the composition back first**, so no older edit is
    /// ever replayed under marked text — measured here with the typing's undo belonging to a view a
    /// mode switch discarded, the case where a replay would come from outside the view on screen.
    /// Whatever it takes back, the document is what is on screen afterwards. (This is why the
    /// hold-back for marked text needs no exception for undo: there is no undo for it to catch.)
    @Test func undoMidCompositionLeavesTheDocumentMatchingTheScreen() {
        let rig = hosted("ab")
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.setSelectedRange(NSRange(location: 0, length: 0))
        rig.view.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        spin()

        // The mode switch: a second view over the same storage, on screen and composing.
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        rig.window.contentView?.addSubview(scroll)
        let live = scroll.documentView as! NSTextView
        live.isRichText = false
        live.allowsUndo = true
        live.isEditable = true
        PlainTextEditor.show(rig.source, in: live)
        live.delegate = rig.coordinator
        rig.view.enclosingScrollView?.removeFromSuperview()
        rig.window.makeFirstResponder(live)
        live.setSelectedRange(NSRange(location: 3, length: 0))
        live.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(live.hasMarkedText(), "fixture: no composition in progress")
        #expect(rig.buffer.text == "Xab", "a half-composed word reached the document")

        rig.undo.undo()
        #expect(live.string.hasPrefix("X"), "⌘Z mid-composition reached past the composition")
        #expect(!live.hasMarkedText(), "⌘Z left the composition up")
        #expect(rig.buffer.text == live.string, "after ⌘Z mid-composition the document is not what is on screen")
        spin()
        rig.undo.undo()
        #expect(rig.buffer.text == "ab" && live.string == "ab", "the typing before the composition did not undo next")
    }

    /// **A half-composed word is not the document's yet.** Marked text is in the storage the moment
    /// it is typed and the view says nothing until it is committed, so the buffer — and autosave —
    /// never held a kana reading before the kanji replaced it. Held back here, published on the
    /// commit through `textDidChange`, and on `unmarkText` too.
    @Test func markedTextReachesTheBufferOnlyWhenCommitted() {
        let rig = hosted("ab")
        defer { withExtendedLifetime(rig.window) {} }
        rig.window.makeFirstResponder(rig.view)
        rig.view.setSelectedRange(NSRange(location: 2, length: 0))
        let none = NSRange(location: NSNotFound, length: 0)

        rig.view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(rig.view.string == "abに", "fixture: the marked text is not in the storage")
        #expect(rig.buffer.text == "ab", "a half-composed word reached the document")
        rig.view.insertText("日", replacementRange: none)
        #expect(rig.buffer.text == "ab日", "the committed word did not reach the document")

        rig.view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(rig.buffer.text == "ab日")
        rig.view.unmarkText()
        #expect(rig.buffer.text == "ab日k", "a word committed by unmarkText never reached the document")
    }

    // MARK: In: a write from outside reaches the view

    /// The positive control. Without it, "nothing was taken in" and "nothing in this harness works"
    /// measure the same.
    @Test func aBufferWrittenFromOutsideReachesTheView() {
        let rig = hosted("one\n")
        defer { withExtendedLifetime(rig.window) {} }
        rig.buffer.text = "two\n"
        #expect(rig.view.string == "two\n")
        #expect(rig.source.text == "two\n")
    }

    /// **A write back to text the storage held before an edit is still taken in.** The storage
    /// remembers what it last published; if typing did not move that record, an outside write
    /// matching the stale record would be skipped and the discarded edit left on screen.
    @Test func textSetFromOutsideReachesTheViewEvenBackToWhatItHeldBefore() {
        let rig = hosted("original\n")
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.setSelectedRange(NSRange(location: 0, length: 0))
        rig.view.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        #expect(rig.buffer.text == "Xoriginal\n")

        rig.buffer.text = "original\n"
        #expect(rig.view.string == "original\n",
                "a write back to the pre-edit text left the discarded edit on screen")
    }

    /// **Bytes, not `==`.** NFC and NFD are one Swift `String` value; an NFD write over NFC text
    /// must still reach the storage, or the screen and a save would hold different bytes.
    @Test func aWriteThatDiffersOnlyInNormalisationIsTakenIn() {
        let nfc = "caf\u{E9}\n"
        let nfd = "cafe\u{301}\n"
        #expect(nfc == nfd, "fixture: these must be canonically equivalent")
        let rig = hosted(nfc)
        defer { withExtendedLifetime(rig.window) {} }
        rig.buffer.text = nfd
        #expect(Array(rig.source.textStorage.string.utf8) == Array(nfd.utf8),
                "the storage kept the NFC bytes under an NFD buffer")
    }

    // MARK: A document switch changes which storage, not its text

    /// **Two files holding the same bytes are still two storages**, and the view is re-pointed at
    /// the incoming one. A text comparison cannot see this switch; the undo stack — kept beside the
    /// storage — is why it matters.
    @Test func aDocumentSwitchWithIdenticalTextRepointsTheView() {
        let rig = hosted("same bytes\n")
        defer { withExtendedLifetime(rig.window) {} }
        let other = EditorSourceStorage(text: "same bytes\n")
        #expect(PlainTextEditor.follow(other, in: rig.view), "the view was not re-pointed")
        #expect(rig.view.textStorage === other.textStorage)
        #expect(!PlainTextEditor.follow(other, in: rig.view), "re-pointing the same storage is not a switch")
        #expect(rig.view.textLayoutManager != nil)
    }

    /// A switch into a shorter document clamps the caret rather than leaving it past the end.
    @Test func aSwitchIntoAShorterDocumentClampsTheCaret() {
        let rig = hosted("a long original line\n")
        defer { withExtendedLifetime(rig.window) {} }
        rig.view.setSelectedRange(NSRange(location: 18, length: 0))
        PlainTextEditor.follow(EditorSourceStorage(text: "short\n"), in: rig.view)
        #expect(rig.view.selectedRange().location <= (rig.view.string as NSString).length)
        #expect(rig.view.selectedRange().location == 6)
    }

    // MARK: Scroll sync

    /// Only the split follows where the text has scrolled to — the rule that decides whether the
    /// topmost visible line is worked out at all on a scroll tick.
    @Test func theVisibleLineIsFollowedOnlyInSplit() {
        #expect(!EditorWorkspaceView.followsVisibleLine(.edit))
        #expect(!EditorWorkspaceView.followsVisibleLine(.preview))
        #expect(EditorWorkspaceView.followsVisibleLine(.split))
    }

    /// And a coordinator with nobody following it reports nothing — the wiring under that rule.
    @Test func aCoordinatorWithNoReporterIsTheRestingState() {
        let rig = hosted("one\ntwo\n")
        defer { withExtendedLifetime(rig.window) {} }
        #expect(rig.coordinator.onVisibleLineChange == nil)
        rig.coordinator.onVisibleLineChange = { _ in }
        #expect(rig.coordinator.onVisibleLineChange != nil)
    }
}
