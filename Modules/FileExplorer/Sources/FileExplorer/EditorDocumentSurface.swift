import AppKit
import Events

/// Whether the caret is in the editor's document, asked from outside the editor.
///
/// `TextEditingChord`'s test, first responder `is NSTextView`, is right for the clipboard but wrong
/// for anything aimed at the open document: every `NSTextField` being typed into hands its caret to
/// an `NSTextView` field editor, so ⌘F would open the document's find bar from a pane's search box.
/// So the editor marks its own scroll view, and this walks up from the responder to that mark.
/// Walking up keeps the find bar working, since its fields' editors live inside the same scroll view.
public enum EditorDocumentSurface {

    /// The mark ``PlainTextEditor`` puts on its scroll view. An identifier, not a reference to the
    /// text view: cheap to compare, and nothing to keep alive or clear when the editor goes away.
    public static let identifier = NSUserInterfaceItemIdentifier("SyncCloud.editorDocumentSurface")

    /// The editor's text view when the caret is somewhere inside it, or `nil` for every other
    /// responder, including the field editors that `responder is NSTextView` would accept.
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

    /// The editor's text view when the caret is in the text itself, `nil` anywhere else,
    /// including the find bar's fields.
    ///
    /// The narrower test, for verbs that change the buffer. ⌘F in the find bar should still mean
    /// the document, but a Bold there must not: it would wrap whatever the document has selected,
    /// text nobody is looking at.
    @MainActor
    public static func caretTextView(in window: NSWindow?) -> NSTextView? {
        guard let view = focusedTextView(in: window),
              window?.firstResponder === view else { return nil }
        return view
    }

    /// The document's text view when the caret is in it and the file takes Markup: what ⌘I asks
    /// before it means Italic. In a `.txt` the key opens the inspector, as wherever the verbs
    /// don't apply.
    @MainActor
    public static func markupTextView(in window: NSWindow?) -> NSTextView? {
        guard let view = caretTextView(in: window), acceptsMarkup(view) else { return nil }
        return view
    }

    /// Whether `view`'s document is one the Markup verbs write into: a Markdown file. Editable
    /// Preview is Markdown by construction; a text view this app didn't build is assumed to be.
    @MainActor
    static func acceptsMarkup(_ view: NSTextView) -> Bool {
        (view.delegate as? PlainTextEditor.Coordinator)?.isMarkdownDocument ?? true
    }

    /// Opens the find bar over the document, if the caret is in it.
    ///
    /// - Returns: `false` when the caret is elsewhere, so the caller can fall through to what the
    ///   chord means outside the editor.
    @MainActor
    @discardableResult
    public static func showFindBar(in window: NSWindow?) -> Bool {
        guard let view = focusedTextView(in: window) else { return false }
        PlainTextEditor.showFindBar(in: view)
        return true
    }

    /// Runs one of the find bar's actions (Find Next, Use Selection for Find) over the document,
    /// if the caret is in it or in the bar. The walk-up test, since Find Next from inside the Find
    /// field is the ordinary way to step through matches.
    ///
    /// - Returns: `false` when the caret is outside the editor, so the item searches nothing
    ///   the reader isn't in.
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
    /// Refuses everywhere else, including the find bar (``caretTextView(in:)``). The menu item is
    /// enabled whenever Edit shows a document, since it can't know where the caret is when it
    /// draws; this is where that is asked. The caller logs the refusal, so the chord never fails
    /// silently.
    ///
    /// - Returns: `false` when the caret is not in the document. `true` whenever it was aimed
    ///   right, even if the verb had nothing to do: an inline verb on an empty selection inserts
    ///   its delimiters, and a heading on a heading takes it off.
    @MainActor
    @discardableResult
    public static func applyMarkup(_ verb: MarkupVerb, in window: NSWindow?) -> Bool {
        guard let view = caretTextView(in: window), view.isEditable else { return false }
        // Not in a file that isn't Markdown, or ⌘B would write `****` into a `.yaml`. The menu
        // bar greys the items there; this is the rule under every door, ⌘I's included.
        guard acceptsMarkup(view) else {
            Logger.shared.info("Markup ▸ \(verb.title) did nothing: the open file is not Markdown")
            return true
        }
        // Editable Preview: the verb is translated into the source like any edit there.
        if let preview = view as? PreviewTextView {
            preview.performMarkup(verb)
            return true
        }
        // Asked before the press, which would refuse on it: the menu bar's items cannot know where
        // the caret is when they draw, so the ones that would break a table stay enabled there.
        let breaks = MarkdownEdits.breaksTable(verb, in: view.string, selection: view.selectedRange())
        if !PlainTextEditor.apply(verb, to: view) {
            if breaks, verb.wrapsWords {
                // The format bar greys these too: across cells a mark breaks the table.
                Logger.shared.info("Markup ▸ \(verb.title) did nothing: the selection runs across a table's cells, and a mark wraps words inside one")
            } else if breaks, !MarkdownTables.touches(view.string as NSString, view.selectedRange()) {
                // The paragraph runs straight into a table the list or quote would swallow.
                Logger.shared.info("Markup ▸ \(verb.title) did nothing: the line runs straight into a table, which a list or quote here would take in as its text — put a blank line between them first")
            } else if breaks {
                // The format bar greys these; a press from the menu bar says why instead.
                Logger.shared.info("Markup ▸ \(verb.title) did nothing: the selection is in a table, and it would take the table's lines out of it")
            } else if case .table(let op) = verb {
                // The Table items can't know where the caret is when the menu draws; one with
                // nothing to do says why.
                Logger.shared.info("Markup ▸ \(verb.title) did nothing: "
                                   + MarkdownTables.refusal(op, in: view.string as NSString, selection: view.selectedRange()))
            }
        }
        return true
    }
}
