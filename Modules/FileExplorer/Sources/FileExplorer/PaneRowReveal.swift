import Foundation

/// A request, from the host, to bring one row of a pane into view (TE47).
///
/// **Why a pane needs to be told.** A row selected by a click is already where the pointer is; a row
/// selected on the user's behalf — the document Edit just opened, the file Reveal in Browse is
/// pointing at — can be the 140th of a long folder, highlighted and entirely off screen. The pane
/// has one other reveal, the search walk's, and it is keyed to the search (`searchRevealNonce`):
/// this is the same scroll, asked for a path the host names rather than a hit the pane found.
///
/// **The token is what makes a repeat a request.** Opening the same file twice asks twice, and a
/// bare path would compare equal the second time, so `.onChange` would never fire for it — the
/// reason the search reveal moved to a nonce as well.
///
/// **A request, answered once.** The pane acts on it when it arrives, or — if it was folded away
/// or not yet mounted then — when it appears, and in both cases only while the row it names is the
/// pane's whole selection (`FileTreeView.revealsRow`). Having acted, it tells the host
/// (`FileTreeView.onRowRevealed`), which retires it: left standing, it was answered again on every
/// appearance while the row stayed selected, and the pane jumped back to the document after every
/// scroll-away and Browse-and-back. The host also retires it the moment the selection moves off
/// that row, so a remount cannot scroll the pane back to a file the user has walked away from.
public struct PaneRowReveal: Equatable, Sendable {
    /// The row's path — a `FileNode.id`.
    public let path: String
    /// Distinguishes this request from the last one for the same path.
    public let token: Int

    public init(path: String, token: Int) {
        self.path = path
        self.token = token
    }
}
