import Testing
import SwiftUI
import AppKit
import Design
import Sync
@testable import FileExplorer

/// **A pane reading its folder shows one busy indicator, in one place, for the whole load.**
///
/// It showed up to three: the centred "Scanning Directory…" while it had no rows, a spinner chip
/// in the corner once it had some, and a spinner in every open empty Columns column — the last two
/// together for the whole gap between the shallow first paint and the deep walk (raised 2026-10-03;
/// the user chose the corner, always, on 2026-10-15). The column half is held by
/// `PaneColumnsEmptyCaptionTests`; this is the pane's half: the rule, the pane's use of it, and —
/// in `PaneBusyChipRenderTests` — what actually paints.
@MainActor
@Suite struct PaneBusyIndicatorTests {

    /// The whole table, so a third input added later has to decide about every cell.
    @Test func theRuleIsTheWalkAndNothingElse() {
        #expect(PaneBusyIndicator.resolve(isLoading: false, treeIsEmpty: true) == PaneBusyIndicator.none)
        #expect(PaneBusyIndicator.resolve(isLoading: false, treeIsEmpty: false) == PaneBusyIndicator.none)
        #expect(PaneBusyIndicator.resolve(isLoading: true, treeIsEmpty: true) == .chip(backed: false),
                "an empty pane being read must show the chip — unbacked, since nothing is under it")
        #expect(PaneBusyIndicator.resolve(isLoading: true, treeIsEmpty: false) == .chip(backed: true))
    }

    /// The pane resolves its chip from its own inputs — the call-site half of the rule, without
    /// which the table above could be right and unused.
    @Test func thePaneAsksTheRuleWithItsOwnState() {
        let row = FileNode(id: "/root/a.txt", name: "a.txt", isDirectory: false)
        #expect(BusyPaneFixture.pane(nodes: [], isLoading: true).busyIndicator == .chip(backed: false))
        #expect(BusyPaneFixture.pane(nodes: [row], isLoading: true).busyIndicator == .chip(backed: true))
        #expect(BusyPaneFixture.pane(nodes: [row], isLoading: false).busyIndicator == PaneBusyIndicator.none)
        // And the centre stays claimed while the walk runs, so "Folder is empty" cannot show on a
        // pane nobody has read yet — the chip replaced the centred spinner, not the empty-state rule.
        #expect(BusyPaneFixture.pane(nodes: [], isLoading: true).emptyState == .loading)
    }

    /// Shown and spoken from one constant, with the typographic ellipsis the rest of the app's
    /// in-progress labels use.
    @Test func theChipSaysScanningDirectory() {
        #expect(PaneBusyIndicator.title == "Scanning Directory\u{2026}")
    }
}

/// A `FileTreeView` with nothing wired but what the busy indicator reads.
@MainActor
enum BusyPaneFixture {
    struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
        func handleOpenInEditor(_ path: String) {}
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

    static func pane(nodes: [FileNode], isLoading: Bool) -> FileTreeView {
        FileTreeView(
            tree: PaneTree(side: .left, version: 0, nodes: nodes),
            otherTree: PaneTree(side: .right, version: 0, nodes: []),
            isLoading: isLoading, currentPath: "/root",
            selection: .constant([]), otherSelection: [],
            isLeft: true, delegate: StubDelegate(),
            rootPathIsValid: true, providerIsEnabled: true,
            hasOnlyHiddenEntries: false, rootPath: "/root"
        )
    }
}

/// **What the busy chip paints, and where.** Rendered over a magenta backdrop nothing in the UI uses
/// (`PaneScanningPlaceholderRenderTests`' method), so every non-backdrop pixel is something the
/// subject drew.
///
/// `.machinePinned(.pixelSampling)` for the reason its siblings carry it: the floors and ceilings
/// are ink counts read on this Mac, and they move with font rasterization and backing scale.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct PaneBusyChipRenderTests {

    private static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name,
                                        suite: String) throws -> NSBitmapImageRep {
        // Pinned, not inherited: the pane's `@AppStorage` reads the Tint slider, and a tint above 0
        // washes the whole surface.
        let defaults = ScratchDefaults("PaneBusyChip-\(suite)-\(appearance.rawValue)")
        defaults.set(LiquidGlassHue.blue.rawValue, forKey: LiquidGlass.hueKey)
        defaults.set(0.0, forKey: LiquidGlass.tintKey)
        let subject = view
            .defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height)
            .background(Color(red: 1, green: 0, blue: 1))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Non-backdrop pixels inside `rect`, given in the view's own points (origin top-left).
    private static func painted(in rect: CGRect, of rep: NSBitmapImageRep, viewSize: CGSize) -> Int {
        let sx = CGFloat(rep.pixelsWide) / viewSize.width, sy = CGFloat(rep.pixelsHigh) / viewSize.height
        var count = 0
        for y in Int(rect.minY * sy)..<Int(rect.maxY * sy) {
            for x in Int(rect.minX * sx)..<Int(rect.maxX * sx) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let isBackdrop = c.redComponent > 0.98 && c.greenComponent < 0.02 && c.blueComponent > 0.98
                if !isBackdrop { count += 1 }
            }
        }
        return count
    }

    /// **An empty pane being read paints in its bottom-right corner, and nowhere else.** The centre
    /// is where "Scanning Directory…" used to draw; the corner is where the chip now draws for the
    /// whole load. Both halves matter: a centre that is clear because nothing rendered at all would
    /// pass the first on its own.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func anEmptyPaneBeingReadPaintsOnlyItsCorner(appearance: NSAppearance.Name) throws {
        let size = CGSize(width: 420, height: 300)
        let rep = try Self.render(BusyPaneFixture.pane(nodes: [], isLoading: true),
                                  size: size, appearance: appearance, suite: "empty")
        let corner = CGRect(x: size.width - 220, y: size.height - 70, width: 220, height: 70)
        let rest = Self.painted(in: CGRect(origin: .zero, size: size), of: rep, viewSize: size)
            - Self.painted(in: corner, of: rep, viewSize: size)
        let inCorner = Self.painted(in: corner, of: rep, viewSize: size)
        #expect(inCorner > 300, "\(appearance.rawValue): the corner chip did not paint (\(inCorner) px)")
        #expect(rest < 50, "\(appearance.rawValue): the pane painted \(rest) px outside its corner chip")
    }

    /// **Backed over rows, bare over nothing.** The backing is a material, and on an empty pane a
    /// material has nothing to blur and paints a flat gray box — the 2026-08-11 regression this same
    /// label once was. Over rows it is what keeps the label legible.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func theChipIsBackedOnlyWhenAsked(appearance: NSAppearance.Name) throws {
        let size = CGSize(width: 300, height: 120)
        let bare = Self.painted(in: CGRect(origin: .zero, size: size),
                                of: try Self.render(PaneBusyChip(backed: false), size: size,
                                                    appearance: appearance, suite: "bare"),
                                viewSize: size)
        let backed = Self.painted(in: CGRect(origin: .zero, size: size),
                                  of: try Self.render(PaneBusyChip(backed: true), size: size,
                                                      appearance: appearance, suite: "backed"),
                                  viewSize: size)
        #expect(bare > 300, "\(appearance.rawValue): the bare chip painted almost nothing (\(bare) px)")
        // The backing covers the whole chip; ink is a fraction of it.
        #expect(backed > bare * 3, "\(appearance.rawValue): backed \(backed) px vs bare \(bare) px")
    }
}
