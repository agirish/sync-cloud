import Foundation

/// Where the caret was, per file, so a workspace switch gives the document back at the line
/// somebody was reading rather than at the top.
///
/// `PlainTextEditor`'s text view is destroyed with the workspace, and a fresh `NSTextView` selects
/// `{0, 0}` and scrolls to the top. The buffer, file, undo stack and mode all live above the view;
/// this keeps the reader's place too.
///
/// Not `@Published`, and not `@State` anywhere: the caret moves on every key and click, and
/// announcing it would re-render observers at typing speed, the cost ``EditorBuffer`` was split out
/// of ``EditorDocument`` to remove. ``EditorBuffer/textVersion`` declines to publish for the same
/// reason.
///
/// Held by the document, so it outlives a workspace teardown and the window. Keyed by path, like
/// ``EditorUndoStore``. Unbounded: an entry is a path and an `Int`; if that ever matters,
/// ``EditorUndoStore/forgetMissingFiles(fileManager:)`` is the shape to copy.
@MainActor
public final class EditorCaretAnchors {

    public init() {}

    private var offsets: [String: Int] = [:]

    /// Remembers where the caret is in `path`. A nil path is nothing open, and is not recorded.
    public func remember(_ offset: Int, for path: String?) {
        guard let path else { return }
        offsets[path] = max(0, offset)
    }

    /// Where the caret was in `path`, or nil for a file this session has never put a caret in.
    ///
    /// Optional because 0 is a real answer: a reader at the top of a file has an anchor of 0, and a
    /// caller that read 0 as "nothing recorded" would skip the restore and leave the caret where a
    /// fresh `NSTextView` puts it (see ``PlainTextEditor/restoreCaret(to:in:text:)``).
    ///
    /// Clamping is the caller's: the anchor is a UTF-16 offset into the text as it was, and the
    /// file may have shrunk since. Only the caller holds the string it must be valid in, and an
    /// offset past the end of a buffer raises `NSRangeException`.
    public func offset(for path: String?) -> Int? {
        guard let path else { return nil }
        return offsets[path]
    }

    /// Drops one file's anchor.
    public func forget(_ path: String) {
        offsets.removeValue(forKey: path)
    }

    /// Files an anchor under the path its file moved to; the text didn't change, so the offset
    /// still holds.
    public func move(from old: String, to new: String) {
        guard old != new else { return }
        offsets[new] = offsets.removeValue(forKey: old)
    }

    /// A caret offset bounded to a string it must be valid in: the clamp `offset(for:)` leaves to
    /// the caller. Static so the rule is tested without an `NSTextView`. Measured in UTF-16 code
    /// units, which `NSRange` and `NSTextView` count in, like `EditorScrollRequest`'s resolved
    /// offsets.
    public static func clamped(_ offset: Int, in text: String) -> Int {
        min(max(0, offset), (text as NSString).length)
    }
}
