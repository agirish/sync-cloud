import Testing
import AppKit
import Design
import SwiftUI
import Sync
@testable import FileExplorer

/// What re-rendering a Columns pane costs when a selection changes.
///
/// Built to chase a reported ~290ms click on panes of ~40,000 nodes, and it **cleared the pane**:
/// three open columns over a 40k tree re-render in ~10ms. Two independent results agree that the
/// reported number is not this view's rendering — the same click measured identically in a Release
/// build as in Debug, and optimisation would have moved real computation.
///
/// It stays as the regression net that finding implies: if a pane render ever does start costing
/// what a click was blamed for, this catches it, and the threshold is deliberately far above the
/// measured cost so it fails on a regression rather than on machine noise.
///
/// The fixture has to be REALISTIC or the measurement is worthless: a small tree, or one whose
/// arrays are COW-shared with the assertion, benchmarks at 0.0ms and proves nothing.
@MainActor
@Suite struct ColumnClickCostBenchmark {

    private struct StubDelegate: FileActionDelegate {
        /// Stands in for `FileSyncManager.isNodeIgnored`, which relativizes the path and tests it
        /// against the effective ignore set — per row, per render.
        let ignored: Set<String>
        func handleRefresh() {}
        func handleFocus(_ node: FileNode) {}
        func handleCopy(_ nodes: [FileNode]) {}
        func handleMove(_ nodes: [FileNode]) {}
        func handleDelete(_ nodes: [FileNode]) {}
        func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool) {}
        func handlePaste(_ targetDir: FileNode) {}
        func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode]) {}
        func handlePasteToPath(_ path: String) {}
        func handleDrop(_ nodes: [FileNode], toPath path: String, isMove: Bool) {}
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

    /// ~40,000 nodes, three levels deep, matching the shape the panes actually hold (the user's two
    /// sides are 40,177 and 37,894). Distinct strings throughout so nothing is COW-shared.
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

        var body: some View {
            counter.bodies += 1
            return FileTreeView(
                tree: tree, otherTree: otherTree, isLoading: false,
                currentPath: ColumnClickCostBenchmark.root,
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: delegate, diffIndex: diffIndex,
                viewMode: .columns, childrenIndex: index,
                browsePath: $box.browsePath,
                onColumnNavigate: { box.browsePath = $0 }
            )
        }
    }

    private func mount(_ box: Box, counter: Counter) -> NSWindow {
        let tree = Self.bigTree(side: .left)
        let otherTree = Self.bigTree(side: .right)
        let index = PaneChildrenIndex(tree: tree, treeRoot: Self.root)
        let delegate = StubDelegate(ignored: [])
        let host = NSHostingView(rootView: Harness(
            box: box, tree: tree, otherTree: otherTree, index: index,
            diffIndex: .empty, delegate: delegate, counter: counter))
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

    /// Wall time from committing the selection to the view graph having re-rendered and laid out.
    /// `layoutIfNeeded` drives `NSHostingView`'s update, so this captures the render the click pays
    /// for. The body counter is checked by the caller: a measurement over a body that never ran is
    /// timing nothing.
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
        // Two columns deep, as the user was: /root/top3/mid7 open, its files listed.
        box.browsePath = PaneBrowsePath(components: ["top3", "mid7"])
        pump(window, seconds: 1.5)

        let columns = tables(window.contentView!)
        #expect(columns.count == 3, "expected three columns; got \(columns.count) — fixture is wrong")
        let rowCounts = columns.map(\.numberOfRows)
        #expect(rowCounts.allSatisfy { $0 > 0 }, "a column materialised no rows: \(rowCounts)")

        // Click a file in the deepest column, repeatedly, as the user does walking a folder.
        var samples: [Double] = []
        for i in 0..<8 {
            let target = "\(Self.root)/top3/mid7/file-3-7-\(i).pdf"
            let before = counter.bodies
            samples.append(renderMs(window) { box.selection = [target] })
            #expect(counter.bodies > before, "the pane did not re-render — the sample is vacuous")
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        print("BENCH columns=\(rowCounts) render samples=\(samples.map { Int($0) }) median=\(Int(median))ms")
        // Measured ~10ms. The bar is set well clear of that: this exists to catch a pane render
        // that has genuinely regressed into the range a click was once blamed for, not to police
        // millisecond drift on a machine that is also running Xcode.
        #expect(median < 120, "pane render cost regressed to \(Int(median))ms (was ~10ms)")
    }
}
