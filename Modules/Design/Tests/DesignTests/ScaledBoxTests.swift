import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Design

/// The rule for sizing a box drawn around a scaled glyph. A `.scaledFont` glyph grows with
/// Settings ▸ Text size; a hard `.frame` around it doesn't, and since `.frame` doesn't clip, the
/// surplus draws straight out of the box.
///
/// - `fittingSize` is not the overflow test: it includes side bearings, overstating the ink by
///   3–5pt. ``GlyphInk/outside(symbol:point:weight:box:shape:scale:)`` renders the ink and decides.
/// - A hit target (`CloseButton` and the like) is rightly a constant, as long as it still holds its
///   glyph's ink at Largest: ``theCloseButtonsReservationStillHoldsItsGlyph``.
@Suite @MainActor struct ScaledBoxTests {

    /// The four named presets, the axis the arithmetic assertions move along.
    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    /// Every step the slider lands on, for the ink check: all ten stops from 90 to 135, not just
    /// the four presets. A boundary can turn over between presets (`docs/backports.md` records one
    /// at 130), which a four-row table would miss.
    private var everySelectableScale: [CGFloat] {
        FontSize.selectablePercents.map { FontSize(percent: $0).scale }
    }

    // MARK: The rule

    /// At the default text size the box is exactly its base size, so a site that adopts
    /// `scaledBox` keeps its 100% layout and needs no re-audit.
    @Test func theDefaultSizeIsTheBoxUnchanged() {
        for box in [CGFloat(12), 13, 14, 21, 22, 26, 30, 34] {
            for point in [CGFloat(9), 10, 11, 12, 22] {
                #expect(FontSize.scaledBox(box, basePoint: point, scale: 1) == box,
                        "a \(box)pt box around a \(point)pt glyph moved at the default text size")
            }
        }
    }

    /// The box never shrinks as the text grows. A pinned frame passes this half and fails the one
    /// below.
    @Test func theBoxNeverShrinksAsTheTextGrows() {
        for box in [CGFloat(13), 14, 21, 34] {
            for point in [CGFloat(9), 10, 11, 12, 22] {
                let widths = scales.map { FontSize.scaledBox(box, basePoint: point, scale: $0) }
                #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 },
                        "a \(box)/\(point) box measures \(widths) across \(scales) — it shrinks as the text grows")
            }
        }
    }

    /// The box and its glyph move together, ruling out `box * scale`: above ``FontSize/knee`` the
    /// ramp damps and clamps, so a bare multiply grows a box around a glyph that has stopped
    /// growing. Asserting the ratio keeps this independent of both constants.
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

    /// The clamp above the knee: a 22pt glyph doesn't grow past Default, so neither may its disc.
    /// `SetupStepGlyph`'s 34 is this row.
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

    /// The number is applied, not merely returned: a frame laid out through `NSHostingView` reads
    /// back the rule's width. The bound is asymmetric because `fittingSize` rounds a fractional frame
    /// up to the next point (26.25 comes back as 27), so a symmetric `± 0.51` would fail on rounding.
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
    /// Rounding that collapsed two sizes onto one number would make every rendered growth check
    /// vacuous.
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

    /// `CloseButton`'s 26×26 is a hit target and stays a constant, which is safe only while the box
    /// still holds the glyph inside it. The `xmark` draws 8.0 · 9.0 · 11.0 · 12.0pt of ink inside
    /// 26pt across the presets, a large margin; raise its 11pt glyph far enough and this fails.
    @Test(.machinePinned(.pixelSampling))
    func theCloseButtonsReservationStillHoldsItsGlyph() {
        for scale in everySelectableScale {
            let out = GlyphInk.outside(symbol: "xmark", point: 11, weight: .semibold,
                                       box: 26, shape: Rectangle(), scale: scale)
            #expect(out <= GlyphInk.tolerance,
                    "the close button's xmark puts \(out)pt² of ink outside its 26pt target at scale \(scale)")
        }
    }

    /// The positive control for every "clean" verdict here: a detector that stopped seeing ink would
    /// return 0 everywhere, so it is shown a box that is too small (about 15pt² outside) and must
    /// report well over ``GlyphInk/tolerance``.
    @Test(.machinePinned(.pixelSampling))
    func theInkMeasurementCanActuallySeeAnOverflow() {
        // `person.2` at 22pt in a 30pt disc, too small for it.
        let shipped = GlyphInk.outside(symbol: "person.2", point: 22, weight: .regular,
                                       box: 30, shape: Circle(), scale: 1)
        #expect(shipped > 10,
                "the shipped 30pt disc reports only \(shipped)pt² of ink outside it — the measurement is blind, so every clean verdict beside it is worthless")

        // ...and the 34pt disc `SetupSheet` uses is clean, measured the same way.
        let fixed = GlyphInk.outside(symbol: "person.2", point: 22, weight: .regular,
                                     box: 34, shape: Circle(), scale: 1)
        #expect(fixed <= GlyphInk.tolerance,
                "the 34pt disc still puts \(fixed)pt² of ink outside it")
    }
}

// MARK: - Ink

/// Reads glyph ink back out of a live renderer and asks whether any of it fell outside the box.
///
/// A symbol's laid-out width includes its side bearings, so `Image(systemName: "house")` reports
/// 23pt at Largest while drawing 18pt of ink; `fittingSize` can't tell an overflow. Overflow is a
/// claim about ink, so it is measured as one: the box painted on its own, the glyph drawn on its
/// own in the identical layout, and the answer is the ink the paint doesn't cover.
enum GlyphInk {

    /// Set between the renderer's fringe and a real overflow: a glyph centred in a fractional box
    /// inks a fraction of a point past the edge. The worst fringe on a correctly sized box measured
    /// 2.5pt² and real overflows 10.8 to 21.0pt², so 4 sits clear of both.
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
                // Solid ink only: a faint antialiased fringe is not what is being measured.
                guard g.redComponent < 0.5, g.greenComponent < 0.5, g.blueComponent < 0.5 else { continue }
                if !(t.greenComponent > t.redComponent + 0.15) { loose += 1 }
            }
        }
        return CGFloat(loose) / (density * density)
    }
}
