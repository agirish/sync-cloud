import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// Who commits the action bar's edge, and why that makes `onBarEdgeFlip` unreachable from a test.
///
/// This exists because "the `withAnimation` edge flip is ruled out" was recorded in
/// `docs/columns-layout-loop.md` on the strength of a fixture that wires `onBarEdgeFlip` and never
/// fires it. `ColumnsDisplayCycleTests.TwoPaneHarness` passes the callback exactly as `ContentView`
/// does, so it reads as covered; instrumenting the closure shows it firing **zero** times across
/// the two-pane provider switch. The 7-passes measurement there is real — it is just silent about
/// this one path, and silence had been written down as a negative.
///
/// The mechanism, which is the part worth keeping:
///
/// `flipEdgeIfScrolledAcross` calls back only when `reresolveAtTop()` disagrees with the committed
/// `atTop`. The host commits **synchronously from its own `body`** — `ContentView` computes
/// `let barAtTop = placement.resolveAtTop(…)` on every render. So by the time a preference callback
/// runs, the host has already committed the same answer and there is nothing left to disagree with:
/// **a selection change can never produce a flip.** Only geometry moving under an *unchanged*
/// selection can, which in the app is a scroll — and a scroll does not re-render the host, because
/// `PaneBarPlacement` is a plain class whose per-frame writes invalidate nothing. That asymmetry is
/// deliberate: it is what stops the bar showing at one edge and hopping to the other, and it makes
/// the preference callback the only observer that notices a scroll.
///
/// In a fixture the asymmetry inverts, which is why no headless test can arm the path. Every lever
/// available for moving geometry either re-renders the SwiftUI root — so the host's `resolveAtTop`
/// commits first — or moves AppKit's clip view without re-driving SwiftUI's geometry preferences.
/// Measured on a harness built specifically to arm it (two panes in Columns, a live `resolveAtTop`
/// from the host, a bar overlay on the resolved edge, the selection on the lowest row the bar
/// actually covers, six rounds of scroll + resize): zero flips.
///
/// So this suite does not try to produce a flip. It pins what IS assertable — the edge really moves,
/// and a fresh re-resolve then agrees with it, which is the exact condition the callback returns on
/// — so the reason the path cannot be armed stays executable instead of being rediscovered a fourth
/// time.
@MainActor
@Suite struct PaneBarPlacementCommitTests {

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

    final class Counter {
        var flips = 0
    }

    final class Box: ObservableObject {
        @Published var tree: PaneTree
        @Published var selection: Set<String> = []
        @Published var browsePath = PaneBrowsePath()
        /// What the host's action bar is acting on — the selection `resolveAtTop` reasons from.
        @Published var hostSelection: Set<String> = []
        init(tree: PaneTree) { self.tree = tree }
    }

    private static let root = "/root"

    private static func tree(folders: Int) -> PaneTree {
        let nodes = (0..<folders).map { i -> FileNode in
            let dir = "\(root)/folder\(i)"
            let kids = (0..<4).map { j in
                FileNode(id: "\(dir)/file\(j)", name: "file\(j)", isDirectory: false)
            }
            return FileNode(id: dir, name: "folder\(i)", isDirectory: true, children: kids)
        }
        return PaneTree(side: .left, version: 1, nodes: nodes)
    }

    /// A pane whose host resolves the edge from its own `body` and mounts a bar on the result —
    /// `ContentView`'s shape, and the thing `ColumnsDisplayCycleTests.TwoPaneHarness` omits.
    private struct Harness: View {
        @ObservedObject var box: Box
        let placement: PaneBarPlacement
        let index: PaneChildrenIndex
        let counter: Counter
        let downloads: NotificationCenter
        @State private var barAtTop = false

        var body: some View {
            _ = barAtTop
            let edge = placement.resolveAtTop(selection: box.hostSelection)
            return FileTreeView(
                tree: box.tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: false,
                currentPath: PaneBarPlacementCommitTests.root,
                selection: $box.selection,
                otherSelection: [],
                isLeft: true,
                delegate: StubDelegate(),
                placement: placement,
                onBarEdgeFlip: {
                    counter.flips += 1
                    withAnimation(.easeInOut(duration: 0.22)) { barAtTop.toggle() }
                },
                viewMode: .columns,
                childrenIndex: index,
                browsePath: $box.browsePath,
                onColumnNavigate: { box.browsePath = $0 },
                downloadChannel: downloads
            )
            .overlay(alignment: edge ? .top : .bottom) {
                if !box.hostSelection.isEmpty {
                    Color.clear.frame(height: 44).padding(10)
                }
            }
        }
    }

    /// Mounted on this suite's own `NotificationCenter` — a mounted `FileTreeView` subscribes to
    /// `.cloudDownloadRequested` regardless of whether it wants it. See `docs/flaky-tests.md`
    /// mechanism 9.
    private func mount(_ box: Box, counter: Counter) -> (NSWindow, PaneBarPlacement) {
        let placement = PaneBarPlacement()
        let index = PaneChildrenIndex(tree: box.tree, treeRoot: Self.root)
        let host = NSHostingView(
            rootView: Harness(box: box, placement: placement, index: index,
                              counter: counter, downloads: NotificationCenter())
        )
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return (window, placement)
    }

    private func pump(_ window: NSWindow, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
    }

    /// The bar's edge changes on a selection change, and it changes **without** a flip callback,
    /// because the host committed it synchronously from `body`.
    ///
    /// Both halves are asserted. Without the first this would pass over a dormant path; without the
    /// second it would not say what it is for.
    @Test func aSelectionChangeMovesTheEdgeWithoutAskingForAFlip() throws {
        let box = Box(tree: Self.tree(folders: 40))
        let counter = Counter()
        let (window, placement) = mount(box, counter: counter)
        // Drops the SwiftUI graph and the pane's live subscription rather than leaving it to ARC.
        // Not `close()` — see `docs/flaky-tests.md` mechanism 8.
        defer { window.contentView = nil }
        pump(window, seconds: 0.3)

        #expect(placement.atTop == false, "nothing is selected yet, so the bar rests at the bottom")

        // The lowest row inside the viewport — the one a bottom-docked bar would cover. Taken from
        // live geometry rather than by index, so a density or font change cannot quietly move this
        // off the band it aims at.
        let target = try #require(
            placement.rowBottoms
                .filter { $0.value - placement.viewportGlobalMinY <= placement.viewportHeight }
                .max(by: { $0.value < $1.value }),
            "no row bottoms were reported — the pane never laid out"
        )
        let inViewport = target.value - placement.viewportGlobalMinY
        #expect(inViewport > placement.viewportHeight - placement.coverage,
                "target row is not inside the bar's coverage band — the placement math is not engaged")

        box.selection = [target.key]
        box.hostSelection = [target.key]
        pump(window, seconds: 0.3)

        // The edge really did move, so this is not a test of a dormant path…
        #expect(placement.atTop, "selecting a covered row must put the bar at the top")

        // …and this is WHY no callback follows: a fresh resolve agrees with what the host already
        // committed, which is exactly the condition `flipEdgeIfScrolledAcross` returns on
        // (`guard placement.reresolveAtTop() != wasAtTop else { return }`).
        //
        // This is the load-bearing assertion, and the flip count below is not. Measured by
        // instrumenting `flipEdgeIfScrolledAcross`: it is entered 3 times, passes its
        // `placement`/`onBarEdgeFlip` guard all 3 times, and returns at the `!=` guard all 3 times —
        // the resolve agreed. But mutating that guard away does **not** redden `flips == 0`, because
        // the callback is dispatched with `DispatchQueue.main.async` and the block lands after the
        // measured pump. So the count corroborates; the agreement is what proves it.
        #expect(placement.reresolveAtTop() == placement.atTop,
                "a re-resolve must agree with the committed edge — that agreement is what makes the callback return")
        #expect(counter.flips == 0,
                "a selection change must not produce an edge-flip callback: the host commits it synchronously from body")
    }
}
