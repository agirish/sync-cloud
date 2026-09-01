import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Design

/// The rule for sizing a box drawn around a scaled glyph — and the property that tells a
/// **reservation** from a **pin**.
///
/// **Written after a sweep that found the same defect three times.** `EditorModeBar` and
/// `StorageSectionBar` drew their symbols inside a hard `13×13` frame; the glyphs were
/// `.scaledFont`-ed and grew with Settings ▸ Text size, the boxes did not, and since `.frame` does
/// not clip the surplus drew straight out of the box. A repo-wide scan for that shape on
/// 2026-08-31 turned up roughly 45 `.scaledFont` + `.frame(width:)` pairs, of which fourteen were a
/// square box around a single SF Symbol. Measuring every one of them is what this file's rules came
/// out of, and the measurements matter as much as the verdict:
///
/// - **`fittingSize` is not the overflow test.** `Image(systemName:)` reports its symbol's layout
///   box, side bearings included, which overstates the drawn ink by 3–5pt at these sizes. Six of
///   the fourteen sites look like overflows under `fittingSize` and are clean when the ink is
///   actually rendered and read back. ``GlyphInk/outside(symbol:point:weight:box:shape:scale:)``
///   below is the test that decides.
/// - **A hit target is not a pinned box.** Six sites frame a glyph to give a pointer something to
///   hit — `CloseButton`, both `DifferencesView` toggles, the Editor rail's `plus`, the destination
///   grip, Settings' disclosure chevron. A pointer does not grow with the text size, so those
///   frames are right to be constants. What makes them *reservations* rather than pins is that they
///   still hold their glyph's ink at Largest, which is a property, not an opinion — so
///   ``theCloseButtonsReservationStillHoldsItsGlyph`` asserts it rather than asserting nothing.
@Suite @MainActor struct ScaledBoxTests {

    /// The four named presets — the axis the arithmetic assertions move along.
    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    /// **Every step the slider actually lands on**, for the ink check. `FontSize.allCases` is the
    /// four named presets; this is all ten stops from 90 to 135. `docs/backports.md` records the
    /// Editor capsule's shedding boundary turning over at 130 — not a preset — so a four-row table
    /// reported "Large fits, Largest does not" and left the step that mattered unmeasured.
    private var everySelectableScale: [CGFloat] {
        FontSize.selectablePercents.map { FontSize(percent: $0).scale }
    }

    // MARK: The rule

    /// **The default text size renders exactly what it rendered before.** Every site that adopts
    /// `scaledBox` is a site whose 100% layout must not move, so this is the assertion that lets
    /// the fixes land without re-auditing the shipped screens.
    @Test func theDefaultSizeIsTheBoxUnchanged() {
        for box in [CGFloat(12), 13, 14, 21, 22, 26, 30, 34] {
            for point in [CGFloat(9), 10, 11, 12, 22] {
                #expect(FontSize.scaledBox(box, basePoint: point, scale: 1) == box,
                        "a \(box)pt box around a \(point)pt glyph moved at the default text size")
            }
        }
    }

    /// **The box never goes backwards as the text grows**, which is the half a pinned frame passes
    /// and the half below is the one it fails.
    @Test func theBoxNeverShrinksAsTheTextGrows() {
        for box in [CGFloat(13), 14, 21, 34] {
            for point in [CGFloat(9), 10, 11, 12, 22] {
                let widths = scales.map { FontSize.scaledBox(box, basePoint: point, scale: $0) }
                #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 },
                        "a \(box)/\(point) box measures \(widths) across \(scales) — it shrinks as the text grows")
            }
        }
    }

    /// **The box and its glyph move together, or the whole exercise is theatre.**
    ///
    /// This is the assertion that rules out the obvious wrong fix — `box * scale`. Above
    /// ``FontSize/knee`` the ramp damps and then clamps, so a bare multiply opens a box around a
    /// glyph that has stopped growing: at 22pt and Largest it would draw a 40.5pt disc around a
    /// symbol still rendering at 22pt, which is the `SetupSheet` mark's exact geometry. Asserting
    /// the *ratio* rather than the value is what makes this independent of either constant.
    @Test func theBoxHoldsItsGlyphsProportionAtEverySize() {
        for box in [CGFloat(13), 14, 21, 34] {
            for point in [CGFloat(9), 10, 11, 12, 22] {
                for scale in scales {
                    let boxed = FontSize.scaledBox(box, basePoint: point, scale: scale)
                    let glyph = FontSize.scaledPointSize(point, scale: scale)
                    #expect(abs(boxed / glyph - box / point) < 0.0001,
                            "a \(box)/\(point) box is \(boxed) around a \(glyph)pt glyph at \(scale) — the two have come apart")
                }
            }
        }
    }

    /// The clamp above the knee, stated as the case it was written for: a 22pt glyph does not grow
    /// past Default, so neither may its disc. `SetupStepGlyph`'s 34 is this row.
    @Test func aGlyphThatStopsGrowingTakesItsBoxWithIt() {
        let discs = scales.map { FontSize.scaledBox(34, basePoint: 22, scale: $0) }
        #expect(discs[0] < discs[1], "the disc did not shrink at the small text size")
        #expect(discs[1] == discs[2] && discs[2] == discs[3],
                "the disc measures \(discs) — it is still growing past the point its glyph stops at")
    }

    /// A zero or negative `basePoint` returns the box rather than dividing by it.
    @Test func anImpossibleBaseReturnsTheBox() {
        #expect(FontSize.scaledBox(21, basePoint: 0, scale: 1.35) == 21)
        #expect(FontSize.scaledBox(21, basePoint: -3, scale: 1.35) == 21)
    }

    // MARK: The rule, laid out rather than computed

    /// **The number is applied, not merely returned.** Every assertion above is arithmetic on a
    /// static function, and a static function with no caller is exactly the failure this sweep
    /// exists because of. This lays a frame out through `NSHostingView` and reads the width back,
    /// so a `scaledBox` that computed correctly and was never wired to a `.frame` fails here.
    ///
    /// **Bounded above by a whole point, not by half of one**, because `fittingSize` rounds a
    /// fractional frame *up* to the next point rather than to the nearer one: 26.25 comes back as
    /// 27 and 28.35 as 29. A symmetric `± 0.51` fails on both, which is the renderer's rounding
    /// and not the rule's answer — so the bound is asymmetric and says which direction it allows.
    @Test func aFrameBuiltFromTheRuleReallyMeasuresIt() {
        for scale in scales {
            let want = FontSize.scaledBox(21, basePoint: 11, scale: scale)
            let got = NSHostingView(rootView: Color.clear
                .frame(width: FontSize.scaledBox(21, basePoint: 11, scale: scale), height: 4)
                .environment(\.appFontScale, scale)).fittingSize.width
            #expect(got >= want - 0.01 && got < want + 1.01,
                    "a box the rule says is \(want)pt laid out at \(got)pt at scale \(scale)")
        }
    }

    /// The companion to the tolerance above: the laid-out widths still tell the four sizes apart.
    /// Rounding up to the next point is harmless here and would not be if it collapsed two sizes
    /// onto one number — that would make every rendered growth assertion in this sweep vacuous.
    @Test func roundingDoesNotCollapseTwoTextSizesOntoOneWidth() {
        let widths = scales.map { scale in
            NSHostingView(rootView: Color.clear
                .frame(width: FontSize.scaledBox(21, basePoint: 11, scale: scale), height: 4)
                .environment(\.appFontScale, scale)).fittingSize.width
        }
        #expect(Set(widths).count == scales.count,
                "the four text sizes lay a 21/11 box out at \(widths) — rounding has merged two of them")
    }

    // MARK: A reservation, asserted rather than assumed

    /// **`CloseButton`'s 26×26 is a hit target and stays a constant — this is why that is safe.**
    ///
    /// The sweep left six framed glyphs alone on the grounds that their boxes are pointer targets,
    /// which have no reason to track the type ramp. That reasoning is only sound while the box is
    /// still big enough for the glyph inside it, and nothing checked: measured 2026-08-31 the
    /// `xmark` draws 8.0 · 9.0 · 11.0 · 12.0pt of ink inside 26pt, so the margin is large and the
    /// verdict holds. Raise `CloseButton`'s 11pt glyph far enough and this is what says so.
    @Test(.machinePinned(.pixelSampling))
    func theCloseButtonsReservationStillHoldsItsGlyph() {
        for scale in everySelectableScale {
            let out = GlyphInk.outside(symbol: "xmark", point: 11, weight: .semibold,
                                       box: 26, shape: Rectangle(), scale: scale)
            #expect(out <= GlyphInk.tolerance,
                    "the close button's xmark puts \(out)pt² of ink outside its 26pt target at scale \(scale)")
        }
    }

    /// **The positive control for every "clean" verdict in this sweep.**
    ///
    /// `GlyphInk.outside` returning 0 is the answer six sites depend on, and a detector that had
    /// silently stopped seeing ink — a threshold that stopped matching, a render that came back
    /// blank — would return 0 for all of them and read as a clean bill of health. So it is shown a
    /// box that is definitely too small, and required to say so. The numbers are the real ones:
    /// `SetupSheet`'s mark drew 15pt² outside a 30pt disc before this branch, which is why the
    /// control asks for meaningfully more than ``GlyphInk/tolerance``.
    @Test(.machinePinned(.pixelSampling))
    func theInkMeasurementCanActuallySeeAnOverflow() {
        // `person.2` at 22pt in the 30pt disc SetupSheet shipped — the defect this sweep fixed.
        let shipped = GlyphInk.outside(symbol: "person.2", point: 22, weight: .regular,
                                       box: 30, shape: Circle(), scale: 1)
        #expect(shipped > 10,
                "the shipped 30pt disc reports only \(shipped)pt² of ink outside it — the measurement is blind, so every clean verdict beside it is worthless")

        // ...and the diameter this branch replaced it with is clean, measured the same way.
        let fixed = GlyphInk.outside(symbol: "person.2", point: 22, weight: .regular,
                                     box: 34, shape: Circle(), scale: 1)
        #expect(fixed <= GlyphInk.tolerance,
                "the 34pt disc still puts \(fixed)pt² of ink outside it")
    }
}

// MARK: - Ink

/// Reads glyph ink back out of a live renderer and asks whether any of it fell outside the box.
///
/// **The measurement `fittingSize` cannot make.** A symbol's laid-out width includes its side
/// bearings, so `Image(systemName: "house")` reports 23pt at Largest while drawing 18pt of ink —
/// and six of the fourteen sites in the 2026-08-31 sweep are "overflows" by the first number and
/// clean by the second. Overflow is a claim about ink, so it is measured as one: the box is painted
/// once on its own, the glyph is drawn once on its own in the identical layout, and the answer is
/// the ink the paint does not cover.
enum GlyphInk {

    /// **Set from the measured gap between the renderer's fringe and a real overflow, not by
    /// taste.** A glyph is centred in a box whose scaled width is usually fractional, so its ink
    /// lands a fraction of a point past the nominal edge and the outermost column of pixels is
    /// partially covered. Swept on 2026-08-31 over every symbol the mode capsules, the storage
    /// capsule and the pass-lens column can draw, at all four text sizes, the worst such fringe on
    /// a **correctly sized** box was 2.5pt² — `clock.badge.exclamationmark`, at the default size,
    /// spilling under a point on its right edge. `eye` shows the same 0.3–0.5pt edge at *every*
    /// size including Small, which is what identifies it as the renderer rather than a fit problem.
    ///
    /// The overflows this sweep actually fixed measured **10.8 and 21.0pt²** (the pass-lens column
    /// at Large and Largest) and **13 and 15pt²** (`SetupSheet`'s mark at Default and above). So 4
    /// sits with 1.6× clearance above the worst fringe and 2.7× below the smallest real defect —
    /// wide on both sides, rather than tuned to whatever number made a test go green.
    static let tolerance: CGFloat = 4

    /// Area of glyph ink, in pt², falling outside `shape` drawn at `box`.
    @MainActor
    static func outside<S: Shape>(symbol: String, point: CGFloat, weight: Font.Weight,
                                  box: CGFloat, shape: S, scale: CGFloat) -> CGFloat {
        let pad: CGFloat = 30
        func bitmap<V: View>(_ view: V) -> (NSBitmapImageRep, CGFloat)? {
            let host = NSHostingView(rootView: AnyView(
                view.environment(\.appFontScale, scale).padding(pad).background(Color.white)))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return (rep, CGFloat(rep.pixelsWide) / host.bounds.width)
        }

        // The box alone, painted a colour nothing else in either render uses...
        let painted = Color.clear.frame(width: box, height: box).background(shape.fill(Color.green))
        // ...and the glyph alone, in the identical frame, so the two bitmaps line up pixel for
        // pixel and "outside" is a per-pixel question rather than a bounding-box approximation.
        let inked = Image(systemName: symbol)
            .scaledFont(.system(size: point, weight: weight))
            .foregroundStyle(Color.black)
            .frame(width: box, height: box)

        guard let (tile, density) = bitmap(painted), let (glyph, _) = bitmap(inked),
              tile.pixelsWide == glyph.pixelsWide, tile.pixelsHigh == glyph.pixelsHigh else {
            Issue.record("could not render \(symbol) at \(point)pt in a \(box)pt box")
            return .infinity
        }

        var loose = 0
        for y in 0..<glyph.pixelsHigh {
            for x in 0..<glyph.pixelsWide {
                guard let g = glyph.colorAt(x: x, y: y), let t = tile.colorAt(x: x, y: y) else { continue }
                // Solid ink only — a faint antialiased fringe is not the thing being measured.
                guard g.redComponent < 0.5, g.greenComponent < 0.5, g.blueComponent < 0.5 else { continue }
                if !(t.greenComponent > t.redComponent + 0.15) { loose += 1 }
            }
        }
        return CGFloat(loose) / (density * density)
    }
}
