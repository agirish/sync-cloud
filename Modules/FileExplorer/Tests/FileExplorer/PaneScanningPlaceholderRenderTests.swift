import Testing
import SwiftUI
import AppKit
import Design
import Sync
@testable import FileExplorer

/// The scanning placeholder must paint its spinner and label and *nothing else*.
///
/// It used to wear a `.regularMaterial` card with a shadow. A material has nothing to blur on an
/// empty pane, so what it actually drew was a flat gray slab in the middle of a white surface —
/// visible in the shipped app, and the reason this test renders rather than inspects the view
/// tree. Geometry cannot see a fill; only pixels can.
///
/// The measurement: render the pane over a backdrop no part of the UI uses (magenta), then count
/// the pixels that are not that backdrop. Ink alone comes to ~3.2k of 504k; the card came to
/// ~53k — a 16× gap, so the 12k ceiling below is nowhere near either number. The floor is there
/// for the opposite failure: a render that draws nothing would otherwise pass this test with a
/// perfect zero.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct PaneScanningPlaceholderRenderTests {

    private struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleRename(_ node: FileNode) {}
        func handleCreateFolder(at path: String) {}
        func handleGetInfo(for path: String) {}
        func handleSort(_ option: SortOption) {}
        func handleIgnore(_ nodes: [FileNode]) {}
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool { false }
    }

    private var scanningPane: FileTreeView {
        FileTreeView(
            tree: PaneTree(side: .left, version: 0, nodes: []),
            otherTree: PaneTree(side: .right, version: 0, nodes: []),
            isLoading: true, currentPath: "/root",
            selection: .constant([]), otherSelection: [],
            isLeft: true, delegate: StubDelegate(),
            rootPathIsValid: true, providerIsEnabled: true,
            hasOnlyHiddenEntries: false, rootPath: "/root"
        )
    }

    /// Pixels in the render that are not the magenta backdrop — i.e. everything the pane painted.
    private func paintedPixels(appearance: NSAppearance.Name) throws -> Int {
        let size = CGSize(width: 420, height: 300)
        // Pinned, not inherited: the pane's own `@AppStorage` reads the Tint slider, and a tint
        // above 0 washes the whole surface — which is a fill covering the canvas, and would fail
        // this test for a reason that has nothing to do with the placeholder.
        let defaults = ScratchDefaults("PaneScanning-\(appearance.rawValue)")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        defaults.set(0.0, forKey: LiquidGlass.tintKey)
        let subject = scanningPane
            .defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
            // Behind the pane, not in front: anything the placeholder fills covers this.
            .background(Color(red: 1, green: 0, blue: 1))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

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
        // Ceiling: no slab behind them. The material card measured ~53k here.
        #expect(painted < 12_000, "\(appearance.rawValue): placeholder is painting a fill (\(painted) px)")
    }
}
