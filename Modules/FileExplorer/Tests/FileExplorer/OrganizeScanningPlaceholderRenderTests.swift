import Testing
import SwiftUI
import AppKit
import Design
import Sync
@testable import FileExplorer

/// Organize's two scanning screens — the duplicate pass and the file pass — must paint their
/// spinner, status line and Cancel button onto the lens surface and nothing else.
///
/// They used to wear a `.regularMaterial` card with a shadow, copied from the file pane's
/// "Scanning Directory…" placeholder for consistency. Both were wrong the same way: a material
/// has nothing to blur on an empty lens, so it renders as a flat gray slab. The pane's copy is
/// covered by `PaneScanningPlaceholderRenderTests`; this is the Organize half.
///
/// Measured the same way — render over a magenta backdrop nothing in the UI uses, then count the
/// pixels below the chip header that are not that backdrop. Ink and the Cancel capsule come to
/// 11,702 of 1,148,000 in the band in light and 14,746 in dark; the card took those to 75,051 and
/// 77,998. Each screen was mutated on its own and failed only its own test, in both appearances,
/// so neither of these is measuring the other's view. The floor guards the opposite failure: a
/// canvas that renders nothing would sail past a ceiling alone.
@MainActor
@Suite struct OrganizeScanningPlaceholderRenderTests {

    private static let canvas = CGSize(width: 700, height: 520)
    /// Everything below the lens chips — the region the placeholder is centered in. Kept clear of
    /// the header so the chips' own fills never enter the count.
    private static let contentBand = CGRect(x: 0, y: 110, width: 700, height: 410)

    /// Non-backdrop pixels in the content band of a scanning lens.
    private func paintedInBand(lens: TidyLens, chip: OrganizeLens,
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

        let subject = TidyView(syncManager: manager, lens: lens, providerName: "Projects",
                               scanTargetFolder: "/root/Documents", onFindDuplicates: {},
                               onBuildStorage: {})
            .defaultAppStorage(defaults)
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            // Behind the lens, not over it: anything the placeholder fills hides this.
            .background(Color(red: 1, green: 0, blue: 1))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        // Without a real window the content composites against the borderless window's own
        // buffer and every comparison reads as zero difference.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: Self.contentBand))
        host.cacheDisplay(in: Self.contentBand, to: rep)

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

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theDuplicateScanScreenPaintsNoCardOfItsOwn(appearance: NSAppearance.Name) throws {
        let painted = try paintedInBand(lens: .duplicates, chip: .duplicates, appearance: appearance) {
            $0.isFindingDuplicates = true
        }
        #expect(painted > 2_000, "\(appearance.rawValue): duplicate scan screen painted almost nothing (\(painted) px)")
        #expect(painted < 40_000, "\(appearance.rawValue): duplicate scan screen is painting a fill (\(painted) px)")
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theFileScanScreenPaintsNoCardOfItsOwn(appearance: NSAppearance.Name) throws {
        let painted = try paintedInBand(lens: .filing, chip: .toFile, appearance: appearance) {
            $0.isSuggestingFiles = true
        }
        #expect(painted > 2_000, "\(appearance.rawValue): file scan screen painted almost nothing (\(painted) px)")
        #expect(painted < 40_000, "\(appearance.rawValue): file scan screen is painting a fill (\(painted) px)")
    }
}
