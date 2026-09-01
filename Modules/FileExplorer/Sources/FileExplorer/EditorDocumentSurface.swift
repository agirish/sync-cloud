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
}
