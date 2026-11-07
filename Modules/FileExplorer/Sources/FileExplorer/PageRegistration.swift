import CoreGraphics
import Foundation

/// A best-effort estimate of how one scanned page sits relative to the other: a small rotation and
/// a translation, recovered by correlating the two at a coarse scale.
///
/// Without it, the pixel modes compare pages by their frames alone, so two scans of one sheet, the
/// most common real pair, glow all over from a half-degree of skew.
///
/// Deliberately crude: no feature detection and no dependency, just a downsampled luminance grid,
/// a translation search, then a small rotation sweep. Enough for scanner skew (a degree or two and
/// a few millimetres). A pair needing more gets low confidence, and the diff falls back to
/// comparing frames and says so, rather than claiming an alignment it didn't achieve.
public struct PageRegistration: Equatable, Sendable {
    /// Rotation in degrees, positive counter-clockwise, applied about the image centre.
    public let degrees: Double
    /// Translation in pixels of the full-size image, applied after the rotation.
    public let dx: Double
    public let dy: Double
    /// How sharply the error surface falls away around the winning transform: 0 is a flat surface
    /// where the best candidate is barely better than everything near it, 1 would be a perfect
    /// spike. Measured against the best candidate far from the winner; see
    /// ``PageRegistrationEstimator/estimate(_:_:scale:)``.
    ///
    /// **Not how much error the alignment removed**, and that is the feature's whole safety: by
    /// improvement, a real 0.5° skew scored 0.183 while unrelated pages scored 0.152 and 0.160, so
    /// no threshold could separate them. The feature is gated on this, not on the transform: a
    /// confident-looking rotation between two different pages is the failure to prevent.
    public let confidence: Double

    /// Whether this estimate is worth applying — see ``confidence``.
    ///
    /// 0.35 is a measured floor, in the empty band between the populations: a search always returns
    /// a best candidate, and unrelated synthetic pages score around 0.15–0.16, while real pairs
    /// score far higher (a pure translation above 0.5, a 1° skew with an offset at 0.906).
    public var isUsable: Bool { confidence >= 0.35 && (degrees != 0 || dx != 0 || dy != 0) }

    /// The sentence that replaces the difference mode's "with no alignment" caveat when this
    /// registration was applied — nil when it says nothing worth saying.
    ///
    /// "Best effort" because the method is a coarse correlation built for scanner skew; a reader
    /// told only "aligned" would read the remaining glow as content.
    ///
    /// Thresholded so it never claims a correction too small to see: tiny angles and sub-pixel
    /// shifts are what the search returns for pages already aligned, and would read as a finding.
    public var caption: String? {
        let angle = abs(degrees) >= 0.25 ? String(format: "%.2f°", abs(degrees)) : nil
        let moved = abs(dx) >= 1 || abs(dy) >= 1
        let parts = [angle.map { "a \($0) skew" }, moved ? "an offset" : nil].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "Aligned before comparing — \(ComparePairFacts.list(parts)) corrected, best effort."
    }

    /// The identity: what a pair that needs no alignment, or admits none, reports.
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
/// Pure, over a plain luminance grid rather than `CGImage`, so the search is testable on synthetic
/// transforms with no rendering in the loop: the only way to know it recovers a rotation it was
/// given, rather than merely producing a number.
public enum PageRegistrationEstimator {

    /// The width both pages are reduced to before searching.
    ///
    /// 256, measured: a 1° rotation moves the page edge by `height/2 × tan(1°)`, about 1.1 pixels
    /// at 96 wide, which is under the bilinear filter's own smoothing, so a coarser grid recovers
    /// translation but not skew. At 256 the edge moves ~3 pixels, which correlates. The cost is
    /// paid back by searching translation at a coarser scale; see ``estimate(_:_:scale:)``.
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
    /// and then shifted by (`dx`, `dy`), in grid pixels.
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

    /// The search: a coarse translation sweep on a downsampled copy, then a joint sweep of angle
    /// and a small translation refinement around that offset, at full grid resolution.
    ///
    /// Staged rather than one sweep over all three at full resolution, which would be ~20 million
    /// grid comparisons; the coarse stage finds the offset, and the second stage only refines it.
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

        // Stage 1: translation, on a downsampled copy. The candidate count is quadratic in the
        // span, and an offset is just as visible at a quarter of the resolution.
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

        // Stage 2: angle and offset together, at full grid resolution, which is what makes a
        // degree of skew visible (see ``gridWidth``). Joint, every angle with its own translation
        // refinement, because the two aren't separable near the optimum: sweeping the angle at a
        // fixed offset can settle in a translation-only local minimum no single step escapes.
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

        // **Gate on the peak's sharpness, never the improvement's size.** By improvement,
        // `(baseline - best) / baseline`, a real skew and two unrelated pages overlapped, so no
        // threshold could separate them. A genuine alignment sits in a sharp well: half a degree or
        // three pixels off it, the error climbs. Unrelated pages have a shallow best, so confidence
        // is measured against the best candidate far from the winner, and a flat surface scores
        // near zero however much error the winner removed.
        //
        // A known weakness: `dx`/`dy` step in whole grid pixels (6.25 full pixels at the 1600px
        // compare raster), so a true offset near half-way between two candidates splits the well
        // and the score collapses, though the angle is exact; about a third of vertical offsets
        // fall in such a band. Every such failure is a refusal, an honest unaligned comparison,
        // never a wrong alignment. A sub-pixel refinement would fix it but changes what `far` is
        // measured against, the gate `docs/backports.md` says must not be weakened; do it with
        // numbers in hand.
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
