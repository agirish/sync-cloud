import Testing
import AppKit
import SwiftUI
@testable import Design

/// RD46.14 — the text-size tiles host a selection lens: in Frosted and Clear the lens lands exactly
/// on the chosen tile, where Solid draws its accent border and wash, and wears today's border as
/// its ring.
///
/// Rendered with the lens probe (glass draws nothing offscreen — see `SelectionLensTests`), whose
/// ring the probe draws too, so the lens's box is the probe and its ring together. The accent is
/// pinned to blue: the tiles paint `Color.accentColor`, and a Graphite system accent would
/// otherwise leave nothing saturated to find.
@MainActor
@Suite(.serialized) struct SelectionLensSizePresetTests {

    static let canvas = CGSize(width: 440, height: 64)
    static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)

    private struct Row: View {
        @State var fontSize: FontSize
        @State var density: ListDensity
        var body: some View { SizePresetRow(fontSize: $fontSize, density: $density, style: .named) }
    }

    static func rig(_ preset: SizePreset, _ appearance: SelectionLensAppearance) -> ProbeRig<AnyView> {
        ProbeRig(AnyView(Row(fontSize: preset.fontSize, density: preset.density)
            .appFontSize(.medium)
            .frame(width: canvas.width - 20)
            .padding(10)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .background(Color.white)
            .accentColor(.blue)
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            // Pinned, so the machine's own settings cannot decide these tests.
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard)), size: canvas)
    }

    /// The accent's border and labels: strongly coloured, where the row's greys are not. Pink
    /// excluded — the probe is saturated too.
    nonisolated static let isAccent: Pixel.Match = { r, g, b in
        let hi = max(r, g, b), lo = min(r, g, b)
        return Int(hi) - Int(lo) > 90 && !(r > 200 && b > 200)
    }
    nonisolated static let isLens: Pixel.Match = { r, g, b in Pixel.lensProbe(r, g, b) || isAccent(r, g, b) }

    @Test(.machinePinned(.pixelSampling), arguments: [SizePreset.all.first!, SizePreset.all.last!])
    func theLensLandsOnTheChosenTile(preset: SizePreset) throws {
        let marker = try #require(Self.rig(preset, .today).box(Self.isAccent),
                                  "Solid drew no accent border — the fixture is not showing a choice")
        let rig = Self.rig(preset, Self.probe)
        let probe = try #require(rig.box(Pixel.lensProbe), "the probe drew nothing — the tiles host no lens")
        // The lens and its ring together are the tile's border box.
        let lens = try #require(rig.box(rows: marker.minY...marker.maxY, Self.isLens))
        #expect(Pixel.same(marker, lens), "lens \(lens) is not the chosen tile \(marker)")
        // Today's wash stepped aside: inside the ring, a point clear of the labels is the bare
        // probe, (255, 0, 255), to within a couple of steps — exact, rather than `Pixel.lensProbe`'s
        // loose match, which leaves room for a fainter film than the wash to pass unseen.
        let rep = rig.capture()
        let inside = Pixel.at(rep, width: Self.canvas.width, CGPoint(x: probe.minX + 3, y: probe.midY))
        #expect(inside.0 > 252 && inside.1 < 3 && inside.2 > 252,
                "the lens's face is \(inside) — today's wash is drawn over the glass")
    }

    @Test(.machinePinned(.pixelSampling))
    func theLensMovesWithTheChoice() throws {
        let first = try #require(Self.rig(SizePreset.all.first!, Self.probe).box(Pixel.lensProbe))
        let last = try #require(Self.rig(SizePreset.all.last!, Self.probe).box(Pixel.lensProbe))
        #expect(last.minX > first.maxX)
    }

    @Test(.machinePinned(.pixelSampling))
    func aSizeOffTheListHasNoTileAndNoLens() {
        // `matching` answers nil off the list — no tile is lit, so no lens either.
        let off = SizePreset(fontSize: .extraLarge, density: .compact)
        #expect(SizePreset.matching(fontSize: off.fontSize, density: off.density) == nil,
                "the fixture is on the list after all")
        #expect(Self.rig(off, Self.probe).box(Pixel.lensProbe) == nil)
    }
}
