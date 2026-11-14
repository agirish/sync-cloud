import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// A Columns pane whose host resolves the action bar's edge from its own `body` and mounts a bar on
/// the result (`ContentView`'s shape), for `PaneColumnsLayoutLoopTests` and
/// `PaneBarPlacementCommitTests`.
@MainActor
enum PaneBarHostHarness {

    final class Counter: @unchecked Sendable {
        var bodies = 0
        var flips = 0
    }

    /// Stands in for the app's `FileSyncManager` + `ContentView` state. `selection` and
    /// `hostSelection` differ on purpose: the List holds the clicked row at once, while the host's
    /// `barSelectionNodes` stays empty for the just-clicked pane for a turn.
    final class Box: ObservableObject {
        @Published var tree: PaneTree
        @Published var selection: Set<String> = []
        @Published var browsePath = PaneBrowsePath()
        /// What the host's action bar is acting on: the selection `resolveAtTop` reasons from.
        @Published var hostSelection: Set<String> = []
        init(tree: PaneTree) { self.tree = tree }
    }

    static let root = "/root"

    /// A root of directories, each holding a few files: enough rows that a folder low in the list
    /// sits inside the bar's coverage band.
    static func tree(folders: Int) -> PaneTree {
        let nodes = (0..<folders).map { i -> FileNode in
            let dir = "\(root)/folder\(i)"
            let kids = (0..<4).map { j in
                FileNode(id: "\(dir)/file\(j)", name: "file\(j)", isDirectory: false)
            }
            return FileNode(id: dir, name: "folder\(i)", isDirectory: true, children: kids)
        }
        return PaneTree(side: .left, version: 1, nodes: nodes)
    }

    /// The pane in Columns, the host's own edge resolve (which commits to the shared placement),
    /// and the flip callback that writes host state.
    private struct Harness: View {
        @ObservedObject var box: Box
        let placement: PaneBarPlacement
        let index: PaneChildrenIndex
        let counter: Counter
        let downloads: NotificationCenter
        @State private var barAtTop = false

        var body: some View {
            counter.bodies += 1
            // The app reads this purely to re-render on a flip; the edge is resolved fresh below.
            _ = barAtTop
            let edge = placement.resolveAtTop(selection: box.hostSelection)
            return FileTreeView(
                tree: box.tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: false,
                currentPath: PaneBarHostHarness.root,
                selection: $box.selection,
                otherSelection: [],
                isLeft: true,
                delegate: NoOpFileActionDelegate(),
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

    /// Mounts the harness in a real (never ordered-in) window: a `List` only bridges to an
    /// `NSTableView`, and preferences only carry real geometry, inside a window that lays out.
    ///
    /// On a `NotificationCenter` of its own: a mounted `FileTreeView` subscribes to
    /// `.cloudDownloadRequested` regardless, and on `.default` this left pane would take the
    /// `.left` posts `CloudDownloadWiringTests` makes and fail that suite. See
    /// `docs/flaky-tests.md`, "A mounted view is a live subscriber, in every suite at once".
    static func mount(_ box: Box, counter: Counter) -> (NSWindow, PaneBarPlacement) {
        let placement = PaneBarPlacement()
        let index = PaneChildrenIndex(tree: box.tree, treeRoot: root)
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

    /// Pumps the runloop, re-laying out by hand each turn. The manual `layoutIfNeeded` disarms
    /// AppKit's runaway guards, so these tests pin the anchor rule, not the update-constraints
    /// budget (`ColumnsDisplayCycleTests`, `docs/columns-layout-loop.md`). A synchronous
    /// `CFRunLoopRunInMode` in a `@MainActor` test never drains the main queue, where flips land.
    static func pump(_ window: NSWindow, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
    }
}
