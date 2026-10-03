import Testing
import AppKit
import SwiftUI
import Sync
import Design
@testable import Dashboard

/// Chrome glass on the pane bar (RD46 follow-up, 2026-10-03): in Frosted and Clear every pill sits
/// in a glass capsule, like Finder's toolbar; Back and Forward share one; Preview has one even when
/// it is off; Solid draws none.
///
/// Rendered through the real `PaneHeader` with the probe — glass draws nothing offscreen, so the
/// probe paints a bar button's glass cyan and the selection lens magenta — and read along the pill
/// row as runs of either. The View switch's lens sits inside the switch's own glass track, so the
/// two read as one run, which is what they are on screen.
@MainActor
@Suite(.serialized) struct ChromeGlassPaneBarTests {

    static let size = CGSize(width: 660, height: 92)
    static let frosted = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)
    static let solid = SelectionLensAppearance(level: .solid, hue: .blue, tint: 0, drawsProbe: true)

    static func render(_ appearance: SelectionLensAppearance, preview: Bool = false) -> NSBitmapImageRep {
        SelectionLensViewModeTests.rig(.tree, preview: preview, appearance: appearance).capture()
    }

    /// The pieces of glass along the pill row, in points: a column counts if any pixel in the
    /// row's band is chrome glass (cyan) or the lens (magenta) — read across the band rather than
    /// along one row, because a row through the middle is cut up by the glyphs drawn on the glass.
    /// The band is the first block of rows that holds any glass at all.
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
        // Back/Forward, Sort, the View switch, Hidden files, Scan, New Folder and Preview — one
        // piece each. Fewer is a pill that lost its glass; more is a pair split in two.
        try #require(runs.count == 7, "\(runs.count) pieces of glass on the bar, want 7: \(runs)")
        func width(_ run: ClosedRange<CGFloat>) -> CGFloat { run.upperBound - run.lowerBound }
        // A single pill's glass: the narrowest run short of Preview, which is the last (the View
        // switch's track and the pair are wider).
        let pill = try #require(runs.dropLast().map(width).min())
        // Back and Forward as ONE capsule: a run exactly two pills and the gap between them wide.
        // Apart, they read as two pill-wide runs, and nothing else on the bar is that width — the
        // View switch's track, the nearest, measured 67pt against the pair's 72.
        let pair = 2 * pill + PaneNavMetrics.pairSpacing
        #expect(runs.contains { abs(width($0) - pair) <= 1.5 },
                "no \(pair)pt run for Back and Forward together — two capsules, not one: \(runs)")
        // Preview is the bar's last control, and has glass even while it is off — a pill's width,
        // like its neighbours', though its own pill gave up the segment inset to its ON fill.
        let last = try #require(runs.last)
        #expect(abs(width(last) - pill) <= 1.01, "Preview's glass is \(width(last))pt, not a pill's \(pill): \(runs)")
    }

    /// **Preview ON keeps its fill, on the glass.** A toggle has no position to say it is on — only
    /// its fill — and the first glass version traded the fill for a tint that all but vanished at
    /// Tint 0 and vanished entirely at accent None, so ON and OFF read the same. The fill is
    /// opaque and sits inside Preview's glass, the segment inset in from it on each side.
    @Test(.machinePinned(.pixelSampling))
    func previewOnKeepsItsFillOnTheGlass() throws {
        let isFill = SelectionLensViewModeTests.isTodaysFill
        let off = Self.render(Self.frosted)
        let on = Self.render(Self.frosted, preview: true)
        let glass = try #require(Self.pillRow(off).last, "no glass on the bar")
        #expect(Pixel.box(off, width: Self.size.width, isFill) == nil, "Preview OFF drew a fill")
        let fill = try #require(Pixel.box(on, width: Self.size.width, isFill), "Preview ON drew no fill under glass")
        let inset = PaneNavMetrics.segmentInset / 2
        #expect(abs(fill.minX - (glass.lowerBound + inset)) <= 1.5 && abs(fill.maxX - (glass.upperBound - inset)) <= 1.5,
                "the accent fill \(fill) is not inset \(inset)pt inside Preview's glass \(glass)")
    }

    /// **Hover is painted on the glass.** A glass pill has no resting grey — the glass is its
    /// ground — but hover and press still wash it in the accent, or the pointer gets no answer.
    /// The wash is the chrome's own (`PaneNavChrome`), drawn inside the button, so it sits over the
    /// glass the button wears outside: read here as the probe's cyan tinted toward the accent.
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
