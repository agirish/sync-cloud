import AppKit
import Design
import Foundation
import SwiftUI
import Testing
@testable import SyncCloud

/// The setup card's step mark — the one glyph box in this sweep that was wrong at 100%.
///
/// **Every other site in the 2026-08-31 glyph-box sweep failed only away from the default text
/// size. This one failed at it.** The mark was `.frame(width: 30, height: 30)` behind a `Circle()`
/// around a 22pt symbol, and two of the five step symbols do not fit that: rendered and diffed
/// against the disc, `person.2` put **15pt² of ink outside the circle** and `folder.badge.gearshape`
/// **13pt²**, at Default, Large and Largest alike. `.frame` does not clip, so the second figure's
/// shoulder drew on the card behind the disc, on the first screen a new user sees.
///
/// **And it is not a text-size bug**, which is the part worth stating: 22pt is above
/// `FontSize.knee`, so the ramp clamps it and the glyph renders at 22pt for Default, Large *and*
/// Largest. Scaling a 30pt box would have left every one of those sizes exactly as broken. The
/// diameter had to change, and 34 is the smallest that holds all five symbols clean — 30 leaves
/// 15pt² out and 32 still leaves 6pt², measured the same way.
///
/// `.pixelSampling`, like every suite here that reads a live renderer back.
@MainActor
@Suite(.serialized) struct SetupStepGlyphTests {

    /// The four named presets — the axis the *growth* assertion moves along.
    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    /// **Every step the slider actually lands on, which is what containment is asked over.**
    /// `FontSize.allCases` is the four named presets; this is all ten stops from 90 to 135.
    /// `docs/backports.md` records the Editor capsule's shedding boundary turning over at 130 —
    /// not a preset — so a four-row table left the step that mattered unmeasured. A disc that
    /// holds its glyph at 125 and 135 but not at 130 is the shape that would slip through.
    private var everySelectableScale: [CGFloat] {
        FontSize.selectablePercents.map { FontSize(percent: $0).scale }
    }

    /// **Every step symbol, at every text size, drawn inside its disc.**
    ///
    /// Swept from `SetupFlow.Step.allCases` rather than a list: a sixth step is a symbol this has to
    /// hold the day it is added, and that is exactly the kind of addition a hand-written list would
    /// wave through. The box comes off ``SetupStepGlyph`` too, so shrinking the disc or enlarging
    /// the glyph is caught here rather than on someone's screen.
    @Test(.machinePinned(.pixelSampling))
    func theDiscHoldsEveryStepSymbolAtEveryTextSize() {
        for step in SetupFlow.Step.allCases {
            for scale in everySelectableScale {
                let out = GlyphInk.outside(symbol: step.symbolName, point: SetupStepGlyph.pointSize,
                                           weight: .regular, box: SetupStepGlyph.box(at: scale),
                                           shape: Circle(), scale: scale)
                #expect(out <= GlyphInk.tolerance,
                        "\(step)'s \(step.symbolName) puts \(out)pt² of ink outside the step disc at scale \(scale)")
            }
        }
    }

    /// **The defect, still measurable, so the fix cannot be quietly undone.**
    ///
    /// This is the positive control the rest of the file depends on — a blind measurement returns
    /// zero for everything and reads as a clean bill of health. It is shown the disc that shipped
    /// and required to report it, and the numbers are far enough apart that this is a verdict
    /// rather than a threshold: 15pt² against a 4pt² tolerance.
    @Test(.machinePinned(.pixelSampling))
    func theDiscThatShippedIsStillMeasurablyTooSmall() {
        let shipped = GlyphInk.outside(symbol: SetupFlow.Step.people.symbolName, point: 22,
                                       weight: .regular, box: 30, shape: Circle(), scale: 1)
        #expect(shipped > 10,
                "the 30pt disc reports only \(shipped)pt² of person.2's ink outside it — the measurement is blind, so every clean verdict in this file is worthless")

        let fixed = GlyphInk.outside(symbol: SetupFlow.Step.people.symbolName, point: 22,
                                     weight: .regular, box: SetupStepGlyph.boxSize, shape: Circle(), scale: 1)
        #expect(fixed <= GlyphInk.tolerance,
                "the \(SetupStepGlyph.boxSize)pt disc still puts \(fixed)pt² of ink outside it")
    }

    /// **The disc stops exactly where its glyph stops.**
    ///
    /// The obvious wrong fix is `30 * scale`, and at this point size it is obviously wrong: the
    /// glyph clamps at 22pt from Default upward, so a flat multiply would open a 46pt disc around a
    /// symbol that never grew past 22. Asking `FontSize.scaledBox` instead gives one step — smaller
    /// at Small, identical everywhere above — and that shape is what is asserted, rather than four
    /// literals that would need re-recording whenever the ramp moves.
    @Test func theDiscTracksTheGlyphRatherThanTheScale() {
        let discs = scales.map { SetupStepGlyph.box(at: $0) }
        #expect(zip(discs, discs.dropFirst()).allSatisfy { $0 <= $1 },
                "the step disc measures \(discs) across \(scales) — it shrinks as the text grows")
        #expect((discs.last ?? 0) > (discs.first ?? 0),
                "the step disc measures \(discs) across \(scales) — it is pinned")
        for scale in scales {
            let ratio = SetupStepGlyph.box(at: scale) / FontSize.scaledPointSize(SetupStepGlyph.pointSize, scale: scale)
            #expect(abs(ratio - SetupStepGlyph.boxSize / SetupStepGlyph.pointSize) < 0.0001,
                    "at scale \(scale) the disc and its glyph have come apart")
        }
    }

    /// **The disc is laid out, not merely computed.** A static function that returns the right
    /// number and is wired to nothing is precisely the failure this sweep came out of, so the view
    /// is hosted and its width read back.
    @Test func theViewLaysOutTheDiscItAdvertises() {
        for scale in scales {
            let want = SetupStepGlyph.box(at: scale)
            let got = NSHostingView(rootView: AnyView(
                SetupStepGlyph(symbol: SetupFlow.Step.people.symbolName)
                    .environment(\.appFontScale, scale))).fittingSize.width
            // `fittingSize` rounds a fractional frame up to the next whole point — 30.6 comes back
            // as 31 — so the bound is asymmetric and says which direction it allows.
            #expect(got >= want - 0.01 && got < want + 1.01,
                    "SetupStepGlyph advertises \(want)pt and lays out at \(got)pt at scale \(scale)")
        }
    }
}

// MARK: - Ink

/// Reads glyph ink back out of a live renderer and asks whether any of it fell outside the box.
///
/// **Duplicated from `Modules/Design/Tests/DesignTests/ScaledBoxTests.swift`**, for the reason
/// `MachinePinned.swift` in this directory is duplicated: SPM has no way to share test-support code
/// across packages without minting a production library product, and this must stay test-only.
/// Change one, change all three (Design, FileExplorer, here).
enum GlyphInk {

    /// **Set from the measured gap between the renderer's fringe and a real overflow, not by
    /// taste.** A glyph is centred in a box whose scaled width is usually fractional, so its ink
    /// lands a fraction of a point past the nominal edge and the outermost column of pixels is
    /// partially covered. Swept on 2026-08-31, the worst such fringe on a **correctly sized** box
    /// was 2.5pt². The overflows this sweep fixed measured 10.8 and 21.0pt² (Organize's pass-lens
    /// column) and 13 and 15pt² (the step disc below). 4 is wide of both.
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

        let painted = Color.clear.frame(width: box, height: box).background(shape.fill(Color.green))
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
                guard g.redComponent < 0.5, g.greenComponent < 0.5, g.blueComponent < 0.5 else { continue }
                if !(t.greenComponent > t.redComponent + 0.15) { loose += 1 }
            }
        }
        return CGFloat(loose) / (density * density)
    }
}
