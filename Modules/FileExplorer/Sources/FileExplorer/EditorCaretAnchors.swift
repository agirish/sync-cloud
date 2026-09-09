import Foundation

/// Where the caret was, per file — so a workspace switch gives the document back at the line
/// somebody was reading rather than at the top.
///
/// **The defect this exists to close.** `PlainTextEditor` is an `NSViewRepresentable`, and the text
/// view it makes is destroyed with the workspace: ⌘1 and back rebuilds it, `makeNSView` assigns
/// `view.string = text` into a brand-new text storage, and a fresh `NSTextView` selects
/// `{0, 0}` and scrolls to the top. The buffer, the file, the undo stack and the mode all survive —
/// they were moved above the view long ago — so what the reader loses is only their PLACE, which is
/// the one thing that made the switch feel like the app forgetting what they were doing.
///
/// **Not `@Published`, and not `@State` anywhere.** The caret moves on every arrow key, every click
/// and every keystroke. Announcing that would re-render whatever observed it at typing speed — and
/// putting a window re-render back onto the typing path is precisely the cost
/// ``EditorBuffer`` was split out of ``EditorDocument`` to remove. A plain reference type written
/// through is free: nothing observes it, so nothing invalidates, and the value is simply there when
/// the next `makeNSView` asks. ``EditorBuffer/textVersion`` declines to publish for the same reason.
///
/// **Held by the document**, so it inherits the lifetime the document's own doc comment establishes:
/// it outlives a workspace teardown and it outlives the window. Keyed by path rather than kept as
/// one value, so the anchors do not become "wherever the caret was in whichever file was last open"
/// — the same shape ``EditorUndoStore`` keys by, and `ContentView.editorOutlineAnchors` before it.
///
/// Unbounded, like `editorOutlineAnchors`: an entry is a path and an `Int`, and a session would have
/// to open tens of thousands of files for that to be worth a policy. If it ever is,
/// ``EditorUndoStore/forgetMissingFiles()`` is the shape to copy.
@MainActor
public final class EditorCaretAnchors {

    public init() {}

    private var offsets: [String: Int] = [:]

    /// Remembers where the caret is in `path`. A nil path is nothing open, and is not recorded.
    public func remember(_ offset: Int, for path: String?) {
        guard let path else { return }
        offsets[path] = max(0, offset)
    }

    /// Where the caret was in `path`, or **nil for a file this session has never put a caret in**.
    ///
    /// **Optional, and 0 is a real answer rather than the absent one.** Conflating them is a defect
    /// this returned as an `Int` for exactly one test run: a reader sitting at the top of a file has
    /// an anchor of 0, and a caller that treats 0 as "nothing recorded" declines to restore it —
    /// which, given what a fresh `NSTextView` does (see ``PlainTextEditor/restoreCaret(to:in:text:)``),
    /// hands them back the file with the caret at the END. The one position a reader is most likely
    /// to be in was the one position the restore skipped.
    ///
    /// **Clamping is the CALLER's**, and deliberately so: the anchor is a UTF-16 offset into the
    /// text as it stood when it was recorded, and the file can be shorter by the time it is asked
    /// for — edited in another app, reverted, or truncated. Only the caller holds the string the
    /// offset has to be valid in, so only the caller can bound it. Handing back an offset past the
    /// end of a buffer is what `NSRangeException` is made of.
    public func offset(for path: String?) -> Int? {
        guard let path else { return nil }
        return offsets[path]
    }

    /// Drops one file's anchor.
    public func forget(_ path: String) {
        offsets.removeValue(forKey: path)
    }

    /// A caret offset bounded to a string it must be valid in — the clamp `offset(for:)` refuses to
    /// guess at.
    ///
    /// Static and non-private so the rule can be tested without an `NSTextView`: "the caret does not
    /// land past the end of a file that shrank" is a claim about arithmetic, and mounting AppKit to
    /// check arithmetic tests the wrong thing.
    ///
    /// Measured in UTF-16 code units because that is what `NSRange` and `NSTextView` count in — the
    /// same currency `EditorScrollRequest`'s offsets are resolved into.
    public static func clamped(_ offset: Int, in text: String) -> Int {
        min(max(0, offset), (text as NSString).length)
    }
}
