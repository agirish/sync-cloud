import CoreGraphics
import Foundation

/// A best-effort estimate of how one scanned page sits relative to the other: a small rotation and
/// a translation, recovered by correlating the two at a coarse scale.
///
/// **Why this exists.** The pixel modes compare two pages by their frames alone, so two scans of
/// one sheet of paper — the most common real pair anyone reaches for — glow all over from a
/// half-degree of skew. The caveat says so, honestly, and concedes exactly the case the mode is
/// for.
///
/// **Why it is deliberately crude.** No feature detection, no dependency, no third-party code: a
/// downsampled luminance grid, an exhaustive translation search, then a small rotation sweep. That
/// is enough for scanner skew (which is a degree or two of rotation and a few millimetres of
/// offset) and is honest about being nothing more. A pair that needs more than this is a pair this
/// estimator reports low confidence for, and the diff then falls back to comparing frames — saying
/// so rather than claiming an alignment it did not achieve.
public struct PageRegistration: Equatable, Sendable {
    /// Rotation in degrees, positive counter-clockwise, applied about the image centre.
    public let degrees: Double
    /// Translation in pixels of the FULL-SIZE image, applied after the rotation.
    public let dx: Double
    public let dy: Double
    /// How much better the aligned overlap is than the unaligned one, as a fraction of the
    /// unaligned error: 0 means alignment bought nothing, 1 would mean it removed all of it.
    ///
    /// **This is the number the feature is gated on**, not the transform. A confident-looking
    /// rotation recovered from two genuinely different pages is exactly the failure the caveat
    /// exists to prevent, and the only defence is refusing to claim an alignment that did not
    /// measurably improve the match.
    public let confidence: Double

    /// Whether this estimate is worth applying — see ``confidence``.
    ///
    /// **0.35 is a measured floor, and the measurement is why it is not 0.15.** The first cut used
    /// 0.15 on the reasoning that any real improvement is worth taking. Two deliberately unrelated
    /// synthetic pages then came back at **0.152** and **0.160** — a search always returns its best
    /// candidate, and over two different documents "best" still removes a sixth of the error by
    /// sliding one page's ink under the other's. Real pairs in the same fixtures score far higher:
    /// a pure translation above 0.5, a 1° skew with a (5, −3) offset at **0.906**. 0.35 sits in the
    /// empty band between the two populations rather than at the edge of either.
    public var isUsable: Bool { confidence >= 0.35 && (degrees != 0 || dx != 0 || dy != 0) }

    /// The sentence that replaces the difference mode's "with no alignment" caveat when this
    /// registration was applied — nil when it says nothing worth saying.
    ///
    /// **"Best effort" is in it because it is the truth about the method.** This is a coarse
    /// correlation over a 256-pixel grid, built for scanner skew and nothing like a registration
    /// pass; a reader told only "aligned" would reasonably read the remaining glow as content.
    ///
    /// Thresholded so the sentence never claims a correction too small to see: a hundredth of a
    /// degree and a sub-pixel shift are what the search returns for two pages that were already
    /// aligned, and captioning those would be noise that reads as a finding.
    public var caption: String? {
        let angle = abs(degrees) >= 0.25 ? String(format: "%.2f°", abs(degrees)) : nil
        let moved = abs(dx) >= 1 || abs(dy) >= 1
        let parts = [angle.map { "a \($0) skew" }, moved ? "an offset" : nil].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "Aligned before comparing — \(ComparePairFacts.list(parts)) corrected, best effort."
    }

    /// The identity — what a pair that needs no alignment, or admits none, reports.
    public static let none = PageRegistration(degrees: 0, dx: 0, dy: 0, confidence: 0)

    public init(degrees: Double, dx: Double, dy: Double, confidence: Double) {
        self.degrees = degrees
        self.dx = dx
        self.dy = dy
        self.confidence = confidence
    }
}

/// Recovers a ``PageRegistration`` from two rasters.
///
/// Pure and `nonisolated`, over a plain luminance grid rather than `CGImage`, so the search is
/// testable on synthetic transforms with no rendering in the loop — which is the only way to know
/// whether it recovers a rotation it was given, rather than merely producing a number.
public enum PageRegistrationEstimator {

    /// The width both pages are reduced to before searching.
    ///
    /// **256, and the number was measured rather than chosen.** The first cut used 96, on the
    /// reasoning that skew is a whole-page property and a coarse grid is cheap. It is cheap and it
    /// is blind: a 1° rotation moves the page edge by `height/2 × tan(1°)` — about 1.1 pixels at
    /// 96 wide, which is under the bilinear filter's own smoothing. Measured on synthetic pairs,
    /// a 1.25° skew came back with **0.02 confidence** and 0.5° came back as no rotation at all,
    /// so the estimator could recover translation perfectly and was useless for the one thing the
    /// caveat is about.
    ///
    /// At 256 the same skew moves the edge ~3 pixels, which correlates. The cost is paid back by
    /// searching the two stages at different scales — see ``estimate(_:_:scale:)``.
    public static let gridWidth = 256

    /// How much the translation sweep downsamples before searching. The sweep is the expensive
    /// stage (its candidate count is quadratic in the span), and translation — unlike rotation —
    /// is perfectly visible at a coarse scale.
    static let translationDownsample = 4

    /// One page as coarse luminance, row-major, `width * height` samples in 0...1.
    public struct Grid: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let samples: [Double]
        public init(width: Int, height: Int, samples: [Double]) {
            self.width = width
            self.height = height
            self.samples = samples
        }
        func sample(_ x: Int, _ y: Int) -> Double {
            guard x >= 0, y >= 0, x < width, y < height else { return 1 }   // off-page reads as paper
            return samples[y * width + x]
        }
        /// This grid reduced by `factor`, box-filtered. Used to make the translation sweep cheap
        /// without costing the rotation sweep its resolution.
        func downsampled(by factor: Int) -> Grid {
            guard factor > 1 else { return self }
            let w = max(1, width / factor), h = max(1, height / factor)
            var out = [Double](repeating: 1, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var total = 0.0
                    var n = 0
                    for sy in (y * factor)..<min((y + 1) * factor, height) {
                        for sx in (x * factor)..<min((x + 1) * factor, width) {
                            total += samples[sy * width + sx]
                            n += 1
                        }
                    }
                    out[y * w + x] = n == 0 ? 1 : total / Double(n)
                }
            }
            return Grid(width: w, height: h, samples: out)
        }

        /// Bilinear read at a fractional position — what the rotation sweep needs, since a rotated
        /// grid lands between samples everywhere.
        func sample(_ x: Double, _ y: Double) -> Double {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let fx = x - Double(x0), fy = y - Double(y0)
            let a = sample(x0, y0), b = sample(x0 + 1, y0)
            let c = sample(x0, y0 + 1), d = sample(x0 + 1, y0 + 1)
            return a * (1 - fx) * (1 - fy) + b * fx * (1 - fy) + c * (1 - fx) * fy + d * fx * fy
        }
    }

    /// Mean absolute difference between `a` and `b` with `b` rotated by `degrees` about its centre
    /// and then shifted by (`dx`, `dy`), in GRID pixels.
    ///
    /// Sampled on a border-inset window, so a shift does not score itself well merely by moving
    /// content off the edge into the off-page constant.
    static func error(_ a: Grid, _ b: Grid, degrees: Double, dx: Double, dy: Double,
                      inset: Int) -> Double {
        let radians = degrees * .pi / 180
        let cosA = cos(radians), sinA = sin(radians)
        let cx = Double(b.width - 1) / 2, cy = Double(b.height - 1) / 2
        var total = 0.0
        var count = 0
        var y = inset
        while y < a.height - inset {
            var x = inset
            while x < a.width - inset {
                // Map the sample in `a` back into `b`'s frame: undo the translation, then rotate
                // about the centre. Inverse mapping, so every destination sample is filled.
                let ox = Double(x) - dx - cx
                let oy = Double(y) - dy - cy
                let sx = cosA * ox + sinA * oy + cx
                let sy = -sinA * ox + cosA * oy + cy
                total += abs(a.sample(x, y) - b.sample(sx, sy))
                count += 1
                x += 1
            }
            y += 1
        }
        return count == 0 ? 1 : total / Double(count)
    }

    /// The search: a coarse translation sweep, a rotation sweep at the best offset, then a fine
    /// translation refinement at the best angle.
    ///
    /// **Staged rather than a joint sweep over all three**, which would be ~20 million grid
    /// comparisons. Skew and offset are close to separable at this scale — a degree of rotation
    /// moves the page corners by a few grid pixels, which the refinement pass then recovers.
    ///
    /// `scale` converts the grid's pixels back to the full-size image's, so the returned
    /// translation is in the units the caller will apply it in.
    public static func estimate(_ a: Grid, _ b: Grid, scale: Double) -> PageRegistration {
        guard a.width == b.width, a.height == b.height, a.width > 8, a.height > 8 else {
            return .none
        }
        let inset = max(2, a.width / 12)
        let baseline = error(a, b, degrees: 0, dx: 0, dy: 0, inset: inset)
        guard baseline > 0 else { return .none }

        // **Stage 1 — translation, on a downsampled copy.** The sweep's candidate count is
        // quadratic in its span, and an offset is just as visible at a quarter of the resolution.
        let factor = Self.translationDownsample
        let coarseA = a.downsampled(by: factor), coarseB = b.downsampled(by: factor)
        let coarseInset = max(1, coarseA.width / 12)
        let span = max(2, coarseA.width / 8)
        var bestCoarse = (err: error(coarseA, coarseB, degrees: 0, dx: 0, dy: 0, inset: coarseInset),
                          dx: 0.0, dy: 0.0)
        for dy in stride(from: -span, through: span, by: 1) {
            for dx in stride(from: -span, through: span, by: 1) {
                let e = error(coarseA, coarseB, degrees: 0,
                              dx: Double(dx), dy: Double(dy), inset: coarseInset)
                if e < bestCoarse.err { bestCoarse = (e, Double(dx), Double(dy)) }
            }
        }

        // **Stage 2 — angle and offset together, at FULL grid resolution.**
        //
        // Two things are being fixed here at once, and the second was measured rather than
        // foreseen. Full resolution is what makes a degree of skew visible at all (see
        // ``gridWidth``). And the sweep is JOINT — every angle gets its own small translation
        // refinement — because the two parameters are not separable near the optimum: sweeping
        // the angle at one fixed offset walked a 1° + (5, −3) pair into a translation-only local
        // minimum at (−6, 4), 0° with 83% of the error removed, while the true correction removed
        // 91%. Coordinate descent could not leave it, because no single step improved.
        let base = (dx: bestCoarse.dx * Double(factor), dy: bestCoarse.dy * Double(factor))
        var best = (err: error(a, b, degrees: 0, dx: base.dx, dy: base.dy, inset: inset),
                    deg: 0.0, dx: base.dx, dy: base.dy)
        let refine = Double(factor)
        var surface: [(err: Double, deg: Double, dx: Double, dy: Double)] = []
        for step in -8...8 {
            let deg = Double(step) * 0.25
            var dy = base.dy - refine
            while dy <= base.dy + refine {
                var dx = base.dx - refine
                while dx <= base.dx + refine {
                    let e = error(a, b, degrees: deg, dx: dx, dy: dy, inset: inset)
                    surface.append((e, deg, dx, dy))
                    if e < best.err { best = (e, deg, dx, dy) }
                    dx += 1
                }
                dy += 1
            }
        }

        // **Confidence is the PEAK's sharpness, not the improvement's size** — and that distinction
        // was forced by measurement, not chosen for elegance.
        //
        // The first cut scored `(baseline - best) / baseline`: how much of the error alignment
        // removed. On synthetic fixtures the two populations it has to separate overlapped
        // outright — a real 0.5° skew scored **0.183** while two deliberately unrelated pages
        // scored **0.152** and **0.160**. No threshold on that number can accept the first and
        // refuse the others, so the whole "fall back rather than claim an alignment it did not
        // achieve" promise was unkeepable on it.
        //
        // What does separate them is the SHAPE of the error surface. A genuine alignment sits in a
        // sharp well: move half a degree or three pixels off it and the error climbs. Two unrelated
        // pages have a shallow best that is barely better than everything around it, because
        // nothing is actually lining up. So confidence is measured against the best candidate FAR
        // from the winner, and a flat surface scores near zero however much error the winner
        // happened to remove.
        let far = surface
            .filter { abs($0.deg - best.deg) >= 0.75
                        || abs($0.dx - best.dx) >= 3 || abs($0.dy - best.dy) >= 3 }
            .min(by: { $0.err < $1.err })?.err
        // No far candidate means the sweep was degenerate; claim nothing rather than divide by it.
        guard let far, far > 0 else { return .none }
        let confidence = (far - best.err) / far
        return PageRegistration(degrees: best.deg,
                                dx: best.dx * scale, dy: best.dy * scale,
                                confidence: max(0, confidence))
    }
}
