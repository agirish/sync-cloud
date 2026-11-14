import Testing
import AppKit
import SwiftUI
@testable import FileExplorer

/// What the document header's Find button actually puts on screen, measured rather than trusted to
/// the action's name: under `NSTextFinder.Action.showFindInterface` AppKit builds the Replace field
/// but leaves it hidden, with no control to bring it back. The button's tooltip and Help promise
/// replace, so these find the field and ask whether it is visible.
@MainActor
@Suite(.serialized) struct EditorFindBarTests {

    /// A text view in a window, set up the way ``PlainTextEditor`` sets its own up. A window is
    /// required: `performTextFinderAction` on a detached view does nothing, which would make every
    /// assertion below vacuous.
    ///
    /// A test that opens the bar must retire it as it ends (`PlainTextEditor.retireFindBar`):
    /// opening it searches for whatever the machine-wide Find pasteboard holds, and a match landing
    /// as the rig is freed leaves AppKit's find indicator a redraw for a freed finder, crashing a
    /// later test (`docs/flaky-tests.md`, "A find indicator's redraw outlives the text view it was
    /// asked for"). `theEditorReallyMarksItsScrollView` checks the real editor applies the mark too.
    private func hosted() -> (scroll: NSScrollView, view: NSTextView, window: NSWindow) {
        EditorTestRigs.markedTextView(text: "one two three\nfour five six\n", allowsUndo: false)
    }

    /// Every text field in the bar, and whether anything in its ancestry hides it. `NSSearchField`
    /// is an `NSTextField` subclass, so one walk finds both rows; AppKit's own classes are private,
    /// so this asks about the visible shape rather than types it can't name.
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

    /// The bar opens with both rows showing, including the Replace half the button promises.
    @Test func theFindBarOpensWithItsReplaceRowShowing() {
        let (scroll, view, _) = hosted()
        defer { PlainTextEditor.retireFindBar(of: view) }
        PlainTextEditor.showFindBar(in: view)

        #expect(scroll.isFindBarVisible, "the find bar did not open at all")

        let rows = fields(in: scroll.findBarView)
        // The positive control, first: a bar with no fields at all would satisfy "none is hidden".
        #expect(rows.count == 2,
                "expected a Find row and a Replace row, found \(rows.count) text fields")
        #expect(rows.allSatisfy { !$0.hidden },
                "a row is hidden: \(rows.map { "\(type(of: $0.field)) hidden=\($0.hidden)" })")
    }

    /// The contrast that makes the test above a measurement: the find-only action really does hide
    /// the Replace row, so the two actions don't behave the same.
    @Test func theFindOnlyActionIsWhatHidesTheReplaceRow() {
        let (scroll, view, _) = hosted()
        defer { PlainTextEditor.retireFindBar(of: view) }
        let sender = NSMenuItem()
        sender.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performTextFinderAction(sender)

        #expect(scroll.isFindBarVisible, "the find-only bar did not open")
        let rows = fields(in: scroll.findBarView)
        #expect(rows.count == 2, "found \(rows.count) text fields rather than two")
        #expect(rows.contains { $0.hidden },
                "showFindInterface no longer hides a row — showFindBar can go back to it")
    }

    // MARK: A press answered once

    /// The real editor, mounted in a window (the find bar needs one), holding `findRequest`.
    private func mountedEditor(findRequest: Int, defaults: UserDefaults)
        -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: editor(findRequest: findRequest, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    /// On its own defaults, as every mounted editor is — see `editorTestDefaults`.
    private func editor(findRequest: Int, defaults: UserDefaults) -> AnyView {
        AnyView(PlainTextEditor(source: EditorSourceStorage(text: "one two three\n"), isEditable: true, fontScale: 1,
                                documentID: "/a/b.md", undoManager: UndoManager(),
                                findRequest: findRequest)
            .editorTestDefaults(defaults))
    }

    /// A text view built after a Find press doesn't replay it. The counter is the workspace's and
    /// outlives the text view (× and Close Document, a refused file and Preview each take the view
    /// down), so a new coordinator starting at 0 would read the standing count as a fresh press.
    @Test func aTextViewBuiltAfterAFindPressDoesNotOpenTheBar() {
        let defaults = ScratchDefaults("EditorFindBarTests")
        let (host, window) = mountedEditor(findRequest: 3, defaults: defaults)
        guard let scroll = EditorTestRigs.markedScroll(in: host) else {
            Issue.record("the editor mounted no marked scroll view")
            return
        }
        defer { if let view = scroll.documentView as? NSTextView { PlainTextEditor.retireFindBar(of: view) } }
        #expect(!scroll.isFindBarVisible,
                "a text view mounted under a standing find request opened the find bar by itself")

        // The positive control: the next press, made while this view is on screen, still opens it,
        // so the bar can open here at all.
        host.rootView = editor(findRequest: 4, defaults: defaults)
        host.layoutSubtreeIfNeeded()
        #expect(scroll.isFindBarVisible, "a press made while the text view was on screen was lost")
        _ = window
    }

    // MARK: Whose caret is it

    /// The routing rests on this: a field editor is an `NSTextView` but not the document.
    /// `TextEditingChord`'s `responder is NSTextView` answers yes to both, so ⌘F can't route on it.
    @Test func aFieldEditorIsNotTheDocument() {
        let (scroll, view, window) = hosted()
        let field = NSTextField(string: "not the document")
        field.frame = NSRect(x: 0, y: 360, width: 200, height: 22)
        window.contentView?.addSubview(field)

        window.makeFirstResponder(view)
        #expect(EditorDocumentSurface.focusedTextView(in: window) === view,
                "the document's own text view was not recognised")

        window.makeFirstResponder(field)
        // The field hands its caret to the window's shared field editor, an NSTextView: the
        // responder that makes the naive test wrong.
        #expect(window.firstResponder is NSTextView,
                "the field did not take the caret, so this case proves nothing")
        #expect(EditorDocumentSurface.focusedTextView(in: window) == nil,
                "a field editor was mistaken for the open document")
        _ = scroll
    }

    /// An unmarked text view, any other the app might grow, is not the document either: the mark
    /// is the whole qualification.
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

    // MARK: Closing retires the bar

    /// Closing the document takes its find bar down with it, in both editors: each editor's
    /// `dismantleNSView` calls `PlainTextEditor.retireFindBar`. Without it a search in flight lands
    /// after the close and leaves AppKit's find indicator a redraw for a freed finder
    /// (`docs/flaky-tests.md`, "A find indicator's redraw outlives the text view it was asked
    /// for"). The crash is too rare to catch a dropped call, so the call is pinned by what it does.
    @Test(arguments: ["Source", "Preview"]) func closingTheDocumentRetiresItsFindBar(_ editor: String) {
        let source = EditorSourceStorage(text: "one two three\n")
        let undo = UndoManager()
        let defaults = ScratchDefaults("EditorFindBarTests.close")
        func mounted(findRequest: Int) -> AnyView {
            AnyView((editor == "Source"
                ? AnyView(PlainTextEditor(source: source, isEditable: true, fontScale: 1, documentID: "/a/b.md",
                                          undoManager: undo, findRequest: findRequest))
                : AnyView(PreviewEditorView(source: source, undoManager: undo, findRequest: findRequest)))
                .editorTestDefaults(defaults))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: mounted(findRequest: 0))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let scroll = EditorTestRigs.markedScroll(in: host) else {
            Issue.record("the \(editor) editor mounted no marked scroll view")
            return
        }
        host.rootView = mounted(findRequest: 1)
        host.layoutSubtreeIfNeeded()
        // The positive control: the bar really opened, so the absence below is the close's doing.
        #expect(scroll.isFindBarVisible, "the find press did not open the \(editor) bar")

        host.rootView = AnyView(Color.clear)
        host.layoutSubtreeIfNeeded()
        #expect(scroll.window == nil, "the \(editor) editor was not taken down, so this proves nothing")
        #expect(!scroll.isFindBarVisible, "the \(editor) editor closed with its find bar still up")
    }
}
