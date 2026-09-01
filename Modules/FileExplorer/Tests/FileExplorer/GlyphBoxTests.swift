import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// Every box this package draws around a scaled glyph — the ones that grow with the text and the
/// ones that deliberately do not.
///
/// **The bug this file is written against passed every test that existed.** `EditorModeBar` framed
/// its symbols at a hard `13×13`, and `EditorLayoutTests` asked whether the capsule grew with the
/// app's text size — of the *labelled* rung, whose words are `Text` and which therefore scaled the
/// whole time. The glyph-only rung, the one made entirely of those frames, measured 85pt at Small,
/// Default, Large and Largest alike and nothing looked. A repo-wide sweep on 2026-08-31 then found
/// the same shape in Organize's pass-lens row.
///
/// So the rule here is: **measure the pinned dimension itself, not a rung that contains it.** A
/// composed row's width is mostly text, and text scales; asking a row whether it grew answers about
/// the text and says nothing about the box beside it. Both suites below measure a view whose width
/// *is* the box.
///
/// The second half is the half `fittingSize` cannot do. `Image(systemName:)` reports its symbol's
/// layout box, bearings included, which overstates the drawn ink by 3–5pt at these sizes — so
/// "does it overflow" is asked of rendered ink, through ``GlyphInk``.
@MainActor
@Suite(.serialized) struct GlyphBoxTests {

    /// The four named presets — the axis the *growth* assertions move along, where what is being
    /// asked is "does this change at all" and four points answer it.
    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    /// **Every step the slider actually lands on, which is what containment is asked over.**
    ///
    /// `FontSize.allCases` is the four *named* presets; `selectablePercents` is all ten stops from
    /// 90 to 135. The difference is not academic here — `docs/backports.md` records the Editor
    /// capsule's shedding boundary turning over at **130**, which is not a preset, so a four-row
    /// table reported "Large fits, Largest does not" and left the step that mattered unmeasured.
    /// A box that holds its glyph at 125 and 135 but not at 130 is exactly the shape that would
    /// slip through, so the ink checks below sweep the ten rather than the four.
    private var everySelectableScale: [CGFloat] {
        FontSize.selectablePercents.map { FontSize(percent: $0).scale }
    }

    private func width<V: View>(_ view: V, _ scale: CGFloat) -> CGFloat {
        NSHostingView(rootView: AnyView(view.environment(\.appFontScale, scale))).fittingSize.width
    }

    // MARK: The pass-lens column

    /// **The column grows across as well as down** — the failure that shipped here was one axis.
    ///
    /// `passLensRow` framed its lens symbol `.frame(width: 14)` with no height, so the box followed
    /// the type ramp downward and sat still sideways: 14×12 at Small and 14×16 at Largest. Measuring
    /// the row would not have caught it, because the row's other two children are `Text` and grew
    /// the whole time; measuring ``PassLensGlyph`` does, because its width is nothing but the box.
    @Test func thePassLensColumnGrowsWithTheAppsTextSize() {
        let widths = scales.map { width(PassLensGlyph(symbol: OrganizeLens.renames.symbol), $0) }
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 },
                "the pass-lens column measures \(widths) across \(scales) — it shrinks as the text grows")
        #expect((widths.last ?? 0) > (widths.first ?? 0),
                "the pass-lens column measures \(widths) across \(scales) — it is not scaling")
    }

    /// **The default text size still draws what it drew before the fix.** The pass cards are a
    /// shipped screen and this change was not supposed to move them at 100%; `boxSize` is still 14
    /// and the ramp is the identity at scale 1, so the assertion is that both remain true together.
    @Test func thePassLensColumnIsUnchangedAtTheDefaultTextSize() {
        #expect(PassLensGlyph.box(at: 1) == PassLensGlyph.boxSize)
        #expect(PassLensGlyph.boxSize == 14, "the shipped column was 14pt — moving it moves every pass card")
    }

    /// Every symbol the column can actually be asked to draw, at every size.
    ///
    /// **Built from `OrganizeLens.allCases`, not a list** — a seventh lens is a symbol this has to
    /// hold the day it is added, and a hand-written list is the thing that would not notice.
    @Test(.machinePinned(.pixelSampling))
    func thePassLensColumnHoldsEveryLensSymbol() {
        for lens in OrganizeLens.allCases {
            for scale in everySelectableScale {
                let out = GlyphInk.outside(symbol: lens.symbol, point: PassLensGlyph.pointSize,
                                           weight: .semibold, box: PassLensGlyph.box(at: scale),
                                           shape: Rectangle(), scale: scale)
                #expect(out <= GlyphInk.tolerance,
                        "\(lens)'s \(lens.symbol) puts \(out)pt² of ink outside the pass-lens column at scale \(scale)")
            }
        }
    }

    // MARK: The mode capsules

    /// ``CapsuleGlyph`` is the fix this sweep followed, and its box is checked the same way its
    /// sibling's is — every symbol either bar can put in it, at every text size.
    @Test(.machinePinned(.pixelSampling))
    func theCapsuleGlyphHoldsEverySymbolBothBarsDraw() {
        let symbols = EditorMode.allCases.map(\.symbol) + StorageSection.allCases.map(\.railSymbol)
        for symbol in symbols {
            for scale in everySelectableScale {
                let out = GlyphInk.outside(symbol: symbol, point: CapsuleGlyph.pointSize,
                                           weight: .medium, box: CapsuleGlyph.box(at: scale),
                                           shape: Rectangle(), scale: scale)
                #expect(out <= GlyphInk.tolerance,
                        "\(symbol) puts \(out)pt² of ink outside the capsule glyph box at scale \(scale)")
            }
        }
    }

    /// The box is applied, not merely computed — the same guard `ScaledBoxTests` puts on the rule,
    /// asked of the two views that consume it.
    @Test func bothGlyphViewsLayOutTheBoxTheyAdvertise() {
        for scale in scales {
            let capsule = width(CapsuleGlyph(symbol: EditorMode.edit.symbol), scale)
            #expect(capsule >= CapsuleGlyph.box(at: scale) - 0.01
                        && capsule < CapsuleGlyph.box(at: scale) + 1.01,
                    "CapsuleGlyph advertises \(CapsuleGlyph.box(at: scale))pt and lays out at \(capsule)pt at scale \(scale)")

            let lens = width(PassLensGlyph(symbol: OrganizeLens.toFile.symbol), scale)
            #expect(lens >= PassLensGlyph.box(at: scale) - 0.01
                        && lens < PassLensGlyph.box(at: scale) + 1.01,
                    "PassLensGlyph advertises \(PassLensGlyph.box(at: scale))pt and lays out at \(lens)pt at scale \(scale)")
        }
    }

    // MARK: The reservations

    /// **Four framed glyphs in this package are hit targets and stay constants. This is the check
    /// that keeps that a fact rather than an assumption.**
    ///
    /// The 2026-08-31 sweep measured every square frame around a single symbol and fixed two. These
    /// four it deliberately left alone: their frames exist to give a pointer something to hit, and a
    /// pointer does not grow with the text size, so pinning them is right. That reasoning holds only
    /// while the box is still big enough for the glyph inside it — measured at Largest, the rail's
    /// `plus` draws 12.5pt of ink in 18, the fold-all toggles 18 in 24, the section chevron 11 in 12
    /// and the destination grip 12 in 16. Raise any of those glyphs and this says so.
    @Test(.machinePinned(.pixelSampling))
    func theHitTargetsStillHoldTheirGlyphs() {
        struct Reservation {
            let site: String, symbols: [String], point: CGFloat, box: CGFloat
        }
        let reservations = [
            Reservation(site: "DifferencesView.collapseToggle",
                        symbols: ["chevron.up", "chevron.down"], point: 12, box: 24),
            // Both cases named rather than swept: `FoldAllAction` is not `CaseIterable` and making
            // it so for a test is not this change's business. The symbols still come off the type.
            Reservation(site: "DifferencesView.foldAllToggle",
                        symbols: [FoldAllAction.collapse, .expand].map(\.systemImage),
                        point: 12, box: 24),
            Reservation(site: "DifferencesView section chevron",
                        symbols: ["chevron.right", "chevron.down"], point: 9, box: 12),
            Reservation(site: "EditorFileRailView new-file plus",
                        symbols: ["plus"], point: 11, box: 18),
            Reservation(site: "DestinationPicker resize grip",
                        symbols: ["line.diagonal"], point: 11, box: 16),
        ]
        for r in reservations {
            for symbol in r.symbols {
                for scale in everySelectableScale {
                    let out = GlyphInk.outside(symbol: symbol, point: r.point, weight: .semibold,
                                               box: r.box, shape: Rectangle(), scale: scale)
                    #expect(out <= GlyphInk.tolerance,
                            "\(r.site) puts \(out)pt² of \(symbol)'s ink outside its \(r.box)pt target at scale \(scale) — it is no longer a reservation, it is a pin")
                }
            }
        }
    }

    /// The positive control. Every "clean" above is a zero, and a blind detector returns zeros for
    /// everything — so it is shown the defect this branch fixed and required to report it.
    @Test(.machinePinned(.pixelSampling))
    func theInkMeasurementCanActuallySeeAnOverflow() {
        // The pass-lens column as it shipped: a hard 14, at the largest text size. It measured
        // 21.0pt² when this was written, so the floor is well clear of `tolerance` rather than
        // just past it — a control that only barely trips is a control that stops tripping.
        let shipped = GlyphInk.outside(symbol: OrganizeLens.renames.symbol, point: 10,
                                       weight: .semibold, box: 14, shape: Rectangle(), scale: 1.35)
        #expect(shipped > 10,
                "the shipped hard-14 column reports only \(shipped)pt² outside it — the measurement is blind, so every clean verdict beside it is worthless")

        // And the same column at the DEFAULT size was clean, which is why this went unseen for as
        // long as it did — and why scaling it changes no shipped rendering at 100%.
        let atDefault = GlyphInk.outside(symbol: OrganizeLens.renames.symbol, point: 10,
                                         weight: .semibold, box: 14, shape: Rectangle(), scale: 1)
        #expect(atDefault <= GlyphInk.tolerance,
                "the hard-14 column was already overflowing at the default size (\(atDefault)pt²) — then this fix is not the whole story")
    }
}

// MARK: - Ink

/// Reads glyph ink back out of a live renderer and asks whether any of it fell outside the box.
///
/// **Duplicated from `Modules/Design/Tests/DesignTests/ScaledBoxTests.swift`**, for the reason
/// `MachinePinned.swift` in this directory is duplicated: SPM has no way to share test-support code
/// across packages without minting a production library product, and this must stay test-only.
/// Change one, change both.
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
