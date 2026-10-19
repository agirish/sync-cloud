import AppKit
import PDFKit

/// The one rule for a menu chord that is also a text-editing key.
///
/// **A menu key equivalent outranks the field editor.** AppKit offers the keystroke to the menu
/// before the responder chain sees it, so registering ⌘A, ⌘X, ⌘C, ⌘V or ⌘⌫ on a menu item takes
/// that key away from every text field in the app — the pane search, a rename field, the
/// differences search, the ⌘K field. With files selected, which is the normal state, ⌘C over a
/// caret would copy *files* and leave the typist wondering why nothing was on the pasteboard.
///
/// This is not hypothetical and not new: `DeleteSelectionCommand` has carried exactly this routing
/// for ⌘⌫ since it was registered, because ⌘⌫ is also NSText's delete-to-beginning-of-line and
/// Finder ships that wart. What is new is that four more chords need it at once, so the rule moves
/// here rather than being copied five times — and it moves *before* §3's ⌘↑ / ⌘↓ arrive, which
/// need it too. That ordering is why the menu bar is order step 5 and the chords are step 6.
///
/// **The test is the first responder, not the focused SwiftUI view.** Whenever any text field holds
/// the caret, AppKit's first responder is the shared field editor — an `NSTextView` — regardless of
/// which SwiftUI view owns the field. `@FocusState` cannot see that, which is the whole reason this
/// reads the responder directly.
enum TextEditingChord {

    /// Whether the keystroke belongs to text being edited rather than to a file action.
    ///
    /// Static and injectable so the rule is testable without a window: the live check reads
    /// `NSApp.keyWindow?.firstResponder`, which a unit test has none of.
    static func belongsToTextEditor(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    /// Runs `fileAction`, unless the caret owns the keystroke — in which case `editorAction` hands
    /// it back to the field editor it was taken from.
    ///
    /// **Handing it back is not optional.** Swallowing the keystroke would be worse than the
    /// collision it avoids: ⌘C in a text field would silently do nothing at all, which reads as the
    /// app being broken rather than as a chord being busy.
    ///
    /// Decides through ``belongsToTextEditor(_:)`` rather than an inline cast: the predicate used
    /// to be a parallel copy nothing shipped called, so the tests naming it pinned a rule the app
    /// did not run. If the predicate ever widens past "is an NSTextView", the failed downcast falls
    /// through to `fileAction` — the safe side, since only a real text view can take the hand-back.
    ///
    /// **`readerAction` is the PDF reader's half**, for the two chords a read-only page answers:
    /// ⌘C copies the text selected on it and ⌘A selects all of it. The reader is a `PDFView`, not an
    /// `NSTextView`, so without it those two went to the FILE action — the pane's selected rows,
    /// which in Edit is usually the open PDF itself.
    ///
    /// **A reader never runs the file action, half or no half.** With `nil` (Cut, Paste, ⌘⌫, the
    /// transfers, ⌘↑ / ⌘↓) the keystroke is refused with `readerRefusal` — a beep, AppKit's answer to
    /// a command that does not apply. It used to fall through to the file side, so ⌘X over a page cut
    /// the open PDF onto the file clipboard, ⌘V pasted files into its folder and ⌘⌫ offered to
    /// delete it: verbs about the pane's rows, fired from a page that was showing none of them.
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

    /// The reader `responder` is, or is inside — **Fill & Sign's overlay holds the keyboard over
    /// the pages while its toolbar is up**, and is a view inside the reader, not one; matched only
    /// as itself, ⌘C there copied the pane's selected file again. A field editor never reaches
    /// this: the caret's branch above takes it first.
    static func enclosingReader(of responder: NSResponder?) -> PDFView? {
        var view = responder as? NSView
        while let current = view {
            if let reader = current as? PDFView { return reader }
            view = current.superview
        }
        return nil
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
