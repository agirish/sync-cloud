import Testing
import AppKit
import Design
@testable import FileExplorer

/// The menu bar's half of the editor (roadmap RD1), as seen from this module: which verbs carry a
/// chord, whether the context menu draws the same one, and where the caret has to be for a verb
/// fired from the menu bar to reach the document.
///
/// **The caret tests are the point.** A menu key equivalent outranks the field editor, so ⌘B
/// registered on a menu item arrives whether the caret is in the document, in the ⌘K field, or in
/// the find bar's own Find field. `EditorDocumentSurface.applyMarkup` is where that is decided, and
/// nothing above it can see the responder — so both directions are asserted here, on a real window
/// with a real first responder.
@MainActor
@Suite(.serialized) struct EditorMenuChordTests {

    /// A text view in a window, marked the way `PlainTextEditor.makeNSView` marks its own. Same
    /// fixture as `EditorFindBarTests`, for the same reason: a detached view has no first responder
    /// to ask about.
    private func hosted(text: String = "one two three\n") -> (scroll: NSScrollView, view: NSTextView, window: NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroll.identifier = EditorDocumentSurface.identifier
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.allowsUndo = true
        view.string = text
        return (scroll, view, window)
    }

    // MARK: Which verbs carry a chord

    /// The five inline verbs and nothing else. Headings and lists are menu-only because ⌘1…⌘4 are
    /// the workspaces and ⌥ is barred — a rule, so it is pinned as one rather than left to whoever
    /// next edits the switch.
    @Test func onlyTheInlineVerbsCarryAChord() {
        let chorded = MarkupVerb.menuOrder.compactMap { $0 }.filter { $0.chord != nil }
        #expect(chorded == [.bold, .italic, .strikethrough, .inlineCode, .link],
                "the chorded verbs are \(chorded.map(\.title))")
        // …and each maps to the registry member it should — the display is what the reader sees.
        #expect(MarkupVerb.bold.chord?.display == "⌘B")
        #expect(MarkupVerb.italic.chord?.display == "⌘I")
        #expect(MarkupVerb.strikethrough.chord?.display == "⇧⌘X")
        #expect(MarkupVerb.inlineCode.chord?.display == "⇧⌘K")
        #expect(MarkupVerb.link.chord?.display == "⇧⌘L")
    }

    /// The three view modes each carry their own ⌃⌘ digit, in the capsule's order.
    @Test func theViewModesCarryControlCommandDigits() {
        #expect(EditorMode.edit.chord.display == "⌃⌘1")
        #expect(EditorMode.preview.chord.display == "⌃⌘2")
        #expect(EditorMode.split.chord.display == "⌃⌘3")
    }

    // MARK: The context menu draws the same chords

    /// **The context menu's items carry the menu bar's key equivalents — exactly those, and none
    /// for the verbs that have none.** They were deliberately blank while nothing registered them;
    /// now that the Markup menu does, a blank here would be the one surface not saying so, and a
    /// different key here would be worse.
    @Test func theContextMenuDrawsEachVerbsRegisteredChord() {
        let menu = PlainTextEditor.Coordinator.markupMenu(target: nil, action: #selector(NSText.copy(_:)))
        let items = menu.items.filter { !$0.isSeparatorItem }
        // The positive control: the menu really is built from `menuOrder`, so the loop below
        // walks every verb rather than an empty list.
        #expect(items.count == MarkupVerb.menuOrder.compactMap { $0 }.count)
        for item in items {
            let verb = MarkupVerb.menuOrder[item.tag]
            #expect(verb?.title == item.title, "tag \(item.tag) titled \(item.title) names \(String(describing: verb))")
            if let chord = verb?.chord {
                #expect(item.keyEquivalent == chord.appKitKeyEquivalent,
                        "\(item.title) draws \(item.keyEquivalent), the menu bar registers \(chord.display)")
                #expect(item.keyEquivalentModifierMask == chord.appKitModifierMask,
                        "\(item.title) draws the wrong modifiers for \(chord.display)")
            } else {
                #expect(item.keyEquivalent.isEmpty, "\(item.title) advertises a chord nothing registers")
            }
        }
        // …and the menu is genuinely divided the way the menu bar's will be.
        #expect(menu.items.filter(\.isSeparatorItem).count == MarkupVerb.menuOrder.filter { $0 == nil }.count)
    }

    // MARK: Where the caret has to be

    /// The ordinary case, and the positive control for every refusal below: with the caret in the
    /// document, a verb from the menu bar edits it.
    @Test func aVerbReachesTheDocumentWhenTheCaretIsInIt() {
        let (_, view, window) = hosted()
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 4, length: 3))

        #expect(EditorDocumentSurface.applyMarkup(.bold, in: window))
        #expect(view.string == "one **two** three\n")
        // The words stay selected, so a second verb aims at the same ones.
        #expect(view.selectedRange() == NSRange(location: 6, length: 3))
        // …and it is one undo step, the way the context menu's verbs are.
        #expect(view.undoManager?.canUndo == true, "the verb registered no undo")
    }

    /// **In the ⌘K field, the rename row, a pane's search — any field editor — the verb refuses.**
    /// This is decision B's other half, and the reason none of these chords may route on
    /// `TextEditingChord`: a field editor IS an `NSTextView`, and a ⌘I routed on that would
    /// italicise the Go-to field.
    @Test func aVerbRefusesWhenTheCaretIsInAFieldEditor() {
        let (_, view, window) = hosted()
        let field = NSTextField(string: "not the document")
        field.frame = NSRect(x: 0, y: 360, width: 200, height: 22)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        #expect(window.firstResponder is NSTextView,
                "the field did not take the caret, so this case proves nothing")
        view.setSelectedRange(NSRange(location: 4, length: 3))

        #expect(!EditorDocumentSurface.applyMarkup(.bold, in: window))
        #expect(view.string == "one two three\n", "the document was edited from a field editor")
        #expect(field.stringValue == "not the document", "the field was edited")
    }

    /// **The find bar's own field is inside the editor's scroll view, and a verb still refuses
    /// there.** ⌘F treats that field as "in the document" so a second ⌘F does not fall through to
    /// the pane search; Bold cannot, because the selection the reader is looking at is in the Find
    /// field and the verb would wrap whatever the document happened to have selected instead.
    @Test func aVerbRefusesInTheFindBarsOwnField() {
        let (scroll, view, window) = hosted()
        view.setSelectedRange(NSRange(location: 4, length: 3))
        PlainTextEditor.showFindBar(in: view)
        guard let bar = scroll.findBarView,
              let field = firstTextField(in: bar) else {
            Issue.record("the find bar produced no field to focus")
            return
        }
        window.makeFirstResponder(field)
        // The premise the test rests on: the walk-up test says "document" here, and the strict
        // one must say "no" — both directions, or a change to either goes unnoticed.
        #expect(EditorDocumentSurface.focusedTextView(in: window) === view,
                "the find field is no longer inside the surface — ⌘F's routing has changed too")
        #expect(EditorDocumentSurface.caretTextView(in: window) == nil,
                "the find field's editor was taken for the document's caret")

        #expect(!EditorDocumentSurface.applyMarkup(.bold, in: window))
        #expect(view.string == "one two three\n", "Bold in the Find field edited the document")
    }

    /// The other half of the same distinction: Find Next from the find bar's field DOES reach the
    /// document, because stepping through matches from the Find field is what the field is for.
    @Test func findNextReachesTheDocumentFromTheFindBarsField() {
        let (scroll, view, window) = hosted(text: "one two one two\n")
        PlainTextEditor.showFindBar(in: view)
        guard let bar = scroll.findBarView,
              let field = firstTextField(in: bar) else {
            Issue.record("the find bar produced no field to focus")
            return
        }
        window.makeFirstResponder(field)
        #expect(EditorDocumentSurface.performFind(.nextMatch, in: window),
                "Find Next was refused from inside the find bar")
        // …and refused from outside the editor, so ⌘G in a pane searches nothing.
        let other = NSTextField(string: "elsewhere")
        other.frame = NSRect(x: 300, y: 360, width: 200, height: 22)
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other)
        #expect(!EditorDocumentSurface.performFind(.nextMatch, in: window))
    }

    /// A read-only document is shown, not hidden, and the menu bar's verbs must not write into it
    /// any more than the context menu's do — the context menu withholds its Markup submenu there.
    @Test func aVerbRefusesOnAReadOnlyDocument() {
        let (_, view, window) = hosted()
        view.isEditable = false
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 4, length: 3))
        #expect(!EditorDocumentSurface.applyMarkup(.bold, in: window))
        #expect(view.string == "one two three\n")
    }

    @Test func noWindowMeansNoVerb() {
        #expect(EditorDocumentSurface.caretTextView(in: nil) == nil)
        #expect(!EditorDocumentSurface.applyMarkup(.bold, in: nil))
        #expect(!EditorDocumentSurface.performFind(.nextMatch, in: nil))
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for sub in view.subviews {
            if let found = firstTextField(in: sub) { return found }
        }
        return nil
    }
}
