import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// A click in a column must leave the pane's layout settled.
///
/// AppKit runs update-constraints and layout passes until a window stops dirtying itself, and
/// raises `NSGenericException` ("…already had more … passes than there are views in the window")
/// when it never does: a hard crash. A drill in Columns can cause one if the pane's geometry
/// callback and its host resolve the action bar's edge from different selections, each commits its
/// answer to the shared anchor, and the pane writes host state from inside the layout pass that
/// called it.
///
/// These pin both halves: the anchor is committed from one source, and a drill on a low row doesn't
/// flip an edge the host would immediately un-flip.
@MainActor
@Suite struct PaneColumnsLayoutLoopTests {

    final class Counter: @unchecked Sendable {
        var bodies = 0
        var flips = 0
    }

    /// Stands in for the app's `FileSyncManager` + `ContentView` state. `selection` and
    /// `hostSelection` are separate on purpose, as in the app: the pane's List holds the clicked
    /// row at once, while the host's `barSelectionNodes` is empty for a pane that isn't the active
    /// one, which includes the just-clicked pane for the turn before the other side's selection is
    /// cleared.
    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
        @Published var hostSelection: Set<String> = []
    }

    private static let root = "/root"

    /// A root of directories, each holding a few files: enough rows that a folder low in the list
    /// sits inside the bar's coverage band.
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

    /// The app's pane column reduced to the parts that decide layout: the pane in Columns, the
    /// host's own edge resolve (which commits to the shared placement), and the flip callback that
    /// writes host state.
    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let index: PaneChildrenIndex
        let placement: PaneBarPlacement
        let counter: Counter
        let downloads: NotificationCenter
        @State private var barAtTop = false

        var body: some View {
            counter.bodies += 1
            // The app reads this purely to re-render on a flip; the edge is resolved fresh below.
            _ = barAtTop
            let edge = placement.resolveAtTop(selection: box.hostSelection)
            return FileTreeView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: false,
                currentPath: PaneColumnsLayoutLoopTests.root,
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

    /// Mounts the harness in a real (never ordered-in) window, as the snapshot harness does: a
    /// `List` only bridges to an `NSTableView`, and preferences only carry real geometry, inside a
    /// window that actually lays out.
    ///
    /// On a `NotificationCenter` of this suite's own: a mounted `FileTreeView` subscribes to
    /// `.cloudDownloadRequested` regardless, and on `.default` this left pane would take the
    /// `.left` posts `CloudDownloadWiringTests` makes and fail that suite. See
    /// `docs/flaky-tests.md`, "A mounted view is a live subscriber, in every suite at once".
    private func mount(_ box: Box, counter: Counter) -> (NSWindow, PaneBarPlacement) {
        let tree = Self.tree(folders: 40)
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let placement = PaneBarPlacement()
        let host = NSHostingView(
            rootView: Harness(box: box, tree: tree, index: index, placement: placement,
                              counter: counter, downloads: NotificationCenter())
        )
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return (window, placement)
    }

    /// Pumps the runloop, re-laying out by hand each turn.
    ///
    /// The manual `layoutIfNeeded` disarms AppKit's runaway guards: a never-settling sibling
    /// ping-pong survives hundreds of rounds of it without raising, while the runloop alone raises
    /// on the first cycle. So these tests pin the action-bar anchor rule and do not bound the
    /// window's update-constraints budget; `ColumnsDisplayCycleTests` does (see
    /// `docs/columns-layout-loop.md`).
    private func pump(_ window: NSWindow, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
    }

    /// Clicking a folder low in a column must not make the pane ask the host to move the bar for a
    /// selection the host isn't showing a bar for.
    @Test func testDrillOnALowRowDoesNotFlipAnEdgeTheHostWillUnflip() throws {
        let box = Box()
        let counter = Counter()
        let (window, placement) = mount(box, counter: counter)
        // Drops the last reference to the SwiftUI graph, and with it the pane's live subscription,
        // rather than leaving it to ARC. Not `close()`: see `docs/flaky-tests.md`, "The wait that
        // hangs instead of failing".
        defer { window.contentView = nil }
        pump(window, seconds: 0.3)

        // Proof the pane really laid out: the root column's rows, and nothing else yet.
        #expect(PaneLayoutSettle.tableRowCounts(window.contentView!) == [40])
        // The lowest row inside the viewport: the one a bottom-docked bar would cover, whose click
        // asks for the flip. Taken from live geometry, not a row index, so a density or font change
        // can't move the test off the band.
        let target = try #require(
            placement.rowBottoms
                .filter { $0.value - placement.viewportGlobalMinY <= placement.viewportHeight }
                .max(by: { $0.value < $1.value })
        )
        let inViewport = target.value - placement.viewportGlobalMinY
        #expect(inViewport > placement.viewportHeight - placement.coverage,
                "target row is not inside the bar's coverage band — the flip path would not be exercised")

        let settledBodies = counter.bodies
        // The tap: open that folder's column and select it. The host's bar selection stays empty
        // for this turn, as `activePane`'s tiebreak leaves it after a click.
        var path = box.browsePath
        path.drill(into: (target.key as NSString).lastPathComponent, atDepth: 0)
        box.browsePath = path
        box.selection = [target.key]
        pump(window, seconds: 1.0)

        // The drilled column is open: the click did what a click does.
        #expect(PaneLayoutSettle.tableRowCounts(window.contentView!) == [40, 4])
        // …and the pane asked for no edge flip, because the bar it would move isn't showing. Fails
        // if the pane resolves from its own raw selection while the host commits from its empty
        // one.
        #expect(counter.flips == 0)
        #expect(placement.atTop == false)
        let cost = counter.bodies - settledBodies
        #expect(cost < 50, "drill re-rendered the pane \(cost)× — layout is not settling")
    }

    /// The anchor has one source. A pane re-resolving after a scroll reasons from the selection the
    /// host committed, so it can never hand back a different edge than the host's next render will.
    @Test func testReresolveCannotDisagreeWithTheHostsCommit() {
        let placement = PaneBarPlacement()
        placement.viewportHeight = 600
        placement.viewportGlobalMinY = 0
        placement.coverage = 64
        placement.rowBottoms = ["low": 580, "high": 40]

        // Host: a bar acting on nothing (the inactive pane, or the turn after a click).
        #expect(placement.resolveAtTop(selection: []) == false)
        // Pane, after geometry moved: same answer, because it reasons from the same selection.
        #expect(placement.reresolveAtTop() == false)

        // Host: a bar acting on the low row.
        #expect(placement.resolveAtTop(selection: ["low"]) == true)
        #expect(placement.reresolveAtTop() == true)
    }
}
