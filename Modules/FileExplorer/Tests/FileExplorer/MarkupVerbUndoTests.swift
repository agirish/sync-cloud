import Testing
import SwiftUI
import AppKit
@testable import FileExplorer

/// A markup verb is **its own undo step** — never part of the typing before it, and never the
/// start of the typing after it — through every door that reaches it.
///
/// **The defect this pins.** `PlainTextEditor.apply` inserts through `insertText(_:replacementRange:)`,
/// the path typing takes, and `NSTextView` coalesces typing into one undo action across events. So
/// "foo" typed and then Markup ▸ Bold over the empty selection after it came back as ONE ⌘Z: the
/// `****` and the "foo" went together. Reported by review on 2026-10-04.
///
/// **Driven through a real `NSTextView` in a window, with the coordinator as delegate**, for
/// `PlainTextEditorBridgeTests`' reason — mounting the representable in this process segfaults —
/// and with a run-loop turn between every edit and every ⌘Z: the undo manager groups by event, so
/// without one every edit in a test is a single group and "one ⌘Z" proves nothing.
///
/// **What the document holds after a ⌘Z is not asserted, and that is a known gap, not an oversight.**
/// Measured 2026-10-04: on TextKit 2 an undo edits the storage without `shouldChangeText` or
/// `didChangeText`, so `textDidChange` never runs and the binding keeps the undone text until the
/// next keystroke — on TextKit 1 it follows. That is the same with or without the breaks here.
@MainActor
@Suite(.serialized) struct MarkupVerbUndoTests {

    struct Rig {
        let view: NSTextView
        let coordinator: PlainTextEditor.Coordinator
        let undo: UndoManager
        let window: NSWindow
    }

    /// The three ways a verb reaches the text view. All three end in `PlainTextEditor.apply`; this
    /// is what keeps one of them from growing a path of its own that the undo boundary misses.
    enum Door: String, CaseIterable, CustomTestStringConvertible {
        /// The menu bar's Markup items, through `EditorDocumentSurface.applyMarkup(_:in:)`.
        case markupMenu
        /// The text view's own context menu, through `Coordinator.applyMarkup(_:)` and the item's tag.
        case contextMenu
        /// TE52's format bar, through `EditorTextViewHandle.applyMarkup(_:)`.
        case formatBar
        var testDescription: String { rawValue }
    }

    /// A text view set up as `makeNSView` sets one up — marked as the document surface, the
    /// substitutions that could rewrite a typed word off — in a window, the caret at the end.
    private func rig(_ text: String) -> Rig {
        let undo = UndoManager()
        let coordinator = PlainTextEditor.Coordinator(
            text: .constant(text), undoManager: undo,
            documentID: "/scratch/a.md", onSelectionChange: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = EditorTextView.scrollableTextView()
        scroll.identifier = EditorDocumentSurface.identifier
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! EditorTextView
        view.isRichText = false
        view.allowsUndo = true
        view.isEditable = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.string = text
        coordinator.pushedText = text
        coordinator.textView = view
        view.delegate = coordinator
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        spin()
        return Rig(view: view, coordinator: coordinator, undo: undo, window: window)
    }

    /// One turn of the run loop — what separates two events, and closes the undo group of the first.
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    private func type(_ text: String, in rig: Rig) {
        rig.view.insertText(text, replacementRange: rig.view.selectedRange())
        spin()
    }

    private func apply(_ verb: MarkupVerb, through door: Door, in rig: Rig) {
        switch door {
        case .markupMenu:
            #expect(EditorDocumentSurface.applyMarkup(verb, in: rig.window))
        case .contextMenu:
            let menu = PlainTextEditor.Coordinator.markupMenu(
                target: rig.coordinator, action: #selector(PlainTextEditor.Coordinator.applyMarkup(_:)))
            guard let item = menu.items.first(where: { $0.title == verb.title }) else {
                Issue.record("the context menu offers no \(verb.title)")
                return
            }
            rig.coordinator.applyMarkup(item)
        case .formatBar:
            let handle = EditorTextViewHandle()
            handle.textView = rig.view
            #expect(handle.applyMarkup(verb))
        }
        spin()
    }

    private func undo(_ rig: Rig) {
        rig.undo.undo()
        spin()
    }

    /// The review's case: "foo", then Bold over the empty selection after it. One ⌘Z takes back the
    /// `****` and leaves "foo"; the typing inside the delimiters is a step of its own too.
    @Test(arguments: Door.allCases)
    func boldAfterTypingIsItsOwnUndoStep(_ door: Door) {
        let rig = rig("")
        defer { withExtendedLifetime(rig.window) {} }
        type("foo", in: rig)
        apply(.bold, through: door, in: rig)
        #expect(rig.view.string == "foo****")
        #expect(rig.view.selectedRange() == NSRange(location: 5, length: 0))
        type("bar", in: rig)
        #expect(rig.view.string == "foo**bar**")

        undo(rig)
        #expect(rig.view.string == "foo****", "⌘Z did not take back the typing inside the delimiters alone")
        undo(rig)
        #expect(rig.view.string == "foo", "⌘Z took the typing before Bold back with it")
        undo(rig)
        #expect(rig.view.string == "")
        #expect(!rig.undo.canUndo, "something else was recorded with the typing")
    }

    /// **The other boundary: typing straight on from the END of what a verb inserted.** A rule
    /// leaves the caret after its own `---` line, so the next keystroke lands exactly where the
    /// insertion stopped — the one place typing would extend the verb's step rather than start one.
    @Test(arguments: Door.allCases)
    func typingStraightAfterARuleIsItsOwnUndoStep(_ door: Door) {
        let rig = rig("A paragraph.")
        defer { withExtendedLifetime(rig.window) {} }
        type("!", in: rig)
        apply(.horizontalRule, through: door, in: rig)
        #expect(rig.view.string == "A paragraph.!\n\n---\n")
        #expect(rig.view.selectedRange() == NSRange(location: 19, length: 0))
        type("Next", in: rig)

        undo(rig)
        #expect(rig.view.string == "A paragraph.!\n\n---\n", "⌘Z took the rule back with the typing after it")
        undo(rig)
        #expect(rig.view.string == "A paragraph.!", "⌘Z took the typing before the rule back with it")
        undo(rig)
        #expect(rig.view.string == "A paragraph.")
        #expect(!rig.undo.canUndo)
    }
}
