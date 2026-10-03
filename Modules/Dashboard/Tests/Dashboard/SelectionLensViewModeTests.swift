import Testing
import AppKit
import SwiftUI
import Sync
import Design
@testable import Dashboard

/// RD46.7 — Tree · Columns in the pane bar hosts a selection lens: in Frosted and Clear the lens
/// lands exactly where Solid draws today's fill.
///
/// Rendered with the lens probe (glass draws nothing offscreen — see `SelectionLensTests` in
/// Design) and compared, pixel box for pixel box, with the Solid render's accent fill. Preview is
/// off in the fixture because the Preview pill borrows the same fill when it is on, and would be
/// counted as part of the marker.
@MainActor
@Suite(.serialized) struct SelectionLensViewModeTests {

    static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)
    static let size = CGSize(width: 660, height: 92)

    static func header(_ mode: PaneViewMode, preview: Bool = false) -> some View {
        let defaults = ScratchDefaults("SelectionLensViewModeTests-header")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        return PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(mode), previewEnabled: .constant(preview), onNewFolder: {})
        .defaultAppStorage(defaults)
    }

    /// The pane bar on white, pinned to the light scheme and an active window.
    static func rig(_ mode: PaneViewMode, preview: Bool = false,
                    appearance: SelectionLensAppearance) -> ProbeRig<AnyView> {
        ProbeRig(AnyView(header(mode, preview: preview)
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            // Pinned, so the machine's own settings cannot decide these tests.
            .environment(\._accessibilityReduceTransparency, false)
            .environment(\._colorSchemeContrast, .standard)
            .frame(width: size.width, height: size.height)
            .background(Color.white)), size: size)
    }

    /// Today's fill: Blue's deepened accent, matched loosely enough to survive the render's colour
    /// shift — measured, `(0.2, 0.5, 1.0)` comes back as `(0.22, 0.53, 0.92)` — and strictly
    /// enough that nothing else in the header (inks, grounds, the white backdrop) comes near it. If
    /// anything did, the fill's box would outgrow the lens's and the comparison below would say so.
    nonisolated static let isTodaysFill: Pixel.Match = Pixel.near(LiquidGlassHue.blue.accentFillColor)

    @Test(.machinePinned(.pixelSampling), arguments: [PaneViewMode.tree, .columns])
    func theLensLandsWhereTodaysFillIs(mode: PaneViewMode) throws {
        let solid = Self.rig(mode, appearance: .today).capture()
        let fill = try #require(Pixel.box(solid, width: Self.size.width, Self.isTodaysFill),
                                "Solid drew no fill — the fixture is not showing the switch")
        let glass = Self.rig(mode, appearance: Self.probe)
        let lens = try #require(glass.box(Pixel.lensProbe), "the probe drew nothing — Tree · Columns hosts no lens")
        #expect(Pixel.same(fill, lens), "lens \(lens) is not today's fill \(fill)")
        // And the fill stepped aside for it.
        #expect(glass.box(Self.isTodaysFill) == nil)
        // The chosen glyph: white on Solid's fill, black on light-mode glass (`selectionLensLabelInk`).
        // Inset 4pt: a capsule leaves its box's corners to the ground behind it.
        #expect(Pixel.count(solid, width: Self.size.width, in: fill, Pixel.whiteInk) > 5,
                "Solid's chosen glyph is not white on its fill")
        let face = lens.insetBy(dx: 4, dy: 4), rep = glass.capture()
        let white = Pixel.count(rep, width: Self.size.width, in: face, Pixel.whiteInk)
        let dark = Pixel.count(rep, width: Self.size.width, in: face, Pixel.blackInk)
        #expect(white == 0 && dark > 5, "the chosen glyph on glass is not dark — \(white) white, \(dark) dark pixels")
    }

    @Test(.machinePinned(.pixelSampling))
    func theLensMovesWithTheMode() throws {
        let tree = try #require(Self.rig(.tree, appearance: Self.probe).box(Pixel.lensProbe))
        let columns = try #require(Self.rig(.columns, appearance: Self.probe).box(Pixel.lensProbe))
        #expect(columns.minX > tree.maxX - 1)
    }
}
