import AppKit
import PDFKit

/// The one rule for a menu chord that is also a text-editing key.
///
/// A menu key equivalent outranks the field editor: AppKit offers the keystroke to the menu before
/// the responder chain, so ⌘A, ⌘X, ⌘C, ⌘V or ⌘⌫ on a menu item would take that key from every text
/// field in the app. With files selected, ⌘C over a caret would copy files. Every such chord routes
/// through here, `DeleteSelectionCommand`'s ⌘⌫ included.
///
/// The test is the first responder, not the focused SwiftUI view: while any field holds the caret,
/// the first responder is the shared field editor, an `NSTextView`, which `@FocusState` cannot see.
enum TextEditingChord {

    /// Whether the keystroke belongs to text being edited rather than to a file action.
    ///
    /// Static and injectable so the rule is testable without a window: the live check reads
    /// `NSApp.keyWindow?.firstResponder`, which a unit test has none of.
    static func belongsToTextEditor(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    /// Runs `fileAction`, unless the caret owns the keystroke, in which case `editorAction` hands it
    /// back to the field editor. Handing it back is not optional: swallowing it would leave ⌘C in a
    /// text field doing nothing at all.
    ///
    /// Decides through ``belongsToTextEditor(_:)`` so the tests pin the rule the app runs. If that
    /// predicate ever widens past `NSTextView`, the failed downcast falls through to `fileAction`,
    /// the safe side.
    ///
    /// `readerAction` is the PDF reader's half, for the two chords a read-only page answers: ⌘C
    /// copies its selected text and ⌘A selects all of it. A reader never runs the file action: with
    /// `nil` (Cut, Paste, ⌘⌫, the transfers, ⌘↑ / ⌘↓) the keystroke gets `readerRefusal`, a beep.
    /// Otherwise ⌘X over a page would cut the open PDF itself, and ⌘⌫ would offer to delete it.
    static func route(responder: NSResponder?,
                      editorAction: (NSTextView) -> Void,
                      readerAction: ((PDFView) -> Void)? = nil,
                      readerRefusal: () -> Void = { NSSound.beep() },
                      fileAction: () -> Void) {
        if belongsToTextEditor(responder), let editor = responder as? NSTextView {
            editorAction(editor)
        } else if let reader = enclosingReader(of: responder) {
            if let readerAction { readerAction(reader) } else { readerRefusal() }
        } else {
            fileAction()
        }
    }

    /// The reader `responder` is, or is inside. Fill & Sign's overlay holds the keyboard while its
    /// toolbar is up and is a view inside the reader, so matching only the reader itself would send
    /// ⌘C there to the pane's selected file. A field editor never reaches this; the caret's branch
    /// takes it first.
    static func enclosingReader(of responder: NSResponder?) -> PDFView? {
        var view = responder as? NSView
        while let current = view {
            if let reader = current as? PDFView { return reader }
            view = current.superview
        }
        return nil
    }

    /// The view holding the keyboard, when it has a selection of its own to copy: Edit's Preview,
    /// whose words are SwiftUI selectable text, neither an `NSTextView` nor a reader. Without this,
    /// ⌘C there would copy the open file instead of the highlighted words.
    ///
    /// Asked through the responder's own `validateMenuItem(_:)`, which says yes only while something
    /// is selected. A view that can copy but cannot say whether it would is left to the file half.
    static func selectionCopier(of responder: NSResponder?) -> NSView? {
        guard let view = responder as? NSView, view.responds(to: copyAction) else { return nil }
        let item = NSMenuItem(title: "Copy", action: copyAction, keyEquivalent: "c")
        return (view as AnyObject).validateMenuItem?(item) == true ? view : nil
    }

    private static let copyAction = #selector(NSText.copy(_:))

    /// ⌘C's file half: the words selected in Preview if there are any, else `fileAction`.
    @MainActor
    static func copySelection(orElse fileAction: () -> Void) {
        if let view = selectionCopier(of: NSApp.keyWindow?.firstResponder) {
            NSApp.sendAction(copyAction, to: view, from: nil)
        } else {
            fileAction()
        }
    }

    /// The live form: reads the key window's first responder for you.
    @MainActor
    static func route(editorAction: (NSTextView) -> Void,
                      readerAction: ((PDFView) -> Void)? = nil,
                      fileAction: () -> Void) {
        route(responder: NSApp.keyWindow?.firstResponder,
              editorAction: editorAction, readerAction: readerAction, fileAction: fileAction)
    }
}
