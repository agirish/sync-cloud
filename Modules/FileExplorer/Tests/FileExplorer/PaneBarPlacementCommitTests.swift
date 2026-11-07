import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// Who commits the action bar's edge, and why a selection change never calls `onBarEdgeFlip`.
///
/// `PaneBarPlacement.flipIfEdgeMoved` calls back only when `reresolveMovedEdge()` finds the
/// committed `atTop` moved. The host commits synchronously from its own `body` (`ContentView`
/// computes `placement.resolveAtTop(…)` on every render), so by the time a geometry callback runs
/// the answer already agrees: a selection change can never produce a flip. Only geometry moving
/// under an unchanged selection can, which in the app is a scroll, and a scroll doesn't re-render
/// the host, because `PaneBarPlacement` is a plain class whose per-frame writes invalidate nothing.
/// That asymmetry is deliberate: it stops the bar showing at one edge and hopping to the other.
///
/// A fixture that passes `onBarEdgeFlip` (as `ColumnsDisplayCycleTests.TwoPaneHarness` does) isn't
/// covering it. In the Tree no headless lever can arm the callback: moving geometry either
/// re-renders the root, so the host commits first, or moves AppKit's clip view without re-driving
/// SwiftUI's geometry preferences. Columns reads its rows' bottoms from each column's table
/// (`ColumnListProbe`), which observes the clip, so a scroll there can be armed; the last two
/// tests pin that.
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
        /// What the host's action bar is acting on: the selection `resolveAtTop` reasons from.
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

    /// A pane whose host resolves the edge from its own `body` and mounts a bar on the result:
    /// `ContentView`'s shape, which `ColumnsDisplayCycleTests.TwoPaneHarness` omits.
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

    /// Mounted on this suite's own `NotificationCenter`: a mounted `FileTreeView` subscribes to
    /// `.cloudDownloadRequested` whether it wants it or not. See `docs/flaky-tests.md`, "A mounted
    /// view is a live subscriber, in every suite at once".
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

    /// The bar's edge changes on a selection change, without a flip callback, because the host
    /// committed it synchronously from `body`. Both halves are asserted: without the first this
    /// would pass over a dormant path, and without the second it wouldn't say what it is for.
    @Test func aSelectionChangeMovesTheEdgeWithoutAskingForAFlip() throws {
        let box = Box(tree: Self.tree(folders: 40))
        let counter = Counter()
        let (window, placement) = mount(box, counter: counter)
        // Drops the SwiftUI graph and the pane's live subscription rather than leaving it to ARC.
        // Not `close()`: see `docs/flaky-tests.md`, "The wait that hangs instead of failing".
        defer { window.contentView = nil }
        pump(window, seconds: 0.3)

        #expect(placement.atTop == false, "nothing is selected yet, so the bar rests at the bottom")

        // The lowest row inside the viewport, the one a bottom-docked bar would cover. Taken from
        // live geometry, not by index, so a density or font change can't move it off the band.
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

        // …and this is why no callback follows: a fresh resolve agrees with what the host already
        // committed, so `PaneBarPlacement.flipIfEdgeMoved` returns (`reresolveMovedEdge()` is
        // false).
        //
        // This is the load-bearing assertion, not the flip count below: the callback is dispatched
        // with `DispatchQueue.main.async` and lands after this synchronous pump, so `flips == 0`
        // holds even if the agreement check is removed. The count only corroborates.
        #expect(placement.reresolveAtTop() == placement.atTop,
                "a re-resolve must agree with the committed edge — that agreement is what makes the callback return")
        #expect(counter.flips == 0,
                "a selection change must not produce an edge-flip callback: the host commits it synchronously from body")
    }

    // MARK: - Columns: a scroll re-resolves the bar

    /// Suspends while the run loop runs, laying the window out a frame at a time. A synchronous
    /// `CFRunLoopRunInMode` inside a `@MainActor` test never drains the main queue, where the flip
    /// callback is dispatched, so the two tests below can't use `pump(_:seconds:)`.
    @discardableResult
    private func waitUntil(_ window: NSWindow, _ timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return condition()
    }

    private func columnList(_ window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.documentView is NSTableView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(window.contentView!)
        return found.first
    }

    /// Columns' row bottoms are in the viewport's own space: the first row ends about a row below
    /// the viewport's top. A probe converting into another space (the window's bottom-up one, the
    /// clip's) would be hundreds of points off and the bar would flip early or never; every other
    /// assertion about bottoms is relative and wouldn't notice.
    @Test func columnRowBottomsAreInTheViewportsSpace() async throws {
        let box = Box(tree: Self.tree(folders: 40))
        let (window, placement) = mount(box, counter: Counter())
        defer { window.contentView = nil }
        let first = "\(Self.root)/folder0"
        await waitUntil(window) { placement.rowBottoms[first] != nil && placement.viewportHeight > 0 }
        let bottom = try #require(placement.rowBottoms[first], "the first row was never reported")
        let below = bottom - placement.viewportGlobalMinY
        #expect(below > 10 && below < 60, "the first row ends \(below)pt below the viewport's top, not about a row")
    }

    /// Scrolling a column flips the bar once. The lowest visible row is selected, so the bar goes
    /// to the top; the column then scrolls until that row rises clear of the band, and the bar is
    /// asked back down exactly once.
    @Test func scrollingAColumnFlipsTheBarOnce() async throws {
        let box = Box(tree: Self.tree(folders: 40))
        let counter = Counter()
        let (window, placement) = mount(box, counter: counter)
        defer { window.contentView = nil }
        await waitUntil(window) { !placement.rowBottoms.isEmpty && placement.viewportHeight > 0 }
        let target = try #require(
            placement.rowBottoms
                .filter { $0.value - placement.viewportGlobalMinY <= placement.viewportHeight }
                .max(by: { $0.value < $1.value }),
            "no row bottoms were reported — the pane never laid out")
        box.selection = [target.key]
        box.hostSelection = [target.key]
        await waitUntil(window) { placement.atTop }
        try #require(placement.atTop, "selecting the lowest visible row did not raise the bar")
        #expect(counter.flips == 0, "a selection change asked for a flip")

        let list = try #require(columnList(window), "no column list")
        let clip = list.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + 160))
        list.reflectScrolledClipView(clip)
        await waitUntil(window) { counter.flips > 0 }
        #expect(counter.flips == 1, "scrolling the selected row clear of the band flipped the bar \(counter.flips) times")
        #expect(!placement.atTop, "the bar stayed at the top after its row rose clear")
    }
}
