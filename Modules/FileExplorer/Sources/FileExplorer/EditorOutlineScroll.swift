import Foundation
import CoreGraphics
import Design

/// Where the rail's outline should be scrolled to when it comes back.
///
/// Switching to Text Files and back destroys the `ScrollView` and its position, and so does opening
/// another file: `EditorWorkspaceView` clears `outline` when the path changes and the parse refills
/// it 150 ms later. Without this, a long document's outline returns to the top every time.
///
/// Both rules are decided at restore time, before the list is on screen, so a test can watch the
/// decision: an offscreen `NSHostingView` never lands a scroll issued from a later turn. It also
/// needs no one-shot flag to stop the list dragging back to the caret when the reader scrolls away.
public enum EditorOutlineScroll {

    /// The row to restore for `remembered`, or `nil` to leave the list where it is.
    ///
    /// `MarkdownOutlineEntry.id` is the heading's source line, and typing above a heading
    /// renumbers it, so the exact id is often gone. The nearest surviving line is "roughly where I
    /// was". Ties go to the earlier line, which keeps the reader's section on screen.
    static func restoreTarget(remembered: Int?, outline: [MarkdownOutlineEntry]) -> Int? {
        guard let remembered, !outline.isEmpty else { return nil }
        if outline.contains(where: { $0.id == remembered }) { return remembered }
        return outline.map(\.id).min { a, b in
            let (da, db) = (abs(a - remembered), abs(b - remembered))
            return da == db ? a < b : da < db
        }
    }

    /// The row the outline should open at: the remembered anchor, unless that would leave the
    /// caret's heading off screen, in which case the caret's heading wins. The rail bolds that
    /// heading, and a bold row past the fold is worse than none.
    ///
    /// - Parameters:
    ///   - remembered: the anchor for this document, before ``restoreTarget(remembered:outline:)``
    ///     resolves it. `nil` for a document nobody has scrolled: the list starts at the top, and
    ///     a caret past the fold still wins.
    ///   - current: the row the caret is inside. `nil` above the first heading, a real answer
    ///     (``MarkdownOutline/currentEntry(forLine:in:)``) that moves nothing.
    ///   - rowsThatFit: how many rows the section shows at once (``rowsThatFit(height:scale:)``).
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

    /// The row to bring into view as the reader moves, or `nil` to leave the list alone.
    ///
    /// Find, Go to Line, the arrows or a page turn can move the current row past the fold. The list
    /// follows only then: a row already on screen stays put, so a click in the list never moves
    /// it. As the Pages tab follows its page.
    ///
    /// - Parameters:
    ///   - current: the row the reader is in, or `nil` above the first heading, which moves nothing.
    ///   - top: the row the list reports at its top, or `nil` before it has reported (the top).
    static func followTarget(current: Int?, top: Int?,
                             outline: [MarkdownOutlineEntry], rowsThatFit: Int) -> Int? {
        guard let current, let currentIndex = outline.firstIndex(where: { $0.id == current }) else {
            return nil
        }
        let topIndex = top.flatMap { t in outline.firstIndex(where: { $0.id == t }) } ?? 0
        let shown = topIndex..<(topIndex + max(rowsThatFit, 1))
        return shown.contains(currentIndex) ? nil : current
    }

    /// One outline row's height at the app's text size: 11pt type on the type ramp's knee curve,
    /// its line box, and 3pt of padding top and bottom. `EditorLayoutTests` measures a rendered row
    /// against this, so the estimate can't drift from what is drawn.
    static func rowHeight(scale: CGFloat) -> CGFloat {
        FontSize.scaledPointSize(11, scale: scale) * 1.35 + 6
    }

    /// How many rows a section `height` points tall shows at once. Floored, never below one: a
    /// half-hidden row at the bottom doesn't count as visible.
    static func rowsThatFit(height: CGFloat, scale: CGFloat) -> Int {
        max(Int((height / rowHeight(scale: scale)).rounded(.down)), 1)
    }

    /// Moves an outline's place with its file, when the disk watch follows a note. One map holds
    /// every file's anchor, PDFs' and notes' alike, so only the moved key changes.
    public static func moveAnchor(in anchors: inout [String: Int], from old: String, to new: String) {
        if let anchor = anchors.removeValue(forKey: old) { anchors[new] = anchor }
    }

    /// Whether a reported top row should be written down as this document's anchor. Not when there
    /// is no open document to key it by, or the outline is empty (between a file opening and its
    /// parse returning), since neither report is the reader's doing.
    static func recordsAnchor(path: String?, outlineIsEmpty: Bool, top: Int?) -> Bool {
        path != nil && !outlineIsEmpty && top != nil
    }
}
