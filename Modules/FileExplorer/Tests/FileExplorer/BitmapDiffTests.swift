import CoreGraphics
import Foundation
import Testing
@testable import FileExplorer

/// The bitmap comparison, on synthetic contexts, including the row-stride case the buffer loop
/// exists to get right.
@Suite struct BitmapDiffTests {

    /// Draws a white image of `width`×`height` with `color` painted into `fill` and each of
    /// `fills` (pixel coords). `ChangedRegionCalloutTests` draws with it too.
    ///
    /// `bytesPerRow: 0` everywhere, as production uses, so the stride must be read back rather
    /// than computed.
    static func image(width: Int, height: Int, fill: CGRect? = nil, fills: [CGRect] = [],
                      color: (Double, Double, Double) = (0, 0, 0)) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        for rect in [fill].compactMap({ $0 }) + fills { ctx.fill(rect) }
        return try #require(ctx.makeImage())
    }

    @Test func twoIdenticalPagesReportNoChange() throws {
        let a = try Self.image(width: 64, height: 64, fill: CGRect(x: 8, y: 8, width: 16, height: 16))
        let b = try Self.image(width: 64, height: 64, fill: CGRect(x: 8, y: 8, width: 16, height: 16))
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.isIdentical)
        #expect(result.changedRects.isEmpty)
        #expect(result.sizesDiffer == false)
    }

    /// One region changed, and the rects name where, not the whole page.
    @Test func oneChangedRegionIsLocated() throws {
        let a = try Self.image(width: 64, height: 64)
        let b = try Self.image(width: 64, height: 64, fill: CGRect(x: 32, y: 32, width: 16, height: 16))
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(!result.isIdentical)
        // 16×16 of 64×64 = 1/16 of the page.
        #expect(abs(result.changedFraction - 0.0625) < 0.005,
                "changed fraction was \(result.changedFraction)")
        let union = result.changedRects.reduce(CGRect.null) { $0.union($1) }
        #expect(union.width <= 32 && union.height <= 32,
                "the changed region spread beyond the square that changed: \(union)")
        #expect(union.width >= 16 && union.height >= 16)
    }

    /// The stride trap: CoreGraphics pads the row stride, so a width whose RGBA row isn't already
    /// aligned gets `bytesPerRow > width * 4`. A loop indexing `y * width * 4` walks off each row
    /// and reports an identical pair as almost entirely changed.
    ///
    /// The premise is asserted first: if the platform stops padding this width, the case must be
    /// re-picked rather than silently passing.
    @Test func aStridePaddedWidthStillComparesCorrectly() throws {
        let width = 101   // 404 bytes a row unpadded — CoreGraphics rounds up
        let ctx = try #require(CGContext(data: nil, width: width, height: 40,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        try #require(ctx.bytesPerRow > width * 4,
                     "this width is no longer padded (\(ctx.bytesPerRow) == \(width * 4)) — pick another")

        let a = try Self.image(width: width, height: 40)
        let b = try Self.image(width: width, height: 40)
        let same = try #require(BitmapDiff.compare(a, b))
        #expect(same.isIdentical,
                "a stride-padded identical pair reported \(same.changedFraction) changed — the loop assumed width × 4")

        let c = try Self.image(width: width, height: 40, fill: CGRect(x: 0, y: 0, width: width, height: 40))
        let all = try #require(BitmapDiff.compare(a, c))
        #expect(all.changedFraction > 0.99, "a fully repainted page reported \(all.changedFraction)")
    }

    /// Anti-alias jitter is not a content change: a re-saved PDF re-embeds its fonts and every
    /// text edge differs by a few levels, so at zero tolerance the pair would read as all changed.
    @Test func aFewLevelsOfJitterIsNotAChange() throws {
        let a = try Self.image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32),
                          color: (0.5, 0.5, 0.5))
        // ~2/255 apart, well inside the tolerance.
        let b = try Self.image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32),
                          color: (0.508, 0.508, 0.508))
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.isIdentical, "\(result.changedFraction) of the page counted as changed")
    }

    /// The other direction, without which the tolerance test above would pass on a comparison
    /// that never reports anything.
    @Test func aRealChangeIsStillSeenAtTheSameSize() throws {
        let a = try Self.image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32),
                          color: (0.5, 0.5, 0.5))
        let b = try Self.image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32),
                          color: (0.6, 0.6, 0.6))   // ~25/255 — twice the tolerance
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.changedFraction > 0.99)
    }

    /// Mismatched sizes rescale to a common raster and say so: a resampled figure is a weaker
    /// claim than a matched pair's, and the viewer must be able to disclose that.
    @Test func mismatchedSizesRescaleAndAreDisclosed() throws {
        let a = try Self.image(width: 64, height: 64, fill: CGRect(x: 0, y: 0, width: 64, height: 64))
        let b = try Self.image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32))
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.sizesDiffer)
        // Same picture at two scales: it still reads as unchanged, which is the useful answer.
        #expect(result.changedFraction < 0.02, "\(result.changedFraction)")
    }

    /// A one-pixel side is degenerate but still compared, and says the sizes differed. The `nil`
    /// that `analyse` keeps for a zero-sized side is unreachable from here: a `CGImage` is never
    /// 0×0, and `cropping(to:)` an empty rect returns no image at all, so there is no input to
    /// test it with.
    @Test func aOnePixelSideIsStillComparedAndDisclosed() throws {
        let a = try Self.image(width: 8, height: 8)
        let ctx = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let tiny = try #require(ctx.makeImage())
        let result = try #require(BitmapDiff.compare(a, tiny), "a 1×1 side was refused")
        #expect(result.sizesDiffer)
        #expect(a.cropping(to: .zero) == nil, "an empty crop now makes an image — the zero-sized case is reachable and wants its own test")
    }

    // MARK: The difference image

    /// Identical pages produce black, which is what makes a glow mean something.
    @Test func theDifferenceOfIdenticalPagesIsBlack() throws {
        let a = try Self.image(width: 16, height: 16, fill: CGRect(x: 2, y: 2, width: 6, height: 6))
        let b = try Self.image(width: 16, height: 16, fill: CGRect(x: 2, y: 2, width: 6, height: 6))
        let diff = try #require(BitmapDiff.differenceImage(a, b))
        #expect(try brightest(of: diff) == 0)
    }

    @Test func theDifferenceOfAChangedRegionGlows() throws {
        let a = try Self.image(width: 16, height: 16)
        let b = try Self.image(width: 16, height: 16, fill: CGRect(x: 4, y: 4, width: 4, height: 4))
        let diff = try #require(BitmapDiff.differenceImage(a, b))
        #expect(try brightest(of: diff) > 200)
    }

    /// Reads the brightest channel value in an image, through the image's own stride, as the
    /// diff does.
    private func brightest(of image: CGImage) throws -> Int {
        let width = image.width, height = image.height
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = try #require(ctx.data)
        let stride = ctx.bytesPerRow
        let bytes = data.bindMemory(to: UInt8.self, capacity: stride * height)
        var best = 0
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<3 { best = max(best, Int(bytes[y * stride + x * 4 + channel])) }
            }
        }
        return best
    }
}
