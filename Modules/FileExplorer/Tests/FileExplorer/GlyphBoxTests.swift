import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// Every box this package draws around a scaled glyph: the ones that grow with the text and the
/// ones that deliberately do not.
///
/// Measure the pinned dimension itself, not a row that contains it: a row's width is mostly text,
/// which scales, and says nothing about a hard-framed symbol beside it. So these measure a view
/// whose width *is* the box.
///
/// Overflow is asked of rendered ink, through ``GlyphInk``, not `fittingSize`: `Image(systemName:)`
/// reports its layout box, bearings included, which overstates the drawn ink by 3–5pt here.
@MainActor
@Suite(.serialized) struct GlyphBoxTests {

    /// The four named presets: enough to ask whether a size changes at all.
    private var scales: [CGFloat] { FontSize.allCases.map(\.scale) }

    /// All ten slider stops from 90 to 135, which containment is asked over: the Editor capsule's
    /// shedding boundary turns over at 130 (see `docs/backports.md`), not a preset, so a box failing
    /// only there would slip past the four presets.
    private var everySelectableScale: [CGFloat] {
        FontSize.selectablePercents.map { FontSize(percent: $0).scale }
    }

    private func width<V: View>(_ view: V, _ scale: CGFloat) -> CGFloat {
        NSHostingView(rootView: AnyView(view.environment(\.appFontScale, scale))).fittingSize.width
    }

    // MARK: The pass-lens column

    /// The column grows across as well as down: a symbol framed `.frame(width: 14)` alone follows
    /// the type ramp downward but not sideways. Measured on ``PassLensGlyph``, whose width is the box,
    /// because the row's `Text` children grow anyway.
    @Test func thePassLensColumnGrowsWithTheAppsTextSize() {
        let widths = scales.map { width(PassLensGlyph(symbol: OrganizeLens.renames.symbol), $0) }
        #expect(zip(widths, widths.dropFirst()).allSatisfy { $0 <= $1 },
                "the pass-lens column measures \(widths) across \(scales) — it shrinks as the text grows")
        #expect((widths.last ?? 0) > (widths.first ?? 0),
                "the pass-lens column measures \(widths) across \(scales) — it is not scaling")
    }

    /// The pass cards must not move at 100%: `boxSize` is 14 and the ramp is the identity at scale 1.
    @Test func thePassLensColumnIsUnchangedAtTheDefaultTextSize() {
        #expect(PassLensGlyph.box(at: 1) == PassLensGlyph.boxSize)
        #expect(PassLensGlyph.boxSize == 14, "the shipped column was 14pt — moving it moves every pass card")
    }

    /// Every symbol the column can draw, at every size. Built from `OrganizeLens.allCases`, so a new
    /// lens is checked the day it is added.
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

    /// ``CapsuleGlyph``'s box holds every symbol either bar can put in it, at every text size.
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

    /// The box is applied, not merely computed, by both views that consume it.
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

    /// The framed glyphs that are hit targets stay constants (a pointer does not grow with the text
    /// size), which is right only while the box still holds the glyph inside it at every size.
    @Test(.machinePinned(.pixelSampling))
    func theHitTargetsStillHoldTheirGlyphs() {
        struct Reservation {
            let site: String, symbols: [String], point: CGFloat, box: CGFloat
        }
        let reservations = [
            Reservation(site: "DifferencesView.collapseToggle",
                        symbols: ["chevron.up", "chevron.down"], point: 12, box: 24),
            // Both cases named: `FoldAllAction` is not `CaseIterable`. The symbols come off the type.
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

    /// The positive control: a blind detector returns zeros for everything, so it is shown a real
    /// overflow and required to report it.
    @Test(.machinePinned(.pixelSampling))
    func theInkMeasurementCanActuallySeeAnOverflow() {
        // A hard 14 at the largest text size overflows well clear of `tolerance`: a control that
        // only barely trips is a control that stops tripping.
        let shipped = GlyphInk.outside(symbol: OrganizeLens.renames.symbol, point: 10,
                                       weight: .semibold, box: 14, shape: Rectangle(), scale: 1.35)
        #expect(shipped > 10,
                "the shipped hard-14 column reports only \(shipped)pt² outside it — the measurement is blind, so every clean verdict beside it is worthless")

        // The same column at the default size is clean.
        let atDefault = GlyphInk.outside(symbol: OrganizeLens.renames.symbol, point: 10,
                                         weight: .semibold, box: 14, shape: Rectangle(), scale: 1)
        #expect(atDefault <= GlyphInk.tolerance,
                "the hard-14 column was already overflowing at the default size (\(atDefault)pt²) — then this fix is not the whole story")
    }
}

// MARK: - Ink

/// Reads glyph ink back out of a live renderer and asks whether any of it fell outside the box.
///
/// Duplicated from `Modules/Design/Tests/DesignTests/ScaledBoxTests.swift`. Change one, change both.
enum GlyphInk {

    /// Set from the measured gap between the renderer's fringe and a real overflow. A glyph centred
    /// in a fractional-width box lands a fraction of a point past the edge; the worst such fringe on
    /// a correctly sized box is 2.5pt², and the smallest real overflow about 10.8pt², so 4 sits
    /// clear of both.
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
