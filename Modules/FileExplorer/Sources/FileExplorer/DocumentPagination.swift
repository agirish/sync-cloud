import Foundation

/// Where the page breaks go, as arithmetic over block heights: no views, no print context. Kept
/// apart from the render because a bad break fails quietly (half a word on each page), and its
/// cases (fits, doesn't fit, taller than a page) belong where a test can hold them.
///
/// A block is one `MarkdownBlock` as ``MarkdownBlockView`` draws it, at the page's content width.
/// The renderer must stack blocks in order with no spacing, each exactly the height given here;
/// ``DocumentPDF`` makes that true.
enum DocumentPagination {

    /// One page: the slice of the stacked content it shows, measured from the content's top.
    struct Page: Equatable {
        /// Distance from the top of the whole stack to the top of this page's slice.
        var start: CGFloat
        /// How much of the stack is visible: the page's content height, except on the last page,
        /// where it is what is left, so a caller can draw a rule under the content.
        var height: CGFloat
    }

    /// Pages for blocks of the given heights, in order.
    ///
    /// A block moves to the next page rather than being cut, except one taller than a whole page:
    /// it starts a page and is cut at page boundaries, since cut beats dropped. An empty document
    /// is one empty page, because Preview refuses to open a PDF with no pages.
    ///
    /// - Parameters:
    ///   - blockHeights: each block's height at the page's content width, in order.
    ///   - pageHeight: the content height of one page — the paper less its margins.
    static func pages(blockHeights: [CGFloat], pageHeight: CGFloat) -> [Page] {
        // A non-positive page height would loop below. A real `NSPrintInfo` never gives one, but
        // refuse it anyway.
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

            // Doesn't fit. If the page already holds something, this block starts the next page,
            // so the break lands on the block boundary.
            if blockTop > pageStart {
                pages.append(Page(start: pageStart, height: blockTop - pageStart))
                pageStart = blockTop
            }
            // Taller than a whole page: cut it page by page until the rest fits. `while`, not
            // `if`, so a block ten pages tall makes ten pages.
            while blockBottom > pageStart + pageHeight {
                pages.append(Page(start: pageStart, height: pageHeight))
                pageStart += pageHeight
            }
            blockTop = blockBottom
        }

        // What is left is the last page, the one whose height isn't the full page height.
        if blockTop > pageStart { pages.append(Page(start: pageStart, height: blockTop - pageStart)) }
        return pages.isEmpty ? [Page(start: 0, height: 0)] : pages
    }
}
