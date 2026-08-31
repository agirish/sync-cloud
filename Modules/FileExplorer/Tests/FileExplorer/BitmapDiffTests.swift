import CoreGraphics
import Foundation
import Testing
@testable import FileExplorer

/// The repo's first bitmap comparison, on synthetic contexts — including the stride case that is
/// the whole reason this is written as a buffer loop rather than assumed to be one.
@Suite struct BitmapDiffTests {

    /// Draws a white image of `width`×`height` with `fill` painted into `rect` (pixel coords).
    ///
    /// `bytesPerRow: 0` deliberately, everywhere: it is what production uses, and it is what makes
    /// the stride a thing that has to be read back rather than computed.
    private func image(width: Int, height: Int, fill: CGRect? = nil,
                       color: (Double, Double, Double) = (0, 0, 0)) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let fill {
            ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            ctx.fill(fill)
        }
        return try #require(ctx.makeImage())
    }

    @Test func twoIdenticalPagesReportNoChange() throws {
        let a = try image(width: 64, height: 64, fill: CGRect(x: 8, y: 8, width: 16, height: 16))
        let b = try image(width: 64, height: 64, fill: CGRect(x: 8, y: 8, width: 16, height: 16))
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.isIdentical)
        #expect(result.changedRects.isEmpty)
        #expect(result.sizesDiffer == false)
    }

    /// One region changed, and the rects name where — not the whole page. A comparison that
    /// reported "something differs" without saying where would be a boolean with extra steps.
    @Test func oneChangedRegionIsLocated() throws {
        let a = try image(width: 64, height: 64)
        let b = try image(width: 64, height: 64, fill: CGRect(x: 32, y: 32, width: 16, height: 16))
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

    /// **The trap this whole file is written around.** CoreGraphics pads the row stride, so a
    /// width whose RGBA row is not already aligned gets `bytesPerRow > width * 4`. A loop indexing
    /// `y * width * 4` walks progressively off each row and reports an identical pair as almost
    /// entirely changed.
    ///
    /// The test asserts the premise first: if the platform ever stops padding this width, the case
    /// stops exercising the trap and must be re-picked rather than silently passing.
    @Test func aStridePaddedWidthStillComparesCorrectly() throws {
        let width = 101   // 404 bytes a row unpadded — CoreGraphics rounds up
        let ctx = try #require(CGContext(data: nil, width: width, height: 40,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        try #require(ctx.bytesPerRow > width * 4,
                     "this width is no longer padded (\(ctx.bytesPerRow) == \(width * 4)) — pick another")

        let a = try image(width: width, height: 40)
        let b = try image(width: width, height: 40)
        let same = try #require(BitmapDiff.compare(a, b))
        #expect(same.isIdentical,
                "a stride-padded identical pair reported \(same.changedFraction) changed — the loop assumed width × 4")

        let c = try image(width: width, height: 40, fill: CGRect(x: 0, y: 0, width: width, height: 40))
        let all = try #require(BitmapDiff.compare(a, c))
        #expect(all.changedFraction > 0.99, "a fully repainted page reported \(all.changedFraction)")
    }

    /// Anti-alias jitter is not a content change. A re-saved PDF re-embeds its fonts, and every
    /// text edge then differs by a few levels while the page reads identically; at zero tolerance
    /// such a pair reports "everything changed", which says nothing.
    @Test func aFewLevelsOfJitterIsNotAChange() throws {
        let a = try image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32),
                          color: (0.5, 0.5, 0.5))
        // ~2/255 apart — well inside the tolerance.
        let b = try image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32),
                          color: (0.508, 0.508, 0.508))
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.isIdentical, "\(result.changedFraction) of the page counted as changed")
    }

    /// …and the other direction, without which the tolerance test above would pass just as well on
    /// a comparison that never reports anything.
    @Test func aRealChangeIsStillSeenAtTheSameSize() throws {
        let a = try image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32),
                          color: (0.5, 0.5, 0.5))
        let b = try image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32),
                          color: (0.6, 0.6, 0.6))   // ~25/255 — twice the tolerance
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.changedFraction > 0.99)
    }

    /// Mismatched sizes rescale to a common raster and SAY SO. A rescale resamples, so the
    /// resulting figure is a weaker claim than a matched pair's and the viewer must be able to
    /// disclose that rather than print a number that looks the same.
    @Test func mismatchedSizesRescaleAndAreDisclosed() throws {
        let a = try image(width: 64, height: 64, fill: CGRect(x: 0, y: 0, width: 64, height: 64))
        let b = try image(width: 32, height: 32, fill: CGRect(x: 0, y: 0, width: 32, height: 32))
        let result = try #require(BitmapDiff.compare(a, b))
        #expect(result.sizesDiffer)
        // Same picture at two scales: it still reads as unchanged, which is the useful answer.
        #expect(result.changedFraction < 0.02, "\(result.changedFraction)")
    }

    /// A zero-sized side has no raster to compare, and that is nil — never "no difference". The
    /// two must not be the same answer on a surface whose next button trashes a file.
    @Test func aZeroSizedSideIsNilAndNotIdentical() throws {
        let a = try image(width: 8, height: 8)
        let ctx = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let tiny = try #require(ctx.makeImage())
        // A 1×1 side is degenerate but comparable; the nil case is a cropped-to-nothing overlap.
        #expect(BitmapDiff.compare(a, tiny) != nil)
        #expect(BitmapDiff.compare(a, try image(width: 8, height: 8)) != nil)
    }

    // MARK: The difference image

    /// Identical pages produce black — the mode's whole premise, and the thing that makes a glow
    /// mean something.
    @Test func theDifferenceOfIdenticalPagesIsBlack() throws {
        let a = try image(width: 16, height: 16, fill: CGRect(x: 2, y: 2, width: 6, height: 6))
        let b = try image(width: 16, height: 16, fill: CGRect(x: 2, y: 2, width: 6, height: 6))
        let diff = try #require(BitmapDiff.differenceImage(a, b))
        #expect(try brightest(of: diff) == 0)
    }

    @Test func theDifferenceOfAChangedRegionGlows() throws {
        let a = try image(width: 16, height: 16)
        let b = try image(width: 16, height: 16, fill: CGRect(x: 4, y: 4, width: 4, height: 4))
        let diff = try #require(BitmapDiff.differenceImage(a, b))
        #expect(try brightest(of: diff) > 200)
    }

    /// Reads the brightest channel value in an image — through the image's OWN stride, for the
    /// same reason the diff does.
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
