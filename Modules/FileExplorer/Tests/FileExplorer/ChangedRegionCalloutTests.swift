import CoreGraphics
import Foundation
import Testing
@testable import FileExplorer

/// Merging changed cells into pointable regions, and putting them on screen where the change is.
///
/// **The rects were computed, tested and drawn nowhere** — the field's own doc promised "the
/// difference view's callouts" while nothing consumed it. Two halves are pinned here: the merge,
/// because a cell is not a region, and the aspect-fit mapping, because an outline that is
/// plausibly NEAR the change rather than on it looks exactly like a working feature.
@Suite struct ChangedRegionCalloutTests {

    private func image(width: Int, height: Int, fills: [CGRect] = []) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for rect in fills { ctx.fill(rect) }
        return try #require(ctx.makeImage())
    }

    // MARK: The merge

    /// **A cell is not a region.** One edited sentence spans several 16px cells, and "8 regions
    /// differ" about one edit is a worse answer than "something differs". A 64×16 change crosses
    /// four cells horizontally and must come back as ONE rect.
    @Test func adjacentCellsMergeIntoOneRegion() throws {
        let a = try image(width: 128, height: 128)
        let b = try image(width: 128, height: 128, fills: [CGRect(x: 16, y: 16, width: 64, height: 16)])
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.changedRects.count == 1,
                "one change came back as \(result.changedRects.count) regions")
    }

    /// **The positive control on the merge.** A rule that merged everything into one rect would
    /// pass the test above and be useless — two changes at opposite corners have to stay two.
    @Test func separatedChangesStayTwoRegions() throws {
        let a = try image(width: 128, height: 128)
        let b = try image(width: 128, height: 128,
                          fills: [CGRect(x: 0, y: 0, width: 16, height: 16),
                                  CGRect(x: 96, y: 96, width: 16, height: 16)])
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.changedRects.count == 2)
    }

    /// Eight-connectivity, not four: a line of text lights a ragged edge of cells, and a diagonal
    /// step between two of them is the same edit. Two cells touching only at a corner are one
    /// region — under four-connectivity this same input comes back as two.
    @Test func diagonallyTouchingCellsAreOneRegion() {
        // A 2×2 cell grid with only the two diagonal cells touched.
        let touched = [true, false, false, true]
        let regions = BitmapDiff.regions(touched: touched, cells: 2, rows: 2,
                                         width: 32, height: 32)
        #expect(regions.count == 1)
        #expect(regions[0] == CGRect(x: 0, y: 0, width: 32, height: 32))
    }

    /// The trailing cell of a row or column is a partial one wherever the raster is not a multiple
    /// of `cellSide`, and a rect running past the page would draw a callout over nothing.
    @Test func aRegionIsClampedToTheComparedArea() {
        let touched = [true, true]
        let regions = BitmapDiff.regions(touched: touched, cells: 2, rows: 1,
                                         width: 20, height: 10)
        #expect(regions.count == 1)
        #expect(regions[0] == CGRect(x: 0, y: 0, width: 20, height: 10),
                "the region ran past the raster: \(regions[0])")
    }

    /// Reading order, so the callouts a reader scans are top-to-bottom rather than in whatever
    /// order the flood fill happened to reach them.
    @Test func regionsComeBackInReadingOrder() {
        // Three isolated cells on a 5-wide grid: bottom-left, top-right, top-left.
        var touched = [Bool](repeating: false, count: 15)
        touched[10] = true   // row 2, col 0
        touched[4] = true    // row 0, col 4
        touched[0] = true    // row 0, col 0
        let regions = BitmapDiff.regions(touched: touched, cells: 5, rows: 3,
                                         width: 80, height: 48)
        #expect(regions.map(\.minY) == [0, 0, 32])
        #expect(regions.prefix(2).map(\.minX) == [0, 64], "ties break left-to-right")
    }

    @Test func nothingTouchedIsNoRegions() {
        #expect(BitmapDiff.regions(touched: [false, false], cells: 2, rows: 1,
                                   width: 32, height: 16).isEmpty)
    }

    // MARK: The aspect-fit mapping

    /// A square image in a wide frame is letterboxed left and right, so the callouts have to be
    /// offset by the same margin the image is.
    @Test func aFittedRectIsCentredAndScaled() {
        let fitted = ChangedRegionCallouts.fittedRect(imageSize: CGSize(width: 100, height: 100),
                                                      in: CGSize(width: 400, height: 200))
        #expect(fitted == CGRect(x: 100, y: 0, width: 200, height: 200))
    }

    @Test func aTallImageIsFittedByWidth() {
        let fitted = ChangedRegionCallouts.fittedRect(imageSize: CGSize(width: 100, height: 200),
                                                      in: CGSize(width: 100, height: 1000))
        #expect(fitted == CGRect(x: 0, y: 400, width: 100, height: 200))
    }

    /// A raster can be nil-sized while a render is in flight, and the view mounts before it is
    /// laid out — neither is a divide by zero.
    @Test(arguments: [CGSize(width: 0, height: 100), CGSize(width: 100, height: 0)])
    func aDegenerateSizeIsNoRect(bad: CGSize) {
        #expect(ChangedRegionCallouts.fittedRect(imageSize: bad, in: CGSize(width: 10, height: 10))
                    .isNull)
        #expect(ChangedRegionCallouts.fittedRect(imageSize: CGSize(width: 10, height: 10), in: bad)
                    .isNull)
    }

    /// **The mapping the whole file exists for.** A region at the image's top-left lands at the
    /// letterbox's top-left, scaled — and the y axis is NOT flipped, because a `CGBitmapContext`'s
    /// buffer starts at the image's top row, the same direction SwiftUI lays out in. A flip would
    /// look correct on a symmetric page and be wrong on every real one.
    @Test func aRegionMapsOntoTheSamePixelsTheImageIsDrawnOn() throws {
        let drawn = ChangedRegionCallouts.drawable(
            regions: [CGRect(x: 10, y: 20, width: 30, height: 40)],
            imageSize: CGSize(width: 100, height: 100),
            in: CGSize(width: 400, height: 200))
        // Fitted rect is (100, 0, 200, 200) — scale 2, x offset 100, y offset 0.
        #expect(drawn == [CGRect(x: 120, y: 40, width: 60, height: 80)])
    }

    /// Past the cap the outlines stop being callouts and become a mesh, so none is drawn — while
    /// the caption still reports the count, which is the half the reader can act on.
    @Test func tooManyRegionsAreCountedButNotDrawn() {
        let many = (0...ChangedRegionCallouts.maxDrawn).map {
            CGRect(x: $0 * 4, y: 0, width: 2, height: 2)
        }
        #expect(many.count > ChangedRegionCallouts.maxDrawn)
        #expect(ChangedRegionCallouts.drawable(regions: many,
                                               imageSize: CGSize(width: 100, height: 100),
                                               in: CGSize(width: 100, height: 100)).isEmpty)
        #expect(ChangedRegionCallouts.caption(regionCount: many.count)?
                    .contains("too many to outline") == true)
        // And exactly at the cap it still draws — the boundary, from both sides.
        #expect(ChangedRegionCallouts.drawable(regions: Array(many.dropLast()),
                                               imageSize: CGSize(width: 100, height: 100),
                                               in: CGSize(width: 100, height: 100)).count
                == ChangedRegionCallouts.maxDrawn)
    }

    // MARK: The caption

    /// Silent at zero: "0 regions differ" beside a black canvas restates an empty picture.
    @Test func noRegionsSaysNothing() {
        #expect(ChangedRegionCallouts.caption(regionCount: 0) == nil)
    }

    @Test func theCaptionAgreesWithItselfOnNumber() {
        #expect(ChangedRegionCallouts.caption(regionCount: 1) == "1 region differs")
        #expect(ChangedRegionCallouts.caption(regionCount: 3) == "3 regions differ")
    }
}
