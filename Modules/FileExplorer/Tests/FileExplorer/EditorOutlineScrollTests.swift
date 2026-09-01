import Testing
import SwiftUI
import Design
@testable import FileExplorer

/// The rules that put the rail's outline back where it was — and that stop it moving under the
/// reader's hand once it is there.
@Suite struct EditorOutlineScrollTests {

    private func outline(_ lines: [Int]) -> [MarkdownOutlineEntry] {
        lines.map { MarkdownOutlineEntry(line: $0, level: 2, depth: 1, title: "Heading \($0)") }
    }

    // MARK: Restoring the anchor

    @Test func aRememberedHeadingThatStillExistsIsRestoredExactly() {
        let target = EditorOutlineScroll.restoreTarget(remembered: 40, outline: outline([1, 20, 40, 60]))
        #expect(target == 40)
    }

    /// **The remembered value is a source line, and source lines move.** Typing above a heading
    /// renumbers it and deleting one removes it outright, so the exact id is often gone by the time
    /// anyone comes back — landing near where they were beats refusing to move.
    @Test func aRememberedHeadingThatHasGoneResolvesToTheNearestSurvivor() {
        #expect(EditorOutlineScroll.restoreTarget(remembered: 40,
                                                  outline: outline([1, 20, 44, 90])) == 44)
        #expect(EditorOutlineScroll.restoreTarget(remembered: 40,
                                                  outline: outline([1, 20, 90])) == 20)
    }

    /// Equidistant, the earlier line wins: it keeps the section the reader was looking at on screen
    /// rather than starting them below it.
    @Test func anAnchorBetweenTwoHeadingsTakesTheOneAbove() {
        #expect(EditorOutlineScroll.restoreTarget(remembered: 30,
                                                  outline: outline([20, 40])) == 20)
    }

    @Test func nothingRememberedAndNothingToScrollBothMeanLeaveItAlone() {
        #expect(EditorOutlineScroll.restoreTarget(remembered: nil, outline: outline([1, 2])) == nil)
        #expect(EditorOutlineScroll.restoreTarget(remembered: 40, outline: []) == nil)
    }

    // MARK: The caret's heading, when the anchor would hide it

    /// His decision, in one function: the remembered anchor opens the list, unless it would leave
    /// the heading the caret is in past the fold — then that wins. A marked row nobody can see is
    /// the failure the mark exists to prevent.
    @Test func aCaretHeadingBelowTheFoldBeatsTheRememberedAnchor() {
        let rows = outline([2, 4, 6, 8, 10, 12, 14, 16, 18, 20])
        // Anchored at the top, five rows on screen, caret in the last heading — off the fold.
        #expect(EditorOutlineScroll.openingTarget(remembered: 2, current: 20,
                                                  outline: rows, rowsThatFit: 5) == 20)
    }

    /// **Above the fold counts too**, which the range check gets for free and a naive "is it further
    /// down than the anchor" test would not: coming back to an anchor deep in a long document with
    /// the caret in the first heading leaves the mark off the TOP of the list.
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

    /// `nil` is a real answer from `MarkdownOutline.currentEntry` — text above the first heading is
    /// in no section — and it is not a reason to move anything.
    @Test func aCaretInNoSectionLeavesTheAnchorAlone() {
        let rows = outline([2, 4, 6])
        #expect(EditorOutlineScroll.openingTarget(remembered: 4, current: nil,
                                                  outline: rows, rowsThatFit: 1) == 4)
    }

    /// A document nobody has scrolled still gets the rule: the list would start at the top, so a
    /// caret past the fold is still a mark nobody can see.
    @Test func withNoAnchorTheListStillOpensOnACaretPastTheFold() {
        let rows = outline([2, 4, 6, 8, 10, 12])
        #expect(EditorOutlineScroll.openingTarget(remembered: nil, current: 12,
                                                  outline: rows, rowsThatFit: 3) == 12)
        #expect(EditorOutlineScroll.openingTarget(remembered: nil, current: 4,
                                                  outline: rows, rowsThatFit: 3) == nil)
    }

    // MARK: How many rows are on screen

    /// **Floored, and never below one.** A half-visible row at the bottom is not one anybody is
    /// reading, so rounding up would call a heading visible with half of it under the edge — and
    /// that is the only question this number is asked.
    @Test func theRowCountFloorsAndNeverReturnsZero() {
        let scale: CGFloat = 1
        let row = EditorOutlineScroll.rowHeight(scale: scale)
        #expect(EditorOutlineScroll.rowsThatFit(height: row * 4.9, scale: scale) == 4)
        #expect(EditorOutlineScroll.rowsThatFit(height: 0, scale: scale) == 1)
    }

    /// The same eight rows at every text size, which is what makes it a count of rows rather than
    /// of points — the mistake the outline's old cap was written to avoid.
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

    /// The reports that are not the reader's doing. A list between a file opening and its parse
    /// returning is reporting about rows that belong to nothing, and there is nothing to key an
    /// anchor by without a path.
    @Test func aReportThatIsNotTheReadersDoingIsNotRecorded() {
        #expect(!EditorOutlineScroll.recordsAnchor(path: nil, outlineIsEmpty: false, top: 20))
        #expect(!EditorOutlineScroll.recordsAnchor(path: "/a/one.md", outlineIsEmpty: true, top: 20))
        #expect(!EditorOutlineScroll.recordsAnchor(path: "/a/one.md", outlineIsEmpty: false, top: nil))
    }
}
