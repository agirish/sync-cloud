import Foundation

/// A request from the host to bring one row of a pane into view: a row selected on the user's
/// behalf (the document Edit opened, Reveal in Browse's target) can be far off screen. The same
/// scroll as the search reveal (`searchRevealNonce`), for a path the host names.
///
/// The token makes a repeat a new request: a bare path would compare equal, so `.onChange` would
/// never fire for it.
///
/// Answered once. The pane acts on arrival, or on appearing if it was hidden or unmounted, and
/// only while the named rows are the pane's whole selection (`FileTreeView.revealsRow`). It then
/// tells the host (`FileTreeView.onRowRevealed`), which retires it; left standing, it would jump
/// the pane back on every appearance. The host also retires it once the selection moves off, so a
/// remount can't scroll back to a file the user left.
public struct PaneRowReveal: Equatable, Sendable {
    /// The row's path — a `FileNode.id`.
    public let path: String
    /// Distinguishes this request from the last one for the same path.
    public let token: Int
    /// The whole selection the request was made with: `[path]`, except a PDF batch's Reveal in
    /// Browse, which selects all the copies and scrolls to the first (`path`). Acted on only while
    /// this set is the selection.
    public let selection: Set<String>

    public init(path: String, token: Int, selection: Set<String>? = nil) {
        self.path = path
        self.token = token
        self.selection = selection ?? [path]
    }
}
