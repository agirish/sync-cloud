import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// The rules that put the rail's outline back where it was, and stop it moving under the reader
/// once it is there.
@Suite struct EditorOutlineScrollTests {

    private func outline(_ lines: [Int]) -> [MarkdownOutlineEntry] {
        lines.map { MarkdownOutlineEntry(line: $0, level: 2, depth: 1, title: "Heading \($0)") }
    }

    // MARK: Restoring the anchor

    /// The remembered heading, else the nearest survivor (edits renumber or remove lines), the one
    /// above on a tie (keeping the reader's section on screen); nothing remembered or nothing to
    /// scroll leaves it alone.
    @Test(arguments: [
        (remembered: 40, lines: [1, 20, 40, 60], target: 40),   // still there: exactly
        (remembered: 40, lines: [1, 20, 44, 90], target: 44),   // gone: the nearest survivor
        (remembered: 40, lines: [1, 20, 90], target: 20),
        (remembered: 30, lines: [20, 40], target: 20),          // equidistant: the one above
        (remembered: nil, lines: [1, 2], target: nil),
        (remembered: 40, lines: [], target: nil),
    ] as [(remembered: Int?, lines: [Int], target: Int?)])
    func theRestoreTarget(_ c: (remembered: Int?, lines: [Int], target: Int?)) {
        #expect(EditorOutlineScroll.restoreTarget(remembered: c.remembered, outline: outline(c.lines)) == c.target)
    }

    // MARK: The caret's heading, when the anchor would hide it

    /// The remembered anchor opens the list unless it would leave the caret's heading past the
    /// fold, above or below; then the caret's heading wins, since a marked row nobody can see is
    /// no use.
    @Test(arguments: [
        // Anchored at the top, five rows on screen, caret in the last heading: off the fold.
        (remembered: 2, current: 20, lines: Array(stride(from: 2, through: 20, by: 2)), fit: 5, target: 20),
        // Off the top counts too, which a naive "further down than the anchor" check misses.
        (remembered: 18, current: 2, lines: Array(stride(from: 2, through: 20, by: 2)), fit: 3, target: 2),
        // The anchor already shows the caret's heading.
        (remembered: 2, current: 8, lines: Array(stride(from: 2, through: 20, by: 2)), fit: 5, target: 2),
        // `nil` from `MarkdownOutline.currentEntry` (text above the first heading) moves nothing.
        (remembered: 4, current: nil, lines: [2, 4, 6], fit: 1, target: 4),
        // With no anchor the list starts at the top, so a caret past the fold still moves it.
        (remembered: nil, current: 12, lines: [2, 4, 6, 8, 10, 12], fit: 3, target: 12),
        (remembered: nil, current: 4, lines: [2, 4, 6, 8, 10, 12], fit: 3, target: nil),
    ] as [(remembered: Int?, current: Int?, lines: [Int], fit: Int, target: Int?)])
    func theOpeningTarget(_ c: (remembered: Int?, current: Int?, lines: [Int], fit: Int, target: Int?)) {
        #expect(EditorOutlineScroll.openingTarget(remembered: c.remembered, current: c.current,
                                                  outline: outline(c.lines), rowsThatFit: c.fit) == c.target)
    }

    // MARK: How many rows are on screen

    /// Floored, and never below one: rounding up would call a half-hidden heading at the bottom
    /// visible.
    @Test func theRowCountFloorsAndNeverReturnsZero() {
        let scale: CGFloat = 1
        let row = EditorOutlineScroll.rowHeight(scale: scale)
        #expect(EditorOutlineScroll.rowsThatFit(height: row * 4.9, scale: scale) == 4)
        #expect(EditorOutlineScroll.rowsThatFit(height: 0, scale: scale) == 1)
    }

    /// The same eight rows at every text size, so it counts rows, not points.
    @Test func theRowCountHoldsItsRowsAcrossTheTextRange() {
        for scale in FontSize.allCases.map(\.scale) {
            let height = EditorOutlineScroll.rowHeight(scale: scale) * 8
            #expect(EditorOutlineScroll.rowsThatFit(height: height, scale: scale) == 8,
                    "eight rows' worth of height held \(EditorOutlineScroll.rowsThatFit(height: height, scale: scale)) at scale \(scale)")
        }
    }

    // MARK: Recording where the reader left it

    /// Only a report of the reader's doing is recorded: rows between a file opening and its parse
    /// returning belong to nothing, and without a path there is nothing to key an anchor by.
    @Test(arguments: [
        (path: "/a/one.md", empty: false, top: 20, records: true),
        (path: nil, empty: false, top: 20, records: false),
        (path: "/a/one.md", empty: true, top: 20, records: false),
        (path: "/a/one.md", empty: false, top: nil, records: false),
    ] as [(path: String?, empty: Bool, top: Int?, records: Bool)])
    func onlyTheReadersReportIsRecorded(_ c: (path: String?, empty: Bool, top: Int?, records: Bool)) {
        #expect(EditorOutlineScroll.recordsAnchor(path: c.path, outlineIsEmpty: c.empty, top: c.top) == c.records)
    }
}
