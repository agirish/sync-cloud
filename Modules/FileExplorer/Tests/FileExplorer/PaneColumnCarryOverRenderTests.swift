import Testing
import AppKit
import SwiftUI
@testable import FileExplorer
import Sync

/// The carry-over, driven through a real mounted pane: `PaneColumnCarryOverTests` scans its
/// `onAppear` call; this renders the arrivals and compares them. A pixel difference between arms
/// that differ in one input (a parked column stack), not a reference image.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct PaneColumnCarryOverRenderTests {

    private static let root = "/carry-over"

    /// A root of sibling folders, with the parked stack two deep inside one of them and a file at
    /// the bottom that only appears once both are open.
    private func tree() -> PaneTree {
        func dir(_ path: String, _ name: String, _ children: [FileNode] = []) -> FileNode {
            FileNode(id: path, name: name, isDirectory: true, children: children)
        }
        let root = Self.root
        return PaneTree(side: .left, version: 1, nodes: [
            dir("\(root)/Claude", "Claude", [dir("\(root)/Claude/Projects", "Projects")]),
            dir("\(root)/Family", "Family"),
            dir("\(root)/Finance", "Finance"),
            dir("\(root)/Home", "Home", [
                dir("\(root)/Home/Accessories", "Accessories", [
                    FileNode(id: "\(root)/Home/Accessories/Guide.pdf", name: "Guide.pdf", isDirectory: false),
                ]),
                dir("\(root)/Home/Archive", "Archive"),
            ]),
        ])
    }

    /// A pane whose load can finish while it is mounted: the state a tab switch lands in mid-scan.
    private final class LoadFlag: ObservableObject {
        @Published var loading: Bool
        init(loading: Bool) { self.loading = loading }
    }

    private struct LoadablePane: View {
        @ObservedObject var flag: LoadFlag
        let tree: PaneTree
        let root: String
        @Binding var selection: Set<String>
        @Binding var browse: PaneBrowsePath

        var body: some View {
            FileTreeView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: flag.loading,
                currentPath: root,
                selection: $selection,
                otherSelection: [],
                isLeft: true,
                delegate: NoOpFileActionDelegate(),
                isSingleSource: true,
                isActivePane: true,
                viewMode: .tree,
                childrenIndex: nil,
                browsePath: $browse,
                onColumnNavigate: { browse = $0 })
                // Place the carry's scroll outright: in this offscreen, never-key window an animation
                // never advances with the display asleep or in Low Power Mode
                // (`EnvironmentValues.paneColumnRevealAnimation`).
                .environment(\.paneColumnRevealAnimation, nil)
        }
    }

    /// Mounts a Tree pane that arrives holding `stack` and returns what it drew, after pumping: the
    /// carry-over's scroll is deferred twice, so an immediate capture would miss it.
    private func render(arrivingWith stack: PaneBrowsePath,
                        tree: PaneTree? = nil,
                        settlingAfterALoad: Bool = false) throws -> NSBitmapImageRep {
        var selection: Set<String> = []
        var browse = stack
        let flag = LoadFlag(loading: settlingAfterALoad)
        let view = LoadablePane(
            flag: flag,
            tree: tree ?? self.tree(),
            root: Self.root,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            browse: Binding(get: { browse }, set: { browse = $0 }))

        let size = NSSize(width: 420, height: 420)
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        // A real (never ordered in) window: appearance, backing store
        // and layout then behave as they do in the app.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host

        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        // The load lands under the mounted pane, which is the moment the refused carry is re-asked.
        if settlingAfterALoad { flag.loading = false }
        for _ in 0..<60 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds),
                               "the pane drew no backing store — the comparison below would be vacuous")
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Differing pixels between two same-size reps, channel-exactly: both arms render in this
    /// process in the same pass.
    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> Int {
        try #require(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh,
                     "different canvas sizes cannot be compared pixel for pixel")
        let lhs = try #require(a.bitmapData), rhs = try #require(b.bitmapData)
        let bytesPerPixel = a.bitsPerPixel / 8
        var differing = 0
        for y in 0..<a.pixelsHigh {
            let rowA = lhs + y * a.bytesPerRow, rowB = rhs + y * b.bytesPerRow
            for x in 0..<a.pixelsWide {
                let offset = x * bytesPerPixel
                if memcmp(rowA + offset, rowB + offset, bytesPerPixel) != 0 { differing += 1 }
            }
        }
        return differing
    }

    /// Arriving mid-scan ends in the same picture as arriving settled: the carry refused while the
    /// tree arrives is re-asked when the load lands. Observes row arrival: an offscreen, never-key
    /// window's scroll position isn't a reliable instrument.
    @Test func testALoadThatFinishesUnderThePaneStillCarriesTheColumnsOver() throws {
        let stack = PaneBrowsePath(components: ["Home", "Accessories"])
        let settled = try render(arrivingWith: stack)
        let midLoad = try render(arrivingWith: stack, settlingAfterALoad: true)

        // The control that stops this being two identically blank pictures agreeing: the carried
        // arm must differ from a pane that arrived with nothing parked.
        let unparked = try render(arrivingWith: PaneBrowsePath())
        let carried = try differingPixels(midLoad, unparked)
        #expect(carried > 500,
                """
                the mid-load arm drew the same tree as an unparked pane (\(carried)px) — nothing was \
                carried at all, so the comparison below would pass on two failures agreeing
                """)

        let changed = try differingPixels(midLoad, settled)
        #expect(changed == 0,
                """
                a pane that arrived during a load ended somewhere else than one that arrived settled \
                (\(changed)px differ) — the refused carry was never re-asked
                """)
    }
}
