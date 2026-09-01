import Foundation
import CoreGraphics
import Design

/// Where the rail's outline should be scrolled to when it comes back.
///
/// **The outline is rebuilt from nothing more often than it looks.** Switching to Text Files and
/// back destroys the `ScrollView` along with its position, and so does opening another file:
/// `EditorWorkspaceView` clears `outline` the instant the path changes and the parse refills it
/// 150ms later, off the main actor. Without something to put it back, a thirty-heading document
/// returns to the top every time anyone glances at the file list.
///
/// **Two rules, both resolved in one pass, and that is a correctness property rather than tidiness.**
/// The first draft asked the scroll view which rows were visible and revealed the caret's heading
/// from that callback. It could not be verified: an offscreen `NSHostingView` performs the first
/// update and then nothing — a scroll issued from a later turn, by binding or by
/// `ScrollViewProxy`, never lands, so the mount test could not tell a working reveal from a dead
/// one. Deciding both rules at restore time, before the list is on screen, puts the whole decision
/// somewhere a test can watch it — and removes the one-shot flag the callback version needed to
/// stop it dragging the list back to the caret every time the reader scrolled away.
enum EditorOutlineScroll {

    /// The row to restore for `remembered`, or `nil` to leave the list where it is.
    ///
    /// **The remembered value is a source line, and source lines move.** `MarkdownOutlineEntry.id`
    /// is the line the heading sits on, the outline is re-derived on every keystroke, and typing a
    /// paragraph above a heading renumbers it — so the exact id is often gone by the time anyone
    /// comes back, and a heading deleted while away is gone for good. The nearest surviving line is
    /// what "roughly where I was" means in a list whose rows are positions in a document.
    ///
    /// Ties go to the earlier line: with an anchor equidistant between two headings, the one above
    /// keeps the section the reader was looking at on screen rather than starting below it.
    static func restoreTarget(remembered: Int?, outline: [MarkdownOutlineEntry]) -> Int? {
        guard let remembered, !outline.isEmpty else { return nil }
        if outline.contains(where: { $0.id == remembered }) { return remembered }
        return outline.map(\.id).min { a, b in
            let (da, db) = (abs(a - remembered), abs(b - remembered))
            return da == db ? a < b : da < db
        }
    }

    /// The row the outline should actually open at: the remembered anchor, unless that would leave
    /// the heading the caret is in off the bottom or off the top, in which case the caret's heading
    /// wins.
    ///
    /// **A marked row nobody can see is the failure the mark exists to prevent.** The rail bolds the
    /// heading the caret is inside; restoring an anchor from a different part of a long document
    /// leaves that bold row somewhere past the fold, which is worse than not marking it at all.
    ///
    /// - Parameters:
    ///   - remembered: the anchor for this document, already resolved by ``restoreTarget(remembered:outline:)``.
    ///     `nil` for a document nobody has scrolled — the list would start at the top, so the rule
    ///     still applies and a caret past the fold still wins.
    ///   - current: the row the caret is inside. `nil` above the first heading, which is a real
    ///     answer and not a fallback (see ``MarkdownOutline/currentEntry(forLine:in:)``) and is not
    ///     a reason to move anything.
    ///   - rowsThatFit: how many rows the section shows at once — see ``rowsThatFit(height:scale:)``.
    static func openingTarget(remembered: Int?, current: Int?,
                              outline: [MarkdownOutlineEntry], rowsThatFit: Int) -> Int? {
        let anchor = restoreTarget(remembered: remembered, outline: outline)
        guard let current, let currentIndex = outline.firstIndex(where: { $0.id == current }) else {
            return anchor
        }
        // Where the list would start: the anchor's row, or the top when there is no anchor.
        let top = anchor.flatMap { a in outline.firstIndex(where: { $0.id == a }) } ?? 0
        let wouldShow = top..<(top + max(rowsThatFit, 1))
        return wouldShow.contains(currentIndex) ? anchor : current
    }

    /// One outline row's height at the app's text size.
    ///
    /// The same arithmetic the section's old eight-row cap was built from — 11pt type on the type
    /// ramp's own knee curve, its line box, and the row's 3pt of padding top and bottom.
    /// `EditorLayoutTests` measures a rendered row against this, because an estimate that drifts
    /// from the drawn row is an estimate that answers the wrong question about what fits.
    static func rowHeight(scale: CGFloat) -> CGFloat {
        FontSize.scaledPointSize(11, scale: scale) * 1.35 + 6
    }

    /// How many rows a section `height` points tall shows at once.
    ///
    /// **Floored, and never below one.** A partly visible row at the bottom is not one the reader
    /// can be said to be looking at, so rounding up would call a heading visible when half of it is
    /// under the edge — and the whole point of the number is to decide exactly that.
    static func rowsThatFit(height: CGFloat, scale: CGFloat) -> Int {
        max(Int((height / rowHeight(scale: scale)).rounded(.down)), 1)
    }

    /// Whether a reported top row should be written down as this document's anchor.
    ///
    /// **The two reports that are not the reader's doing**, each of which wrote a wrong anchor
    /// before it was excluded: there is no open document to key it by, or the outline is empty —
    /// which is every moment between a file opening and its parse returning, when the scroll view
    /// is reporting about rows that belong to nothing.
    static func recordsAnchor(path: String?, outlineIsEmpty: Bool, top: Int?) -> Bool {
        path != nil && !outlineIsEmpty && top != nil
    }
}
