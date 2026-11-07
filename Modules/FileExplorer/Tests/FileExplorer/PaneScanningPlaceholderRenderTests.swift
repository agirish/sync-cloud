import Testing
import SwiftUI
import AppKit
import Design
import Sync
@testable import FileExplorer

/// An empty pane being read must paint its busy indicator (`PaneBusyIndicator`) as spinner and
/// label and nothing else; where the chip sits is `PaneBusyChipRenderTests`' business. A material
/// card has nothing to blur on an empty pane and draws a flat gray slab, which only pixels can see,
/// so this renders over a magenta backdrop and counts the pixels that aren't it: ink is ~3.2k of
/// 504k, a card ~53k. The floor stops a render that draws nothing from passing. Machine-pinned:
/// both bounds move with font rasterization and backing scale.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct PaneScanningPlaceholderRenderTests {

    private var scanningPane: FileTreeView {
        FileTreeView(
            tree: PaneTree(side: .left, version: 0, nodes: []),
            otherTree: PaneTree(side: .right, version: 0, nodes: []),
            isLoading: true, currentPath: "/root",
            selection: .constant([]), otherSelection: [],
            isLeft: true, delegate: NoOpFileActionDelegate(),
            rootPathIsValid: true, providerIsEnabled: true,
            hasOnlyHiddenEntries: false, rootPath: "/root"
        )
    }

    /// Pixels in the render that are not the magenta backdrop: everything the pane painted.
    private func paintedPixels(appearance: NSAppearance.Name) throws -> Int {
        let size = CGSize(width: 420, height: 300)
        // Pinned, not inherited: a Tint above 0 washes the whole surface and would fail this test
        // for a reason unrelated to the placeholder.
        let defaults = ScratchDefaults("PaneScanning-\(appearance.rawValue)")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        defaults.set(0.0, forKey: LiquidGlass.tintKey)
        let subject = scanningPane
            .defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
            // Behind the pane, not in front: anything the placeholder fills covers this.
            .background(Color(red: 1, green: 0, blue: 1))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let rep = try #require(PixelDiff.render(subject, size: size, appearance: appearance))

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
    func theScanningPlaceholderPaintsNoCardOfItsOwn(appearance: NSAppearance.Name) throws {
        let painted = try paintedPixels(appearance: appearance)
        // Floor: the spinner and its label really rendered, so a blank canvas cannot pass.
        #expect(painted > 800, "\(appearance.rawValue): placeholder painted almost nothing (\(painted) px)")
        // Ceiling: no slab behind them. A material card paints ~53k here.
        #expect(painted < 12_000, "\(appearance.rawValue): placeholder is painting a fill (\(painted) px)")
    }
}
