import Foundation

/// Where the page breaks go, as arithmetic over block heights — no views, no print context.
///
/// **Separated from the render because it is the half that can be wrong quietly.** A renderer that
/// draws nothing fails loudly; a paginator that puts a break two points into a heading produces a
/// PDF that opens, prints, and has the top half of a word on one page and the bottom half on the
/// next. That is a rule with cases — a block that fits the rest of the page, one that does not, one
/// that is taller than any page at all — and cases belong somewhere a test can hold all three.
///
/// The unit is a **block**: one `MarkdownBlock` as ``MarkdownBlockView`` draws it, measured at the
/// page's content width. The contract with the renderer is that the blocks are stacked in order
/// with no spacing between them, each occupying exactly the height given here — see
/// ``DocumentPDF`` for how that is made true rather than hoped for.
enum DocumentPagination {

    /// One page: the slice of the stacked content it shows, measured from the content's top.
    struct Page: Equatable {
        /// Distance from the top of the whole stack to the top of this page's slice.
        var start: CGFloat
        /// How much of the stack is visible. Always the page's content height except on the last
        /// page, where it is whatever is left — which is what lets a caller draw a rule under the
        /// content rather than under the paper.
        var height: CGFloat
    }

    /// Pages for blocks of the given heights, in order.
    ///
    /// **A block moves to the next page rather than being cut**, which is the whole point, and the
    /// exception is the one case where honouring that would loop forever: a block taller than a
    /// whole page has no page it fits on, so it starts one and is cut at page boundaries until it
    /// is spent. A 40-line code fence and a tall screenshot both reach that path, and both are
    /// better cut than dropped.
    ///
    /// **An empty document is one empty page, not zero pages.** A PDF with no pages is a file
    /// Preview refuses to open, and "I exported my empty note and got a broken file" is a worse
    /// answer than a blank sheet.
    ///
    /// - Parameters:
    ///   - blockHeights: each block's height at the page's content width, in order.
    ///   - pageHeight: the content height of one page — the paper less its margins.
    static func pages(blockHeights: [CGFloat], pageHeight: CGFloat) -> [Page] {
        // A non-positive page height has no pagination to do and would loop below. It cannot arise
        // from a real `NSPrintInfo`, which is exactly why it is worth refusing rather than trusting.
        guard pageHeight > 0 else { return [Page(start: 0, height: 0)] }

        let total = blockHeights.reduce(0, +)
        guard total > 0 else { return [Page(start: 0, height: 0)] }

        var pages: [Page] = []
        var pageStart: CGFloat = 0
        var blockTop: CGFloat = 0

        for height in blockHeights {
            let blockBottom = blockTop + height
            // Fits in what is left of the current page: nothing to decide.
            if blockBottom <= pageStart + pageHeight { blockTop = blockBottom; continue }

            // Does not fit. If the page already has something on it, this block starts the next
            // page — the break lands exactly on the block boundary, which is the promise.
            if blockTop > pageStart {
                pages.append(Page(start: pageStart, height: blockTop - pageStart))
                pageStart = blockTop
            }
            // Taller than a whole page even with the page to itself: cut it, page by page, until
            // the remainder fits. `while` rather than `if`, so a block ten pages tall is ten pages
            // rather than two.
            while blockBottom > pageStart + pageHeight {
                pages.append(Page(start: pageStart, height: pageHeight))
                pageStart += pageHeight
            }
            blockTop = blockBottom
        }

        // Whatever is left over is the last page. `blockTop` is now the content's total height, so
        // this is the one page whose height is not the full page height.
        if blockTop > pageStart { pages.append(Page(start: pageStart, height: blockTop - pageStart)) }
        return pages.isEmpty ? [Page(start: 0, height: 0)] : pages
    }
}
