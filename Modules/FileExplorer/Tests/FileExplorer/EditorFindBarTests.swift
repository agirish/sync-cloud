import Testing
import AppKit
import SwiftUI
@testable import FileExplorer

/// What the document header's Find button actually puts on screen.
///
/// **Measured, because the action's NAME is not the evidence.** `showFindBar` shipped sending
/// `NSTextFinder.Action.showFindInterface`, which reads like the right thing and is not: AppKit
/// builds the Replace field either way and, under that action, leaves it `isHidden` and parked
/// above the bar with no control to bring it back. The button's tooltip and its Help entry both
/// promise replace, so the bar has to carry it — and the only way to know it does is to find the
/// field and ask whether it is visible.
@MainActor
@Suite(.serialized) struct EditorFindBarTests {

    /// A text view in a window, set up the way ``PlainTextEditor`` sets its own up. A window is
    /// required: `performTextFinderAction` on a detached view does nothing at all, which would make
    /// every assertion below vacuous.
    private func hosted() -> (scroll: NSScrollView, view: NSTextView, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        // Marked the way `PlainTextEditor.makeNSView` marks its own — and
        // `theEditorReallyMarksItsScrollView` is what stops this line from being the only place the
        // mark is ever applied.
        scroll.identifier = EditorDocumentSurface.identifier
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.string = "one two three\nfour five six\n"
        return (scroll, view, window)
    }

    /// Every text field in the bar, and whether anything in its ancestry hides it.
    ///
    /// `NSSearchField` is an `NSTextField` subclass, so one walk finds both rows. The classes AppKit
    /// actually uses — `NSFindPatternSearchField`, `NSFindPatternTextField` — are private, which is
    /// why this asks about the visible shape rather than about types it may not name.
    private func fields(in view: NSView?) -> [(field: NSTextField, hidden: Bool)] {
        guard let view else { return [] }
        var found: [(NSTextField, Bool)] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField {
                var hidden = false
                var ancestor: NSView? = v
                while let a = ancestor {
                    if a.isHidden { hidden = true; break }
                    ancestor = a.superview
                }
                found.append((field, hidden))
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// The defect this test exists for: the bar opened, and the half the button promises was
    /// hidden inside it.
    @Test func theFindBarOpensWithItsReplaceRowShowing() {
        let (scroll, view, _) = hosted()
        PlainTextEditor.showFindBar(in: view)

        #expect(scroll.isFindBarVisible, "the find bar did not open at all")

        let rows = fields(in: scroll.findBarView)
        // **The positive control, and it comes first.** Without it a bar that rendered no fields
        // whatsoever would satisfy "none of them is hidden" and pass.
        #expect(rows.count == 2,
                "expected a Find row and a Replace row, found \(rows.count) text fields")
        #expect(rows.allSatisfy { !$0.hidden },
                "a row is hidden: \(rows.map { "\(type(of: $0.field)) hidden=\($0.hidden)" })")
    }

    /// The other half of the same claim, stated as the contrast that makes it a measurement: the
    /// action this used to send really does hide the Replace row, so the test above is not passing
    /// because both actions happen to behave the same.
    @Test func theFindOnlyActionIsWhatHidesTheReplaceRow() {
        let (scroll, view, _) = hosted()
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(sender)

        #expect(scroll.isFindBarVisible, "the find-only bar did not open")
        let rows = fields(in: scroll.findBarView)
        #expect(rows.count == 2, "found \(rows.count) text fields rather than two")
        #expect(rows.contains { $0.hidden },
                "showFindInterface no longer hides a row — showFindBar can go back to it")
    }

    // MARK: Whose caret is it

    /// The distinction the whole routing rests on: a field editor is an `NSTextView`, and it is not
    /// the document. `TextEditingChord`'s `responder is NSTextView` answers "yes" to both, which is
    /// why ⌘F cannot be routed on it.
    @Test func aFieldEditorIsNotTheDocument() {
        let (scroll, view, window) = hosted()
        let field = NSTextField(string: "not the document")
        field.frame = NSRect(x: 0, y: 360, width: 200, height: 22)
        window.contentView?.addSubview(field)

        window.makeFirstResponder(view)
        #expect(EditorDocumentSurface.focusedTextView(in: window) === view,
                "the document's own text view was not recognised")

        window.makeFirstResponder(field)
        // The field hands its caret to the window's shared field editor — an NSTextView, and the
        // exact responder that makes the naive test wrong.
        #expect(window.firstResponder is NSTextView,
                "the field did not take the caret, so this case proves nothing")
        #expect(EditorDocumentSurface.focusedTextView(in: window) == nil,
                "a field editor was mistaken for the open document")
        _ = scroll
    }

    /// The find bar's own fields live inside the editor's scroll view, so typing in them is still
    /// "in the document" as far as the chord is concerned — which is what stops a second ⌘F, made
    /// while the caret sits in the Find field, falling through to the pane search.
    @Test func theFindBarsOwnFieldsCountAsTheDocument() {
        let (scroll, view, window) = hosted()
        PlainTextEditor.showFindBar(in: view)
        guard let bar = scroll.findBarView,
              let field = fields(in: bar).first?.field else {
            Issue.record("the find bar produced no fields to focus")
            return
        }
        window.makeFirstResponder(field)
        #expect(EditorDocumentSurface.focusedTextView(in: window) === view,
                "the find bar's own field was treated as being outside the editor")
    }

    /// An unmarked text view — any other one the app might grow — is not the document either. The
    /// mark is the whole qualification, so this is the positive control for it.
    @Test func anUnmarkedTextViewIsNotTheDocument() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSTextView.scrollableTextView()
        other.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other.documentView as? NSTextView)
        #expect(EditorDocumentSurface.focusedTextView(in: window) == nil,
                "an unmarked scroll view was accepted as the editor's")
    }

    @Test func noWindowMeansNoDocument() {
        #expect(EditorDocumentSurface.focusedTextView(in: nil) == nil)
        #expect(EditorDocumentSurface.showFindBar(in: nil) == false)
    }

    /// **The mark is applied by the editor, not only by this file's fixture.** Every routing test
    /// above sets the identifier by hand, so deleting the line from `makeNSView` would leave them
    /// all green while ⌘F silently stopped finding the document. This mounts the real view.
    @Test func theEditorReallyMarksItsScrollView() {
        let editor = PlainTextEditor(text: .constant("hello"), isEditable: true, fontScale: 1,
                                     documentID: "/a/b.md", undoManager: UndoManager())
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()

        var marked: NSScrollView?
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView, scroll.identifier == EditorDocumentSurface.identifier {
                marked = scroll
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        #expect(marked != nil, "the editor mounted no scroll view carrying the mark")
        #expect(marked?.documentView is NSTextView,
                "the marked view holds no text view for a chord to reach")
    }
}
