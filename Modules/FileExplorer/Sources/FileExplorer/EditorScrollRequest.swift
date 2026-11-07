import Foundation

/// A request to bring a source line into view, carrying a token so the same line can be asked for
/// twice.
///
/// Without the token, a second click on the same outline row (made because the reader scrolled
/// away) would leave the value unchanged and do nothing. Same shape as
/// `EditorFileRailView.namingFocus`, for the same reason.
///
/// Read by both surfaces: ``PlainTextEditor/scrollRequest`` moves the caret, and
/// ``MarkdownPreview/scrollRequest`` scrolls the rendered document.
struct EditorScrollRequest: Equatable {
    /// 1-based, matching ``MarkdownBlock/line``.
    var line: Int
    var token: Int
    /// Go to Line's column, 1-based, or `nil` for every other request: a heading jump goes to the
    /// line's start and names a line that exists. With a column the request is typed, so the text
    /// view clamps it to the last line and the line's end; see
    /// ``EditorGoToLine/utf16Offset(of:in:using:)``.
    var column: Int? = nil
    /// How much to select from there, in UTF-16 units: a Contents result's match. `0` for every
    /// other request, which puts a bare caret.
    var length: Int = 0
    /// Whether the selection then becomes Find's search text, with the find bar shown, so ⌘G steps
    /// to the file's next match. A Contents result's request only.
    var seedsFind: Bool = false
}
