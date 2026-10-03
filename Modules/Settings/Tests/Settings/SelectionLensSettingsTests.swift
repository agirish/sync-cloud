import Testing
import AppKit
import SwiftUI
import Design
@testable import Settings

/// The Settings controls that host a selection lens (roadmap RD46): in Frosted and Clear the lens
/// lands exactly where Solid draws today's marker.
///
/// Rendered with the lens probe (glass draws nothing offscreen — see `SelectionLensTests` in Design)
/// and compared, box for box, with the Solid render's marker.
@MainActor
@Suite(.serialized) struct SelectionLensSettingsTests {

    static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)

    /// `view` at `size` on white, pinned to the light scheme and an active window.
    static func rig<V: View>(_ view: V, size: CGSize, appearance: SelectionLensAppearance) -> ProbeRig<AnyView> {
        ProbeRig(AnyView(view
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            // Pinned, so the machine's own settings cannot decide these tests.
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.white)), size: size)
    }

    /// The bounding box of the pixels matching `match` — in the rows `rows` spans when given, so a
    /// colour painted elsewhere in the view cannot widen it.
    static func box<V: View>(_ view: V, size: CGSize, appearance: SelectionLensAppearance,
                             rows: ClosedRange<CGFloat>? = nil, _ match: Pixel.Match) -> CGRect? {
        rig(view, size: size, appearance: appearance).box(rows: rows, match)
    }

    static func expectSameBox(_ marker: CGRect?, _ lens: CGRect?, _ what: String,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        guard let marker, let lens else {
            Issue.record("\(what): marker \(String(describing: marker)), lens \(String(describing: lens))",
                         sourceLocation: sourceLocation)
            return
        }
        #expect(Pixel.same(marker, lens), "\(what): lens \(lens) is not today's marker \(marker)",
                sourceLocation: sourceLocation)
    }

    // MARK: - RD46.8 · Settings rail

    static let railSize = CGSize(width: SettingsRail.width, height: 520)

    static func tabList(_ tab: SettingsView.SettingsTab, query: String = "") -> some View {
        SettingsRail.TabList(selection: .constant(tab), query: .constant(query), hue: .blue)
    }

    @Test(.machinePinned(.pixelSampling), arguments: [SettingsView.SettingsTab.general, .advanced])
    func theRailsLensLandsOnTheSelectedRow(tab: SettingsView.SettingsTab) {
        let fill = Pixel.near(LiquidGlassHue.blue.accentFillColor)
        let solid = Self.rig(Self.tabList(tab), size: Self.railSize, appearance: .today).capture()
        let glass = Self.rig(Self.tabList(tab), size: Self.railSize, appearance: Self.probe).capture()
        let marker = Pixel.box(solid, width: Self.railSize.width, fill)
        let lens = Pixel.box(glass, width: Self.railSize.width, Pixel.lensProbe)
        Self.expectSameBox(marker, lens, "\(tab)")
        #expect(Pixel.box(glass, width: Self.railSize.width, fill) == nil, "today's fill must step aside for the lens")
        // The chosen row's label: white on Solid's fill, black on light-mode glass (`selectionLensLabelInk`).
        // Inset 4pt, clear of the rounded corners.
        guard let marker, let lens else { return }
        #expect(Pixel.count(solid, width: Self.railSize.width, in: marker, Pixel.whiteInk) > 10,
                "\(tab): Solid's chosen label is not white on its fill")
        let face = lens.insetBy(dx: 4, dy: 4)
        let white = Pixel.count(glass, width: Self.railSize.width, in: face, Pixel.whiteInk)
        let dark = Pixel.count(glass, width: Self.railSize.width, in: face, Pixel.blackInk)
        #expect(white == 0 && dark > 10, "\(tab): the chosen label on glass is not dark — \(white) white, \(dark) dark pixels")
    }

    @Test(.machinePinned(.pixelSampling))
    func searchingLeavesNoRowSelectedAndNoLens() {
        #expect(Self.box(Self.tabList(.general, query: "font"), size: Self.railSize,
                         appearance: Self.probe, Pixel.lensProbe) == nil)
    }

    // MARK: - RD46.15 · Accent swatches

    static let accentSize = CGSize(width: 547, height: 200)

    static func accentRow(_ hue: LiquidGlassHue) -> some View {
        AccentColorSection(selectedHue: hue, onSelect: { _ in })
    }

    /// The halo as the probe draws it, in its two parts — measured raw: today's ring on its rim,
    /// 40% black over the probe, about `(155, 16, 178)`; and inside it the 1pt gap left showing
    /// before the swatch, the probe under the swatch's shadow, about `(221, 21, 254)` — short of
    /// `Pixel.lensProbe`'s floor, so neither part is matched by it. No swatch is that magenta.
    nonisolated static let isRing: Pixel.Match = { r, g, b in (130...190).contains(r) && (150...205).contains(b) && g < 60 }
    nonisolated static let isGap: Pixel.Match = { r, g, b in r > 200 && b > 230 && g < 60 }
    nonisolated static let isHalo: Pixel.Match = { r, g, b in isRing(r, g, b) || isGap(r, g, b) }

    /// The halo: a disc `outset` past the chosen swatch on every side, centred on it — and today's
    /// ring gone from the swatch. The probe is drawn BEHIND the swatch, so its box is the halo's.
    ///
    /// The swatch is found by its own colour as RENDERED — sampled 10pt above the halo's centre,
    /// clear of the checkmark — and matched tightly, in the halo's rows only (the preview strip
    /// below paints the accent too). A nominal colour with a loose tolerance does not work here:
    /// today's ring is the accent under 40% black, and for Green the render's colour shift put
    /// that within ±0.12 of the nominal value, so the ring counted as swatch.
    @Test(.machinePinned(.pixelSampling), arguments: [LiquidGlassHue.blue, .green, .rose])
    func theHaloRingsTheChosenSwatch(hue: LiquidGlassHue) throws {
        let row = Self.accentRow(hue)
        let glass = Self.rig(row, size: Self.accentSize, appearance: Self.probe)
        let halo = try #require(glass.box(Self.isHalo), "the probe drew nothing — the accent row hosts no lens")
        let rows = halo.minY...halo.maxY
        let solid = Self.rig(row, size: Self.accentSize, appearance: .today)
        let fill = Pixel.at(solid.capture(), width: Self.accentSize.width, CGPoint(x: halo.midX, y: halo.midY - 10))
        let isSwatch: Pixel.Match = { r, g, b in
            abs(Int(r) - Int(fill.0)) <= 10 && abs(Int(g) - Int(fill.1)) <= 10 && abs(Int(b) - Int(fill.2)) <= 10
        }
        let swatch = try #require(glass.box(rows: rows, isSwatch), "no \(hue) swatch inside the halo's rows")
        let outset = AccentColorSection.lensStyle.outset
        #expect(outset > 0, "a halo with no outset sits wholly behind the swatch and cannot be seen")
        Self.expectSameBox(swatch.insetBy(dx: -outset, dy: -outset), halo, "\(hue) halo")
        // The ring is the halo's rim: the gap inside it is the ring's width short of the halo.
        Self.expectSameBox(halo.insetBy(dx: HueOptionView.ringWidth, dy: HueOptionView.ringWidth),
                           glass.box(rows: rows, Self.isGap), "\(hue) — the halo's ring")
        // In Solid the swatch is short of the full disc by today's ring, which `strokeBorder` paints
        // over its outer 2pt; under the halo the ring is gone and the disc is whole.
        Self.expectSameBox(swatch.insetBy(dx: HueOptionView.ringWidth, dy: HueOptionView.ringWidth),
                           solid.box(rows: rows, isSwatch),
                           "\(hue) — today's ring is drawn in Solid and stepped aside under the halo")
    }

    @Test func theHaloIsNeverTinted() {
        // It rings a colour, so it must not wear one — at Tint 100 as at 0.
        #expect(AccentColorSection.lensStyle.markerOpacity == 0)
        #expect(SelectionLensRule.tintOpacity(markerOpacity: AccentColorSection.lensStyle.markerOpacity,
                                              hue: .rose, tint: 1) == 0)
    }

    @Test(.machinePinned(.pixelSampling))
    func theHaloMovesWithTheChoice() throws {
        let blue = try #require(Self.box(Self.accentRow(.blue), size: Self.accentSize,
                                         appearance: Self.probe, Self.isHalo))
        let green = try #require(Self.box(Self.accentRow(.green), size: Self.accentSize,
                                         appearance: Self.probe, Self.isHalo))
        #expect(green.minX > blue.maxX)
    }
}
