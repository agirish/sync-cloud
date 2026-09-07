import Testing
import Foundation
@testable import FileExplorer

/// Where the page breaks land, as arithmetic — the half of printing that can be wrong quietly.
///
/// Every case here is a shape a real document produces: blocks that fill a page exactly, one that
/// would straddle a break, one too tall for any page, and an empty file.
@Suite struct DocumentPaginationTests {

    private func pages(_ heights: [CGFloat], _ pageHeight: CGFloat) -> [DocumentPagination.Page] {
        DocumentPagination.pages(blockHeights: heights, pageHeight: pageHeight)
    }

    @Test func blocksThatFitTogetherAreOnePage() {
        let result = pages([100, 100, 100], 400)
        #expect(result == [.init(start: 0, height: 300)])
    }

    /// **The claim the whole feature rests on: a block is never cut when it could be moved.**
    /// Two 60pt blocks fit a 100pt page; the second one does not fit beside the first, so it starts
    /// the next page and the break lands exactly on the boundary between them.
    @Test func aBlockThatWouldStraddleABreakStartsTheNextPage() {
        let result = pages([60, 60], 100)
        #expect(result == [.init(start: 0, height: 60), .init(start: 60, height: 60)],
                "a heading that did not fit was cut in half instead of being moved")
    }

    /// A page filled exactly is one page, not one page and an empty second one.
    @Test func anExactFillDoesNotProduceATrailingBlankPage() {
        let result = pages([50, 50], 100)
        #expect(result == [.init(start: 0, height: 100)])
    }

    /// **The one case where a cut is right**: a block taller than the paper has no page it fits on,
    /// so it takes pages of its own and is cut at the boundaries. Better cut than dropped — and it
    /// must not loop, which is what a `while` rather than an `if` buys.
    @Test func aBlockTallerThanThePageIsCutRatherThanLost() {
        let result = pages([250], 100)
        #expect(result == [.init(start: 0, height: 100),
                           .init(start: 100, height: 100),
                           .init(start: 200, height: 50)])
    }

    /// The tall block still starts its own page when something precedes it — the preceding content
    /// is not dragged into the cut.
    @Test func aTallBlockStartsItsOwnPageFirst() {
        let result = pages([40, 250], 100)
        #expect(result.first == .init(start: 0, height: 40),
                "the block before the oversize one was cut with it")
        #expect(result.count == 4)
        #expect(result.last == .init(start: 240, height: 50))
    }

    /// **An empty document is a blank sheet, not a zero-page PDF** — which is a file Preview
    /// refuses to open. The same answer for no blocks at all and for blocks that measure nothing.
    @Test func anEmptyDocumentIsOneBlankPage() {
        #expect(pages([], 100) == [.init(start: 0, height: 0)])
        #expect(pages([0, 0], 100) == [.init(start: 0, height: 0)])
    }

    /// A page with no height cannot be paginated and must not spin trying. Unreachable from a real
    /// `NSPrintInfo`, which is why it is checked here rather than trusted there.
    @Test func aPageWithNoHeightRefusesRatherThanLooping() {
        #expect(pages([100], 0) == [.init(start: 0, height: 0)])
    }

    /// Every page's slice is inside the content, and the slices are contiguous — the property that
    /// makes "print all pages" print the whole document exactly once.
    @Test func thePagesCoverTheContentExactlyOnce() {
        let heights: [CGFloat] = [30, 120, 45, 300, 22, 60]
        let result = pages(heights, 200)
        var expected: CGFloat = 0
        for page in result {
            #expect(page.start == expected, "page \(page) does not start where the last one ended")
            expected = page.start + page.height
        }
        #expect(expected == heights.reduce(0, +), "the pages do not add up to the document")
    }
}
