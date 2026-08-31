import Testing
import AppKit
import SwiftUI
@testable import FileExplorer
import Sync

/// The carry-over, driven through a real mounted pane rather than asserted about in the abstract.
///
/// `FileTreeView.carryOver` can be perfect while nothing calls it, and the call it needs is a
/// SwiftUI `onAppear` — the seam a unit test cannot reach. `PaneColumnCarryOverTests` guards that
/// call at source level, which is a blunt instrument with a known blind spot; this renders the two
/// arrivals and compares what a person would actually see.
///
/// The assertion is a **pixel difference between the arms**, not a committed reference image:
/// nothing here should pin the outline's typography or row metrics, and a tolerance-based snapshot
/// comparison is blind to small controls anyway. The two arms differ in exactly one input — whether
/// the pane arrives with a parked column stack — so every differing pixel is that difference.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct PaneColumnCarryOverRenderTests {

    /// The pane's actions are irrelevant here: nothing in this fixture clicks.
    private struct StubDelegate: FileActionDelegate {
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

    private static let root = "/carry-over"

    /// The shape of the reported screenshot: a root of sibling folders, with the parked stack two
    /// deep inside one of them and a file at the bottom that only appears once both are open.
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

    /// Mounts a Tree pane that arrives holding `stack`, lets the deferred reveal settle, and returns
    /// what it drew.
    ///
    /// The run-loop pumping is not decoration: the carry-over's scroll is deferred twice on purpose
    /// (SwiftUI is still applying the update that opens the folders when it runs), so a fixture that
    /// captured immediately would photograph the tree before the work under test happened.
    /// A pane whose load can finish while it is mounted — the state a tab switch lands in mid-scan.
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
                delegate: StubDelegate(),
                isSingleSource: true,
                isActivePane: true,
                viewMode: .tree,
                childrenIndex: nil,
                browsePath: $browse,
                onColumnNavigate: { browse = $0 })
                // **Place the carry's scroll outright rather than easing it across.** This window is
                // offscreen and never key, so a SwiftUI animation in it never advances with the
                // display asleep or in Low Power Mode, and the scroll never lands — see
                // `EnvironmentValues.paneColumnRevealAnimation` and `PaneColumnsScrollTests`, where
                // a test stayed GREEN with the reveal inert, which is worse than failing. The
                // control in `testALoadThatFinishesUnderThePaneStillCarriesTheColumnsOver` measured
                // exactly that here: both arms drew the unscrolled tree and agreed perfectly.
                .environment(\.paneColumnRevealAnimation, nil)
        }
    }

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
        // A real (never ordered in) window, as `SnapshotRendering` uses: appearance, backing store
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

    /// Differing pixels between two reps of the same size. Compared channel-exactly: both arms are
    /// rendered by this process in the same pass, so anti-aliasing jitter is not in play and a
    /// tolerance would only blur the answer.
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

    /// **Arriving mid-scan must end in the same picture as arriving settled.**
    ///
    /// The carry is refused while the tree is still arriving — deciding from a half-built list is
    /// how the other direction moved the columns somewhere the user never was — and a refusal that
    /// is never re-asked is just a silent failure with better manners. The pane latched `carriedStack`
    /// regardless, so the folders stayed shut for the rest of the session.
    ///
    /// What this can observe is ROW ARRIVAL, which is what the reveal suites assert too: an
    /// offscreen, never-key window's scroll position is not a reliable instrument (see
    /// `PaneColumnsScrollTests`, where a test stayed green with the reveal inert). Expansion is the
    /// half that decides whether the folders you were in are on screen at all.
    @Test func testALoadThatFinishesUnderThePaneStillCarriesTheColumnsOver() throws {
        let stack = PaneBrowsePath(components: ["Home", "Accessories"])
        let settled = try render(arrivingWith: stack)
        let midLoad = try render(arrivingWith: stack, settlingAfterALoad: true)

        // The control that stops this being two identically blank pictures agreeing: the carried
        // arm must genuinely differ from a pane that arrived with nothing parked.
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

    /// Flip to Tree three columns deep and the folders you were in are open, with the deepest one on
    /// screen — instead of the top of a tree that says nothing about where you just were.
    @Test func testTheTreeArrivesWithTheParkedColumnsOpen() throws {
        let parked = try render(arrivingWith: PaneBrowsePath(components: ["Home", "Accessories"]))
        let resting = try render(arrivingWith: PaneBrowsePath())

        // The control first: an identical mount must draw identically, or the comparison below is
        // measuring render noise rather than the carry-over.
        let noise = try differingPixels(resting, try render(arrivingWith: PaneBrowsePath()))
        #expect(noise == 0, "two identical mounts already differ by \(noise)px — the arms below prove nothing")

        // Two rows appear (Accessories, Guide.pdf) and one disclosure triangle turns. At this row
        // height that is thousands of pixels; the floor is set well under it so the test fails on
        // the carry-over being gone, not on a font metric moving.
        let changed = try differingPixels(parked, resting)
        #expect(changed > 500,
                """
                the pane arrived at the same picture with and without a parked column stack \
                (\(changed)px differ) — the columns were not carried into the tree
                """)
    }
}
