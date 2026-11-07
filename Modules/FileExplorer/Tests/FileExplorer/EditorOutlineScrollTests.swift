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

    @Test func aRememberedHeadingThatStillExistsIsRestoredExactly() {
        let target = EditorOutlineScroll.restoreTarget(remembered: 40, outline: outline([1, 20, 40, 60]))
        #expect(target == 40)
    }

    /// The remembered value is a source line, and edits renumber or remove lines, so a missing
    /// heading resolves to the nearest survivor rather than refusing to move.
    @Test func aRememberedHeadingThatHasGoneResolvesToTheNearestSurvivor() {
        #expect(EditorOutlineScroll.restoreTarget(remembered: 40,
                                                  outline: outline([1, 20, 44, 90])) == 44)
        #expect(EditorOutlineScroll.restoreTarget(remembered: 40,
                                                  outline: outline([1, 20, 90])) == 20)
    }

    /// Equidistant, the earlier line wins, keeping the reader's section on screen rather than
    /// starting them below it.
    @Test func anAnchorBetweenTwoHeadingsTakesTheOneAbove() {
        #expect(EditorOutlineScroll.restoreTarget(remembered: 30,
                                                  outline: outline([20, 40])) == 20)
    }

    @Test func nothingRememberedAndNothingToScrollBothMeanLeaveItAlone() {
        #expect(EditorOutlineScroll.restoreTarget(remembered: nil, outline: outline([1, 2])) == nil)
        #expect(EditorOutlineScroll.restoreTarget(remembered: 40, outline: []) == nil)
    }

    // MARK: The caret's heading, when the anchor would hide it

    /// The remembered anchor opens the list unless it would leave the caret's heading past the
    /// fold; then the caret's heading wins, since a marked row nobody can see is no use.
    @Test func aCaretHeadingBelowTheFoldBeatsTheRememberedAnchor() {
        let rows = outline([2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
        // Anchored at the top, five rows on screen, caret in the last heading — off the fold.
        #expect(EditorOutlineScroll.openingTarget(remembered: 2, current: 20,
                                                  outline: rows, rowsThatFit: 5) == 20)
    }

    /// Off the top counts too: an anchor deep in a long document with the caret in the first
    /// heading hides the mark above the list. A naive "further down than the anchor" check misses it.
    @Test func aCaretHeadingAboveTheAnchorAlsoWins() {
        let rows = outline([2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
        #expect(EditorOutlineScroll.openingTarget(remembered: 18, current: 2,
                                                  outline: rows, rowsThatFit: 3) == 2)
    }

    @Test func aCaretHeadingTheAnchorAlreadyShowsLeavesTheAnchorAlone() {
        let rows = outline([2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
        #expect(EditorOutlineScroll.openingTarget(remembered: 2, current: 8,
                                                  outline: rows, rowsThatFit: 5) == 2)
    }

    /// `nil` from `MarkdownOutline.currentEntry` (text above the first heading) moves nothing.
    @Test func aCaretInNoSectionLeavesTheAnchorAlone() {
        let rows = outline([2, 4, 6])
        #expect(EditorOutlineScroll.openingTarget(remembered: 4, current: nil,
                                                  outline: rows, rowsThatFit: 1) == 4)
    }

    /// With no anchor the list starts at the top, so a caret past the fold still moves it.
    @Test func withNoAnchorTheListStillOpensOnACaretPastTheFold() {
        let rows = outline([2, 4, 6, 8, 10, 12])
        #expect(EditorOutlineScroll.openingTarget(remembered: nil, current: 12,
                                                  outline: rows, rowsThatFit: 3) == 12)
        #expect(EditorOutlineScroll.openingTarget(remembered: nil, current: 4,
                                                  outline: rows, rowsThatFit: 3) == nil)
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

    @Test func anOpenDocumentWithRowsAndATopRowRecordsItsPosition() {
        #expect(EditorOutlineScroll.recordsAnchor(path: "/a/one.md", outlineIsEmpty: false, top: 20))
    }

    /// Reports that aren't the reader's doing: rows between a file opening and its parse
    /// returning belong to nothing, and without a path there is nothing to key an anchor by.
    @Test func aReportThatIsNotTheReadersDoingIsNotRecorded() {
        #expect(!EditorOutlineScroll.recordsAnchor(path: nil, outlineIsEmpty: false, top: 20))
        #expect(!EditorOutlineScroll.recordsAnchor(path: "/a/one.md", outlineIsEmpty: true, top: 20))
        #expect(!EditorOutlineScroll.recordsAnchor(path: "/a/one.md", outlineIsEmpty: false, top: nil))
    }
}
