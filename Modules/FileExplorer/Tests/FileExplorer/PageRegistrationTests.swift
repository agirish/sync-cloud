import Testing
import Foundation
import CoreGraphics
@testable import FileExplorer

/// Does the estimator recover a transform it was given? Asked on synthetic pairs where the answer
/// is known exactly: a page rendered once, then re-rendered shifted and skewed by amounts this file
/// chose. A test over real scans could only say the number looked plausible; these say how close
/// the estimate came, or fail.
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
        // A block of "text" lines, a heading, and a rule down one side, scaled to the grid so the
        // fixture keeps its proportions if the working resolution changes.
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
        let got = PageRegistrationEstimator.estimate(a, b, scale: 1)

        // The estimate is the correction, so it is the negative of the movement: `b` is `a` moved
        // by (dx, dy), and what brings it back onto `a` is (-dx, -dy), which a warp needs.
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
        // The recovered transform must reach the exact inverse's residual, so the search lands on
        // the answer, not merely near it.
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

    /// An identical pair must claim nothing: an alignment here would move a page that was already
    /// aligned, and the diff would glow along every edge it shifted.
    @Test func anIdenticalPairIsNotWorthAligning() {
        let a = page()
        let got = PageRegistrationEstimator.estimate(a, a, scale: 1)
        #expect(!got.isUsable,
                "an identical pair claimed an alignment (\(got.degrees)°, \(got.dx), \(got.dy), confidence \(got.confidence))")
    }

    /// Two different pages must not be forced into agreement. A search always returns its best
    /// candidate, and "best" over two unrelated pages is meaningless; the confidence floor stops
    /// it.
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

    /// The caption never claims a correction too small to see: two aligned pages search out to
    /// hundredths of a degree and sub-pixel shifts, which are not a finding.
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
        let halfInked = try image(64, 40) { $0.fill(CGRect(x: 0, y: 0, width: 32, height: 40)) }

        let grid = try #require(BitmapDiff.grid(halfInked, width: 32))
        #expect(grid.width == 32)
        #expect(grid.height == 20, "the grid did not keep the page's aspect ratio")
        // Ink on one half, paper on the other — whichever way CoreGraphics ordered the rows.
        let dark = grid.samples.filter { $0 < 0.25 }.count
        let light = grid.samples.filter { $0 > 0.75 }.count
        #expect(dark > grid.samples.count / 3, "the ink half did not read as dark (\(dark) samples)")
        #expect(light > grid.samples.count / 3, "the paper half did not read as light (\(light) samples)")
    }

    /// The refusal reaches the comparison, not just the estimate: `compareAligning` compares the
    /// pages as they are and reports no registration, so nothing downstream captions a declined
    /// alignment.
    @Test func aPairItWillNotAlignIsComparedUnchanged() throws {
        // Two unmistakably different pages: ink in opposite corners.
        let a = try image(128, 160) { $0.fill(CGRect(x: 8, y: 8, width: 50, height: 40)) }
        let b = try image(128, 160) { $0.fill(CGRect(x: 70, y: 110, width: 50, height: 40)) }

        let result = try #require(BitmapDiff.compareAligning(a, b, wantsDifferenceImage: false).result)
        #expect(result.registration == nil,
                "two unrelated pages were reported as aligned (\(String(describing: result.registration)))")
        // And the figure is the unaligned one — the pages really were compared as they are.
        let plain = try #require(BitmapDiff.compare(a, b))
        #expect(result.changedFraction == plain.changedFraction,
                "the declined alignment still changed what was compared")
    }

    /// The glow and the outlines come from one comparison on every path out of `compareAligning`.
    /// The picture is the per-channel distance, so counting its pixels that clear
    /// ``BitmapDiff/tolerance`` must reproduce `changedFraction` exactly. Fails if the picture is
    /// drawn from the unaligned pair while the figures come from the aligned one.
    ///
    /// Covers all three returns, since the estimator refuses most real pairs and the fallback is
    /// what a reader usually gets. Two guards keep it from going vacuous: each case must take the
    /// branch it is named for, and on the aligned case the unaligned picture must actually
    /// disagree.
    @Test func thePictureAndTheFigureAreOfTheSamePair() throws {
        let left = try barPage(edited: false)

        // Ink in the opposite corner from the fixture's own: unmistakably a different page, which
        // the estimator refuses, so `analyse(left, right,)` answers instead.
        let unrelated = try image(512, 662) { $0.fill(CGRect(x: 300, y: 60, width: 160, height: 220)) }
        // A different aspect ratio, so the two grids disagree on height and the guard fires before
        // the estimator is ever reached.
        let otherShape = try image(900, 400) { $0.fill(CGRect(x: 40, y: 40, width: 300, height: 200)) }

        let cases: [(name: String, right: CGImage, aligns: Bool)] = [
            ("a de-skewed pair", try skewed(barPage(edited: true), degrees: -1.0), true),
            ("two unrelated pages", unrelated, false),
            ("a pair whose grids do not match", otherShape, false)
        ]

        for c in cases {
            let (outcome, picture) = BitmapDiff.compareAligning(left, c.right,
                                                                wantsDifferenceImage: true)
            let result = try #require(outcome, "\(c.name): nothing came back at all")
            let shown = try #require(picture, "\(c.name): asked for a picture and got none")

            // Guard one: this case took the branch it is here to cover.
            #expect((result.registration != nil) == c.aligns, """
                \(c.name): registration came back \(result.registration == nil ? "nil" : "set"), \
                so this case is no longer testing the path it names
                """)

            // The invariant itself.
            #expect(inkFraction(shown) == result.changedFraction, """
                \(c.name): the picture holds \(inkFraction(shown)) of changed pixels while the \
                result reports \(result.changedFraction) — the glow and the callouts are of \
                different image pairs again
                """)

            // Guard two, on the aligned case only: the OLD picture would have failed the line
            // above, so the fixture is sharp enough to catch a return to it.
            if c.aligns {
                let asTheyAre = try #require(BitmapDiff.analyse(left, c.right,
                                                                wantsDifferenceImage: true).difference)
                #expect(inkFraction(asTheyAre) != result.changedFraction,
                        "\(c.name): the unaligned picture already matched the aligned figure — this fixture proves nothing")
            }
        }
    }

    /// A caller that didn't ask for the picture must not get one on the aligned path. The
    /// difference raster is a third full-page image (~13 MB at the sheet's size) that the swipe and
    /// onion modes never draw; `CompareCopiesSheet.wantsAlignedDifference` exists to spare them it.
    @Test func askingForNoPictureOnAnAlignedPairAllocatesNone() throws {
        let left = try barPage(edited: false)
        let right = try skewed(barPage(edited: true), degrees: -1.0)

        let outcome = BitmapDiff.compareAligning(left, right, wantsDifferenceImage: false)
        let result = try #require(outcome.result)
        // The guard: this is the aligned path, not a fallback that trivially draws nothing.
        #expect(result.registration != nil,
                "the fixture was not aligned, so this says nothing about the aligned path")
        #expect(outcome.difference == nil,
                "a caller that asked for no picture was handed one anyway — a full-page raster the swipe and onion modes would pay for")
    }

    /// A white RGB canvas of a given size.
    private func whiteContext(_ width: Int, _ height: Int) throws -> CGContext {
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx
    }

    /// A blank raster of a given size with `draw` run over it in black.
    private func image(_ width: Int, _ height: Int,
                       _ draw: (CGContext) -> Void) throws -> CGImage {
        let ctx = try whiteContext(width, height)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        draw(ctx)
        return try #require(ctx.makeImage())
    }

    /// The share of a difference raster that is above ``BitmapDiff/tolerance`` — the same predicate
    /// `analyse` counts `changedFraction` with, read back off the picture it drew.
    private func inkFraction(_ difference: CGImage) -> Double {
        guard let data = difference.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return .nan }
        var changed = 0
        for y in 0..<difference.height {
            for x in 0..<difference.width {
                // The stride read back, never computed — see `BitmapDiff.analyse`.
                let i = y * difference.bytesPerRow + x * 4
                // Byte 4 is `noneSkipLast` padding and carries no distance.
                if max(Int(bytes[i]), max(Int(bytes[i + 1]), Int(bytes[i + 2]))) > BitmapDiff.tolerance {
                    changed += 1
                }
            }
        }
        return Double(changed) / Double(difference.width * difference.height)
    }

    /// ``page()``'s bars drawn as a real raster, at a size whose 256-wide grid is a reduction rather
    /// than an enlargement. `edited` shortens one bar — the "one paragraph changed" a reader is
    /// looking for.
    private func barPage(edited: Bool, width: Int = 512, height: Int = 662) throws -> CGImage {
        let ctx = try whiteContext(width, height)
        let u = CGFloat(width) / 96
        func bar(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat, _ value: CGFloat) {
            ctx.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
            ctx.fill(CGRect(x: x * u, y: CGFloat(height) - (top + h) * u, width: w * u, height: h * u))
        }
        bar(14, 10, 50, 4, 0.15)
        for line in 0..<9 { bar(14, CGFloat(24 + line * 8), edited && line == 5 ? 30 : 62, 3, 0.25) }
        bar(14, 100, 34, 3, 0.25)
        bar(80, 8, 2, 100, 0.4)
        return try #require(ctx.makeImage())
    }

    /// The page as if it had gone through the scanner at an angle: rotated about its centre and
    /// resampled once, which is the forward transform `BitmapDiff.warped` has to invert.
    private func skewed(_ image: CGImage, degrees: Double) throws -> CGImage {
        let ctx = try whiteContext(image.width, image.height)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2)
        ctx.rotate(by: CGFloat(degrees * .pi / 180))
        ctx.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(ctx.makeImage())
    }

    /// The scale conversion is real: the estimate is applied to the full-size image, not the grid.
    @Test func theTranslationComesBackInFullSizePixels() {
        let a = page()
        let b = transformed(a, degrees: 0, dx: 4, dy: 0)
        let got = PageRegistrationEstimator.estimate(a, b, scale: 8)
        #expect(abs(got.dx - (-32)) <= 8, "a 4-grid-pixel shift at scale 8 came back as \(got.dx)")
    }
}
