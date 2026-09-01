import Foundation

/// A request to bring a source line into view, carrying a token so the same line can be asked for
/// twice.
///
/// **The token is not decoration.** Clicking the same outline row twice is two requests for one
/// line, and a plain `Int` would be unchanged between them — so the second click, the one somebody
/// makes precisely because they have scrolled away since the first, would do nothing. Same shape as
/// `EditorFileRailView.namingFocus`, and for the same reason.
///
/// Read by both surfaces: ``PlainTextEditor/scrollRequest`` moves the caret, and
/// ``MarkdownPreview/scrollRequest`` scrolls the rendered document.
struct EditorScrollRequest: Equatable {
    /// 1-based, matching ``MarkdownBlock/line``.
    var line: Int
    var token: Int
}
