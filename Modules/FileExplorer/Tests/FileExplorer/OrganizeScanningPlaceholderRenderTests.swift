import Testing
import SwiftUI
import AppKit
import Design
import Sync
@testable import FileExplorer

/// Organize's two scanning screens, the duplicate pass and the file pass, must paint their
/// spinner, status line and Cancel button onto the lens surface and nothing else. A material card
/// has nothing to blur on an empty lens, so it renders as a flat gray slab. The pane's placeholder
/// is covered by `PaneScanningPlaceholderRenderTests`; this is the Organize half.
///
/// Renders over a magenta backdrop and counts the non-backdrop pixels below the chip header: about
/// 12k–15k for ink and the Cancel capsule, about 75k with a card. The floor catches a canvas that
/// renders nothing. `.machinePinned(.pixelSampling)`, like its sibling, because both ends of the
/// count move with font rasterization and backing scale.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct OrganizeScanningPlaceholderRenderTests {

    private static let canvas = CGSize(width: 700, height: 520)
    /// Everything below the lens chips — the region the placeholder is centered in. Kept clear of
    /// the header so the chips' own fills never enter the count.
    private static let contentBand = CGRect(x: 0, y: 110, width: 700, height: 410)

    /// Non-backdrop pixels in the content band of a scanning lens.
    private func paintedInBand(lens: WorkspaceLensKind, chip: OrganizeLens,
                               appearance: NSAppearance.Name,
                               scanning: (FileSyncManager) -> Void) throws -> Int {
        let manager = FileSyncManager()
        scanning(manager)

        // One scratch suite per render, not one per suite: both tests write the SAME key
        // (`OrganizeLens.defaultsKey`) with different values, and a shared suite would leave
        // whichever ran second deciding which lens the first one rendered.
        let defaults = ScratchDefaults("OrganizeScanning-\(chip.rawValue)-\(appearance.rawValue)")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        defaults.set(chip.rawValue, forKey: OrganizeLens.defaultsKey)

        let subject = LensWorkspaceView(syncManager: manager, lens: lens, providerName: "Projects",
                               scanTargetFolder: "/root/Documents", onFindDuplicates: {},
                               onBuildStorage: {})
            .defaultAppStorage(defaults)
        // Behind the lens, not over it: anything the placeholder fills hides the magenta.
        let (host, window) = ReviewLensHost.mount(subject, size: Self.canvas, appearance: appearance,
                                                  background: Color(red: 1, green: 0, blue: 1), passes: 2)

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: Self.contentBand))
        withExtendedLifetime(window) { host.cacheDisplay(in: Self.contentBand, to: rep) }

        var painted = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let isBackdrop = c.redComponent > 0.98 && c.greenComponent < 0.02 && c.blueComponent > 0.98
                if !isBackdrop { painted += 1 }
            }
        }
        return painted
    }

    enum Scan: Sendable { case duplicates, files }

    @Test(arguments: [Scan.duplicates, .files], [NSAppearance.Name.aqua, .darkAqua])
    func theScanScreenPaintsNoCardOfItsOwn(_ scan: Scan, appearance: NSAppearance.Name) throws {
        let painted = try scan == .duplicates
            ? paintedInBand(lens: .duplicates, chip: .duplicates, appearance: appearance) { $0.isFindingDuplicates = true }
            : paintedInBand(lens: .filing, chip: .toFile, appearance: appearance) { $0.isSuggestingFiles = true }
        #expect(painted > 2_000, "\(appearance.rawValue): \(scan) scan screen painted almost nothing (\(painted) px)")
        #expect(painted < 40_000, "\(appearance.rawValue): \(scan) scan screen is painting a fill (\(painted) px)")
    }
}
