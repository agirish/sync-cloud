import Testing
import AppKit
import SwiftUI
import Design
@testable import Sync
@testable import FileExplorer

/// RD46.3 — Organize's rail hosts a selection lens: in Frosted and Clear the lens lands exactly on
/// the selected item, where Solid draws its wash and 2pt ring — and wears that ring itself.
///
/// Mounted through the real `LensWorkspaceView`, because the host is the rail's own row inside its
/// scroll view — a test of `RailItemLabel` alone would pass with the host missing. The manager has
/// no findings, so nothing on the rail but the selected item's ring and glyph wears the accent, and
/// the ring's box is the item's box. The probe draws the lens's ring too, so in glass the item's
/// box is the probe and its ring together.
@MainActor
@Suite(.serialized) struct SelectionLensOrganizeRailTests {

    nonisolated static let canvas = CGSize(width: 1400, height: 620)
    /// Row 1, where the rail is. Anything below — the readout, the lens content — is not searched.
    nonisolated static let railBand: ClosedRange<CGFloat> = 0...60

    static func mount(lens: OrganizeLens?, appearance: SelectionLensAppearance) -> ProbeRig<AnyView> {
        let defaults = ScratchDefaults("SelectionLensOrganizeRailTests")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        if let lens {
            defaults.set(lens.rawValue, forKey: OrganizeLens.defaultsKey)
        } else {
            defaults.removeObject(forKey: OrganizeLens.defaultsKey)
        }
        let subject = LensWorkspaceView(syncManager: FileSyncManager(), lens: .filing, providerName: "Projects",
                                        scanTargetFolder: "/root/Downloads", onFindDuplicates: {},
                                        onUpdateFolderMemory: {}, onConfigureCloudRefine: {},
                                        providerRoot: nil)
            .defaultAppStorage(defaults)
            .environment(\.selectionLensAppearance, appearance)
            .environment(\.controlActiveState, .active)
            .frame(width: canvas.width, height: canvas.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        return ProbeRig(AnyView(subject), size: canvas)
    }

    /// Blue's raw accent — the ring's colour — allowing for the render's shift.
    nonisolated static let isRing: Pixel.Match = { r, g, b in
        abs(Int(r) - 51) < 31 && abs(Int(g) - 128) < 31 && abs(Int(b) - 255) < 31
    }
    nonisolated static let isLens: Pixel.Match = { r, g, b in Pixel.lensProbe(r, g, b) || isRing(r, g, b) }
    static let probe = SelectionLensAppearance(level: .frosted, hue: .blue, tint: 0, drawsProbe: true)

    @Test(.machinePinned(.pixelSampling), arguments: [OrganizeLens?.none, .duplicates])
    func theLensLandsOnTheSelectedItem(lens: OrganizeLens?) throws {
        let ring = try #require(Self.mount(lens: lens, appearance: .today).box(rows: Self.railBand, Self.isRing),
                                "Solid drew no ring on the rail")
        let rig = Self.mount(lens: lens, appearance: Self.probe)
        try #require(rig.box(rows: Self.railBand, Pixel.lensProbe),
                     "the probe drew nothing — Organize's rail hosts no lens")
        let lensBox = try #require(rig.box(rows: Self.railBand, Self.isLens))
        #expect(Pixel.same(ring, lensBox), "lens \(lensBox) is not the selected item \(ring)")
        // And it wears the ring: accent at the lens's own edge, beside the probe.
        let rep = rig.capture()
        let edge = Pixel.at(rep, width: Self.canvas.width, CGPoint(x: lensBox.midX, y: lensBox.minY + 0.5))
        #expect(Self.isRing(edge.0, edge.1, edge.2), "the lens's top edge is \(edge) — no ring on the glass")
    }

    @Test(.machinePinned(.pixelSampling))
    func theLensMovesWithTheSelection() throws {
        let all = try #require(Self.mount(lens: nil, appearance: Self.probe).box(rows: Self.railBand, Pixel.lensProbe))
        let duplicates = try #require(Self.mount(lens: .duplicates, appearance: Self.probe)
                                        .box(rows: Self.railBand, Pixel.lensProbe))
        #expect(duplicates.minX > all.maxX)
    }
}
