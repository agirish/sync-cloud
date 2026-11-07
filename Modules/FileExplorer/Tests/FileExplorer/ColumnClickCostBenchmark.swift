import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// What re-rendering a Columns pane costs when a selection changes: three columns over a ~40k-node
/// tree, ~10ms. Blind to row menus, whose `.contextMenu` bodies run only on screen
/// (`ContextMenuWalkTests` pins those). The fixture must be realistic: a small or COW-shared tree
/// measures 0.0ms. The bar is a fixed 250ms, not load-scaled, because a CPU probe can't see what
/// starves a render (`docs/flaky-tests.md`, "Load-scaled benchmarks"); see `budgetMs`. Absolute is
/// fine under `.machinePinned(.calibratedTiming)`.
@MainActor
@Suite(.machinePinned(.calibratedTiming)) struct ColumnClickCostBenchmark {

    private struct StubDelegate: FileActionDelegate {
        /// Stands in for `FileSyncManager.isNodeIgnored`, which relativizes the path and tests it
        /// against the effective ignore set — per row, per render.
        let ignored: Set<String>
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
        func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool {
            ignored.contains(node.id)
        }
    }

    final class Box: ObservableObject {
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
    }

    static let root = "/root"

    /// ~40,000 nodes, three levels deep, the shape real panes hold. Distinct strings throughout so
    /// nothing is COW-shared.
    private static func bigTree(side: PaneTree.Side) -> PaneTree {
        var top: [FileNode] = []
        top.reserveCapacity(40)
        for a in 0..<40 {
            var mid: [FileNode] = []
            mid.reserveCapacity(25)
            for b in 0..<25 {
                let dir = "\(root)/top\(a)/mid\(b)"
                let files = (0..<40).map { c in
                    FileNode(id: "\(dir)/file-\(a)-\(b)-\(c).pdf",
                             name: "file-\(a)-\(b)-\(c).pdf", isDirectory: false)
                }
                mid.append(FileNode(id: dir, name: "mid\(b)", isDirectory: true, children: files))
            }
            top.append(FileNode(id: "\(root)/top\(a)", name: "top\(a)", isDirectory: true, children: mid))
        }
        return PaneTree(side: side, version: 1, nodes: top)
    }

    /// Counts body evaluations, so a measurement can prove the view actually re-rendered rather
    /// than timing a no-op.
    final class Counter: @unchecked Sendable { var bodies = 0 }

    private struct Harness: View {
        @ObservedObject var box: Box
        let tree: PaneTree
        let otherTree: PaneTree
        let index: PaneChildrenIndex
        let diffIndex: DiffStatusIndex
        let delegate: FileActionDelegate
        let counter: Counter
        let downloads: NotificationCenter

        var body: some View {
            counter.bodies += 1
            return FileTreeView(
                tree: tree, otherTree: otherTree, isLoading: false,
                currentPath: ColumnClickCostBenchmark.root,
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: delegate, diffIndex: diffIndex,
                viewMode: .columns, childrenIndex: index,
                browsePath: $box.browsePath,
                onColumnNavigate: { box.browsePath = $0 },
                downloadChannel: downloads
            )
        }
    }

    /// Mounts the pane on a `NotificationCenter` of its own. A mounted `FileTreeView` subscribes to
    /// `.cloudDownloadRequested` regardless, and on `.default` it would accept other suites' posts
    /// during its pump (`docs/flaky-tests.md`, "A mounted view is a live subscriber, in every suite
    /// at once").
    private func mount(_ box: Box, counter: Counter) -> NSWindow {
        let tree = Self.bigTree(side: .left)
        let otherTree = Self.bigTree(side: .right)
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let delegate = StubDelegate(ignored: [])
        let host = NSHostingView(rootView: Harness(
            box: box, tree: tree, otherTree: otherTree, index: index,
            diffIndex: .empty, delegate: delegate, counter: counter,
            downloads: NotificationCenter()))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    private func pump(_ window: NSWindow, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.01, true)
            window.layoutIfNeeded()
        }
    }

    private func tables(_ view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { found.append(t) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    /// One fixed chunk of CPU-bound work (FNV-1a over a counter), timed on the calling thread and
    /// printed for diagnosis only, ~10ms unloaded. It doesn't reliably stretch when the process is
    /// starved, so don't use it as a load signal for a render. The count is fixed so readings
    /// compare between runs.
    private static let probeIterations = 100_000
    /// The render budget, in milliseconds, sized against the worst starvation measured on this
    /// machine (163ms, nothing regressed) rather than an idle run. A regression between 164ms and
    /// 249ms escapes; a tighter bar would fire on starved runs. To chase one in that band, first
    /// check whether 163ms is still this machine's worst, then move this number.
    private static let budgetMs: Double = 250.0

    private func probeMs() -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        var acc: UInt64 = 0xcbf2_9ce4_8422_2325
        for i in 0..<Self.probeIterations {
            acc = (acc ^ UInt64(i)) &* 0x100_0000_01b3
        }
        // The accumulator must stay observable or the loop is dead code to the optimiser.
        precondition(acc != 0, "FNV accumulator can never be zero")
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    /// Wall time from committing the selection to the view graph having re-rendered and laid out;
    /// `layoutIfNeeded` drives `NSHostingView`'s update. The caller checks the body counter, since a
    /// body that never ran times nothing.
    private func renderMs(_ window: NSWindow, _ body: () -> Void) -> Double {
        let started = CFAbsoluteTimeGetCurrent()
        body()
        window.layoutIfNeeded()
        _ = CFRunLoopRunInMode(.defaultMode, 0, true)
        window.layoutIfNeeded()
        return (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    @Test func benchmarkSelectionClickCost() throws {
        let box = Box()
        let counter = Counter()
        let window = mount(box, counter: counter)
        // Drops the last reference to the SwiftUI graph, and with it the pane's live subscription,
        // rather than leaving it to ARC. Not `close()`, which over-releases a `.titled` window.
        defer { window.contentView = nil }
        // Two columns deep, as the user was: /root/top3/mid7 open, its files listed.
        box.browsePath = PaneBrowsePath(components: ["top3", "mid7"])
        pump(window, seconds: 1.5)

        let columns = tables(window.contentView!)
        #expect(columns.count == 3, "expected three columns; got \(columns.count) — fixture is wrong")
        let rowCounts = columns.map(\.numberOfRows)
        #expect(rowCounts.allSatisfy { $0 > 0 }, "a column materialised no rows: \(rowCounts)")

        // Click a file in the deepest column, repeatedly, as the user does walking a folder. Each
        // sample is paired with a probe reading only for the printed line; nothing is load-adjusted.
        var samples: [Double] = []
        var probes: [Double] = []
        for i in 0..<8 {
            let target = "\(Self.root)/top3/mid7/file-3-7-\(i).pdf"
            probes.append(probeMs())
            let before = counter.bodies
            samples.append(renderMs(window) { box.selection = [target] })
            #expect(counter.bodies > before, "the pane did not re-render — the sample is vacuous")
        }
        let median = samples.sorted()[samples.count / 2]
        let probeMedian = probes.sorted()[probes.count / 2]
        // The probe is printed for diagnosis, not asserted on (see the type comment).
        print("BENCH columns=\(rowCounts) render samples=\(samples.map { Int($0) }) median=\(Int(median))ms "
              + "probes=\(probes.map { Int($0) }) probeMedian=\(Int(probeMedian))ms "
              + "budget=\(Int(Self.budgetMs))ms")
        // ~10ms unloaded, 163ms under deliberate starvation with nothing regressed. The bar clears
        // that and still catches a ~290ms click.
        #expect(median < Self.budgetMs,
                "pane render cost regressed to \(Int(median))ms (was ~10ms; budget \(Int(Self.budgetMs))ms)")
    }
}
