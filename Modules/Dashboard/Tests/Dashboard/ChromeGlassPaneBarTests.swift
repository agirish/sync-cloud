import Testing
import AppKit
import SwiftUI
import Sync
import Design
@testable import Dashboard

/// Chrome glass on the pane bar: in Frosted and Clear every pill sits in a glass capsule, like
/// Finder's toolbar; Back and Forward share one; Solid draws none. Glass draws nothing offscreen,
/// so the probe paints a bar button's glass cyan and the selection lens magenta; the View switch's
/// lens sits inside its own glass track, so the two read as one run, as on screen.
@MainActor
@Suite(.serialized) struct ChromeGlassPaneBarTests {

    static let size = CGSize(width: 660, height: 92)
    static let frosted = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)
    static let solid = SelectionLensAppearance(level: .solid, hue: .blue, tint: 0, drawsProbe: true)

    static func render(_ appearance: SelectionLensAppearance) -> NSBitmapImageRep {
        SelectionLensViewModeTests.rig(.tree, appearance: appearance).capture()
    }

    /// The pieces of glass along the pill row, in points. A column counts if any pixel in the row's
    /// band is glass (cyan) or lens (magenta), read across the band because the glyphs cut up any
    /// single row. The band is the first block of rows holding any glass.
    static func pillRow(_ rep: NSBitmapImageRep) -> [ClosedRange<CGFloat>] {
        let isGlass: Pixel.Match = { r, g, b in Pixel.chromeProbe(r, g, b) || Pixel.lensProbe(r, g, b) }
        guard let band = Pixel.rowRuns(rep, width: size.width, isGlass).first else { return [] }
        return Pixel.columnRuns(rep, width: size.width, rows: band.minY...band.maxY, isGlass)
            .map { $0.minX...$0.maxX }
    }

    @Test(.machinePinned(.pixelSampling))
    func solidDrawsNoGlassOnTheBar() {
        #expect(Self.pillRow(Self.render(Self.solid)).isEmpty)
    }

    @Test(.machinePinned(.pixelSampling))
    func everyPillSitsInGlassAndBackAndForwardShareOne() throws {
        let runs = Self.pillRow(Self.render(Self.frosted))
        // Back/Forward, Sort, the View switch, Hidden files, Scan and New Folder, one piece each.
        // Fewer is a pill that lost its glass; more is a pair split in two.
        try #require(runs.count == 6, "\(runs.count) pieces of glass on the bar, want 6: \(runs)")
        func width(_ run: ClosedRange<CGFloat>) -> CGFloat { run.upperBound - run.lowerBound }
        // A single pill's glass: the narrowest run (the View switch's track and the pair are wider).
        let pill = try #require(runs.map(width).min())
        // Back and Forward as one capsule: a run two pills and their gap wide. Nothing else on the
        // bar is that wide (the View switch's track is a few points narrower).
        let pair = 2 * pill + PaneNavMetrics.pairSpacing
        #expect(runs.contains { abs(width($0) - pair) <= 1.5 },
                "no \(pair)pt run for Back and Forward together — two capsules, not one: \(runs)")
    }

    /// Hover is painted on the glass: a glass pill has no resting grey, but hover and press still
    /// wash it in the accent, or the pointer gets no answer. `PaneNavChrome`'s wash is drawn inside
    /// the button over its glass, so it reads as cyan tinted toward the accent.
    @Test(.machinePinned(.pixelSampling))
    func hoverWashesTheGlass() throws {
        func pill(_ phase: HoverAffordancePhase) -> ProbeRig<AnyView> {
            ProbeRig(AnyView(Color.clear
                .paneNavChrome(accent: LiquidGlassHue.blue.accentColor, controlSize: .regular)
                .environment(\.hoverAffordancePhase, phase)
                .paneNavGlass()
                .padding(10)
                .frame(width: 80, height: 50, alignment: .topLeading)
                .background(Color.white)
                .environment(\.selectionLensAppearance, Self.frosted)
                .environment(\.colorScheme, .light)
                .environment(\._accessibilityReduceTransparency, false)), size: CGSize(width: 80, height: 50))
        }
        let rest = pill(.rest)
        let glass = try #require(rest.box(Pixel.chromeProbe), "the pill drew no glass at rest")
        let centre = CGPoint(x: glass.midX, y: glass.midY)
        let bare = Pixel.at(rest.capture(), width: 80, centre)
        let hovered = Pixel.at(pill(.hover).capture(), width: 80, centre)
        // The accent at 0.22 over cyan pulls green down by ~30 and leaves blue; bare glass is unmoved.
        #expect(Int(bare.1) - Int(hovered.1) > 15,
                "hover left the glass bare — \(bare) at rest, \(hovered) hovered")
    }
}
