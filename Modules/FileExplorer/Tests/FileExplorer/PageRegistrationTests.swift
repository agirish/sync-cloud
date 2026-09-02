import Testing
import Foundation
import CoreGraphics
@testable import FileExplorer

/// **Does the estimator recover a transform it was given?** That is the only question worth asking
/// of a "best effort" alignment, and it is asked here on synthetic pairs where the answer is known
/// exactly — a page rendered once, then re-rendered shifted and skewed by amounts this file chose.
///
/// A test over real scans could only ever say "the number looked plausible". These say "we moved it
/// by 1.25° and 6px, and the estimate came back within a quarter degree and a pixel" — or they fail.
@Suite struct PageRegistrationTests {

    typealias Grid = PageRegistrationEstimator.Grid

    /// A synthetic page: paper with text-like bars and a rule, enough structure for correlation to
    /// have something to lock onto. Deterministic — no randomness, so a failure is reproducible.
    private func page(width: Int = 256, height: Int = 331) -> Grid {
        var samples = [Double](repeating: 1, count: width * height)
        func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ value: Double) {
            for y in y0..<min(y0 + h, height) where y >= 0 {
                for x in x0..<min(x0 + w, width) where x >= 0 {
                    samples[y * width + x] = value
                }
            }
        }
        // A block of "text" lines, a heading, and a rule down one side — scaled to the grid so
        // the fixture keeps its proportions if the working resolution moves again.
        let u = width / 96
        fill(14 * u, 10 * u, 50 * u, 4 * u, 0.15)
        for line in 0..<9 { fill(14 * u, (24 + line * 8) * u, 62 * u, 3 * u, 0.25) }
        fill(14 * u, 100 * u, 34 * u, 3 * u, 0.25)
        fill(80 * u, 8 * u, 2 * u, 100 * u, 0.4)
        return Grid(width: width, height: height, samples: samples)
    }

    /// Re-samples `grid` as if the page had been scanned rotated by `degrees` and offset by
    /// (`dx`, `dy`) — the forward transform the estimator is meant to invert.
    private func transformed(_ grid: Grid, degrees: Double, dx: Double, dy: Double) -> Grid {
        let radians = degrees * .pi / 180
        let cosA = cos(radians), sinA = sin(radians)
        let cx = Double(grid.width - 1) / 2, cy = Double(grid.height - 1) / 2
        var out = [Double](repeating: 1, count: grid.width * grid.height)
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                // Inverse map: where in the ORIGINAL does this destination sample come from?
                let ox = Double(x) - dx - cx
                let oy = Double(y) - dy - cy
                let sx = cosA * ox + sinA * oy + cx
                let sy = -sinA * ox + cosA * oy + cy
                out[y * grid.width + x] = grid.sample(sx, sy)
            }
        }
        return Grid(width: grid.width, height: grid.height, samples: out)
    }

    // MARK: What it recovers

    /// Pure translation, which is the common half of scanner misfeed.
    @Test(arguments: [(4.0, 0.0), (0.0, -5.0), (6.0, 3.0), (-7.0, 4.0)])
    func itRecoversATranslation(_ offset: (dx: Double, dy: Double)) {
        let a = page()
        let b = transformed(a, degrees: 0, dx: offset.dx, dy: offset.dy)
        // `b` is `a` moved by (dx, dy); to bring `b` back onto `a` the estimate must be the SAME
        // sign, because `error` applies it to `b` with the same inverse mapping `transformed` used.
        let got = PageRegistrationEstimator.estimate(a, b, scale: 1)

        // **The estimate is the CORRECTION, so it is the negative of the movement.** `b` is `a`
        // moved by (dx, dy); what brings `b` back onto `a` is (-dx, -dy), and that is what a warp
        // needs to be handed. Measured both ways before this was written down: every magnitude
        // came back exact and every sign inverted, which is a convention rather than a defect.
        #expect(abs(got.dx - (-offset.dx)) <= 1,
                "dx came back \(got.dx); correcting a page moved \(offset.dx) needs \(-offset.dx)")
        #expect(abs(got.dy - (-offset.dy)) <= 1,
                "dy came back \(got.dy); correcting a page moved \(offset.dy) needs \(-offset.dy)")
        #expect(got.confidence > 0.5,
                "a pure translation of a page onto itself reported only \(got.confidence) confidence")
    }

    /// Rotation, which is the half the caveat is actually about.
    @Test(arguments: [-1.5, -0.75, 0.5, 1.25, 2.0])
    func itRecoversASkew(_ degrees: Double) {
        let a = page()
        let b = transformed(a, degrees: degrees, dx: 0, dy: 0)
        let got = PageRegistrationEstimator.estimate(a, b, scale: 1)

        #expect(abs(got.degrees - (-degrees)) <= 0.25,
                "a page skewed \(degrees)° needs a \(-degrees)° correction; came back as \(got.degrees)°")
        #expect(got.isUsable, "a real skew was reported unusable (confidence \(got.confidence))")
    }

    /// Both at once — a sheet fed in crooked and off-centre, which is what a real scan is.
    @Test func itRecoversASkewAndAnOffsetTogether() {
        let a = page()
        let b = transformed(a, degrees: 1.0, dx: 5, dy: -3)
        let got = PageRegistrationEstimator.estimate(a, b, scale: 1)
        // Measured when this was written: the recovered transform reaches the SAME residual as
        // the exact inverse (0.0124 against a 0.1315 baseline), so the search is not merely close
        // — it lands on the answer.
        let residual = PageRegistrationEstimator.error(a, b, degrees: got.degrees,
                                                       dx: got.dx, dy: got.dy, inset: 21)
        let ideal = PageRegistrationEstimator.error(a, b, degrees: -1.0, dx: -5, dy: 3, inset: 21)
        #expect(residual <= ideal * 1.05,
                "the recovered transform left \(residual) where the exact inverse leaves \(ideal)")

        #expect(abs(got.degrees - (-1.0)) <= 0.25, "angle came back \(got.degrees)°")
        #expect(abs(got.dx - (-5)) <= 1.5, "dx came back \(got.dx)")
        #expect(abs(got.dy - 3) <= 1.5, "dy came back \(got.dy)")
        #expect(got.isUsable)
    }

    // MARK: What it refuses

    /// **An identical pair must claim nothing.** Reporting an alignment here would move a page that
    /// was already aligned, and the diff would then glow along every edge it shifted.
    @Test func anIdenticalPairIsNotWorthAligning() {
        let a = page()
        let got = PageRegistrationEstimator.estimate(a, a, scale: 1)
        #expect(!got.isUsable,
                "an identical pair claimed an alignment (\(got.degrees)°, \(got.dx), \(got.dy), confidence \(got.confidence))")
    }

    /// **Two genuinely different pages must not be forced into agreement.** This is the failure the
    /// confidence floor exists for: a search always returns its best candidate, and "best" over two
    /// unrelated pages is still meaningless.
    @Test func twoDifferentPagesReportLowConfidence() {
        let a = page()
        var other = [Double](repeating: 1, count: 256 * 331)
        // A different document: one big block low on the page, nothing where `a` has its text.
        for y in 190..<295 { for x in 55..<190 { other[y * 256 + x] = 0.2 } }
        let b = Grid(width: 256, height: 331, samples: other)

        let got = PageRegistrationEstimator.estimate(a, b, scale: 1)
        #expect(!got.isUsable,
                "two unrelated pages were aligned with \(got.confidence) confidence — the diff would claim an alignment it did not achieve")
    }

    // MARK: What it says

    /// **The caption never claims a correction too small to see.** A search over two already-aligned
    /// pages returns hundredths of a degree and sub-pixel shifts; captioning those would put a
    /// finding on screen where there is none.
    @Test func aNegligibleCorrectionSaysNothing() {
        #expect(PageRegistration(degrees: 0.01, dx: 0.2, dy: -0.4, confidence: 0.9).caption == nil)
        #expect(PageRegistration.none.caption == nil)
    }

    /// And a real one names which of the two it corrected, so "best effort" attaches to something.
    @Test func aRealCorrectionNamesWhatItDid() throws {
        let skewOnly = try #require(
            PageRegistration(degrees: -1.25, dx: 0, dy: 0, confidence: 0.9).caption)
        #expect(skewOnly.contains("1.25° skew"), "\(skewOnly)")
        #expect(!skewOnly.contains("offset"), "a pure skew claimed an offset it did not correct")
        #expect(skewOnly.contains("best effort"),
                "the caption dropped the words that stop the remaining glow reading as content")

        let both = try #require(
            PageRegistration(degrees: 1.0, dx: -6, dy: 3, confidence: 0.9).caption)
        #expect(both.contains("skew") && both.contains("offset"), "\(both)")

        let offsetOnly = try #require(
            PageRegistration(degrees: 0, dx: -6, dy: 3, confidence: 0.9).caption)
        #expect(offsetOnly.contains("offset") && !offsetOnly.contains("skew"), "\(offsetOnly)")
    }

    // MARK: The bridge into the comparison

    /// The luminance grid is built from the image the DIFF sees — white ground and all — so the
    /// estimator and the comparison cannot disagree about what the page is.
    @Test func theGridReadsAPageAsTheComparisonDoes() throws {
        let width = 64, height = 40
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(ctx.makeImage())

        let grid = try #require(BitmapDiff.grid(image, width: 32))
        #expect(grid.width == 32)
        #expect(grid.height == 20, "the grid did not keep the page's aspect ratio")
        // Ink on one half, paper on the other — whichever way CoreGraphics ordered the rows.
        let dark = grid.samples.filter { $0 < 0.25 }.count
        let light = grid.samples.filter { $0 > 0.75 }.count
        #expect(dark > grid.samples.count / 3, "the ink half did not read as dark (\(dark) samples)")
        #expect(light > grid.samples.count / 3, "the paper half did not read as light (\(light) samples)")
    }

    /// **The refusal reaches the comparison, not just the estimate.** `isUsable` being false is
    /// only half a promise: what matters is that `compareAligning` then compares the pages AS THEY
    /// ARE and reports no registration, so nothing downstream captions an alignment that was
    /// declined.
    @Test func aPairItWillNotAlignIsComparedUnchanged() throws {
        func image(_ draw: (CGContext) -> Void) throws -> CGImage {
            let ctx = try #require(CGContext(data: nil, width: 128, height: 160,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 160))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            draw(ctx)
            return try #require(ctx.makeImage())
        }
        // Two unmistakably different pages: ink in opposite corners.
        let a = try image { $0.fill(CGRect(x: 8, y: 8, width: 50, height: 40)) }
        let b = try image { $0.fill(CGRect(x: 70, y: 110, width: 50, height: 40)) }

        let result = try #require(BitmapDiff.compareAligning(a, b))
        #expect(result.registration == nil,
                "two unrelated pages were reported as aligned (\(String(describing: result.registration)))")
        // And the figure is the unaligned one — the pages really were compared as they are.
        let plain = try #require(BitmapDiff.compare(a, b))
        #expect(result.changedFraction == plain.changedFraction,
                "the declined alignment still changed what was compared")
    }

    /// The scale conversion is real: the estimate is applied to the full-size image, not the grid.
    @Test func theTranslationComesBackInFullSizePixels() {
        let a = page()
        let b = transformed(a, degrees: 0, dx: 4, dy: 0)
        let got = PageRegistrationEstimator.estimate(a, b, scale: 8)
        #expect(abs(got.dx - (-32)) <= 8, "a 4-grid-pixel shift at scale 8 came back as \(got.dx)")
    }
}
