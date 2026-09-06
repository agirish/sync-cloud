import AppKit

/// Whether the caret is in the editor's document, asked from outside the editor.
///
/// **The narrow focus test, and it exists because the obvious one is wrong.** `TextEditingChord`
/// routes ⌘X/⌘C/⌘V/⌘A by asking whether the first responder `is NSTextView` — being one is the
/// whole qualification, which is correct for the clipboard because every field editor in the window
/// deserves those four. It is exactly wrong for anything aimed at the OPEN DOCUMENT: a `NSTextView`
/// is also what an `NSTextField` hands its caret to while it is being typed into, so that test is
/// true in the Go-to field, in a pane's search field, in the rail's naming row and in the sidebar's
/// filter. A ⌘F routed on it would open the document's find bar from inside the pane search box.
///
/// So the editor MARKS its own scroll view, and this walks up from the responder looking for that
/// mark. Walking up rather than comparing to the text view directly is what keeps the find bar
/// working: its Find and Replace fields are AppKit's, they live inside the same scroll view, and
/// their field editors are responders in their own right.
public enum EditorDocumentSurface {

    /// The mark ``PlainTextEditor`` puts on its scroll view.
    ///
    /// A view identifier rather than a shared mutable reference to the text view: identifiers are
    /// what AppKit provides for exactly this, they cost nothing to compare, and there is no object
    /// to keep alive or forget to clear when the editor goes away.
    public static let identifier = NSUserInterfaceItemIdentifier("SyncCloud.editorDocumentSurface")

    /// The editor's text view when the caret is somewhere inside it, or `nil` otherwise.
    ///
    /// `nil` for every other responder in the window, including the field editors that
    /// `responder is NSTextView` would accept.
    @MainActor
    public static func focusedTextView(in window: NSWindow?) -> NSTextView? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        var ancestor: NSView? = responder
        while let view = ancestor {
            if view.identifier == identifier {
                return (view as? NSScrollView)?.documentView as? NSTextView
            }
            ancestor = view.superview
        }
        return nil
    }

    /// The editor's text view when the caret is IN THE TEXT ITSELF — `nil` when it is anywhere
    /// else, including the find bar's own fields.
    ///
    /// **The narrower of the two tests, for the verbs that change the buffer.** ``focusedTextView``
    /// walks up so that ⌘F pressed inside the find bar still means the document; a Bold pressed
    /// there must not, because the reader's selection is in the Find field and the verb would
    /// wrap whatever the DOCUMENT happens to have selected instead — an edit to text nobody is
    /// looking at. So the markup verbs ask whether the first responder is the document view, not
    /// merely inside its scroll view.
    @MainActor
    public static func caretTextView(in window: NSWindow?) -> NSTextView? {
        guard let view = focusedTextView(in: window),
              window?.firstResponder === view else { return nil }
        return view
    }

    /// Opens the find bar over the document, if the caret is in it.
    ///
    /// - Returns: `false` when the caret is elsewhere, so the caller can fall through to whatever
    ///   the chord means outside the editor rather than swallowing it.
    @MainActor
    @discardableResult
    public static func showFindBar(in window: NSWindow?) -> Bool {
        guard let view = focusedTextView(in: window) else { return false }
        PlainTextEditor.showFindBar(in: view)
        return true
    }

    /// Runs one of the find bar's own actions — Find Next, Use Selection for Find — over the
    /// document, if the caret is in it or in the bar.
    ///
    /// The walk-up test, deliberately: Find Next from inside the Find field is the ordinary way to
    /// step through matches, and that field's editor is the responder then.
    ///
    /// - Returns: `false` when the caret is outside the editor, so the item does nothing there
    ///   rather than searching a document the reader is not in.
    @MainActor
    @discardableResult
    public static func performFind(_ action: NSTextFinder.Action, in window: NSWindow?) -> Bool {
        guard let view = focusedTextView(in: window) else { return false }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        view.performTextFinderAction(sender)
        return true
    }

    /// Applies a Markup verb to the document's selection, if the caret is in the text.
    ///
    /// **Refuses everywhere else, including the find bar** — see ``caretTextView(in:)``. The menu
    /// item that called this is enabled whenever Edit shows a document, because a menu item cannot
    /// know where the caret is when it renders; this is where that question is finally asked. The
    /// caller logs the refusal, since a chord that does nothing and says nothing is this app's
    /// own named defect.
    ///
    /// - Returns: `false` when the caret is not in the document. `true` whether or not the verb had
    ///   anything to do — an inline verb over an empty selection inserts its delimiters, and a
    ///   heading on a heading takes it off, so "applied" is the answer whenever it was aimed right.
    @MainActor
    @discardableResult
    public static func applyMarkup(_ verb: MarkupVerb, in window: NSWindow?) -> Bool {
        guard let view = caretTextView(in: window), view.isEditable else { return false }
        PlainTextEditor.apply(verb, to: view)
        return true
    }
}
