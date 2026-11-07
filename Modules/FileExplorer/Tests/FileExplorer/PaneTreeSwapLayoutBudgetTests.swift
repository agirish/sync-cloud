import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// What a provider switch does to the window's layout budget. AppKit raises `NSGenericException`
/// once a window has had more update-constraints passes than it has views, and the view count is
/// not a constant: `FileSyncManager.invalidateComparisonState()` drops both pane trees
/// synchronously, so a provider switch empties the view tree and refills it from another root, and
/// the budget collapses just as the churn peaks. `PaneColumnsLayoutLoopTests` pins that a click
/// settles; these pin the swap, rounds-to-settle against the view count that budgets them.
@MainActor
@Suite struct PaneTreeSwapLayoutBudgetTests {

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

    /// The host's state, both panes. Both sit on one `path` because that is the harder
    /// configuration to settle.
    final class Box: ObservableObject {
        @Published var left: PaneTree
        @Published var right: PaneTree
        @Published var path: String
        @Published var leftSelection: Set<String> = []
        @Published var rightSelection: Set<String> = []
        init(left: PaneTree, right: PaneTree, path: String) {
            self.left = left
            self.right = right
            self.path = path
        }
    }

    private static let root = "/root"

    private static func tree(side: PaneTree.Side, files: Int, version: Int = 1) -> PaneTree {
        let nodes = (0..<files).map { i in
            FileNode(id: "\(root)/file\(i)", name: "file\(i)", isDirectory: false,
                     fileSize: 1024 * (i + 1))
        }
        return PaneTree(side: side, version: version, nodes: nodes)
    }

    /// Two panes side by side on one root: the app's shape reduced to what lays out.
    private struct Harness: View {
        @ObservedObject var box: Box
        let leftPlacement: PaneBarPlacement
        let rightPlacement: PaneBarPlacement

        var body: some View {
            HStack(spacing: 0) {
                pane(tree: box.left, other: box.right, isLeft: true,
                     selection: $box.leftSelection, placement: leftPlacement)
                Divider()
                pane(tree: box.right, other: box.left, isLeft: false,
                     selection: $box.rightSelection, placement: rightPlacement)
            }
        }

        private func pane(tree: PaneTree, other: PaneTree, isLeft: Bool,
                          selection: Binding<Set<String>>, placement: PaneBarPlacement) -> some View {
            FileTreeView(
                tree: tree,
                otherTree: other,
                isLoading: false,
                currentPath: box.path,
                selection: selection,
                otherSelection: [],
                isLeft: isLeft,
                delegate: StubDelegate(),
                placement: placement,
                onBarEdgeFlip: {},
                isActivePane: isLeft
            )
        }
    }

    private func mount(_ box: Box) -> NSWindow {
        let host = NSHostingView(rootView: Harness(box: box,
                                                   leftPlacement: PaneBarPlacement(),
                                                   rightPlacement: PaneBarPlacement()))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
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

    /// Every view in the window: the exception's actual budget.
    private func viewCount(_ v: NSView) -> Int {
        1 + v.subviews.reduce(0) { $0 + viewCount($1) }
    }

    private func dirtyCount(_ v: NSView) -> Int {
        (v.needsLayout ? 1 : 0) + (v.needsUpdateConstraints ? 1 : 0)
            + v.subviews.reduce(0) { $0 + dirtyCount($1) }
    }

    /// Layout rounds needed before nothing in the window is dirty, measured from the moment a
    /// change lands. Not preceded by a pump: pumping first measures the settled state, a vacuous
    /// pass. This driver can't see AppKit's display-cycle guard: `layoutIfNeeded()` runs constraint
    /// updates with the runaway guards disarmed, so a never-settling loop survives 400 rounds here
    /// while the run loop raises on its first cycle. A low count says the tree stops dirtying
    /// itself under a manual pump, not that the window stays inside AppKit's pass budget; the
    /// run-loop counterpart is `ColumnsDisplayCycleTests` (see `docs/columns-layout-loop.md`).
    private func roundsToSettle(_ window: NSWindow, cap: Int = 400) -> Int {
        var rounds = 0
        while rounds < cap, dirtyCount(window.contentView!) > 0 {
            window.layoutIfNeeded()
            rounds += 1
        }
        return rounds
    }

    private func tableRowCounts(_ view: NSView) -> [Int] {
        var counts: [Int] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { counts.append(t.numberOfRows) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return counts
    }

    /// A provider switch: two populated panes on one root, then both trees dropped and refilled
    /// from a different root in a single turn.
    @Test func testProviderSwitchTreeSwapSettlesWellInsideTheWindowsViewBudget() throws {
        let box = Box(left: Self.tree(side: .left, files: 60),
                      right: Self.tree(side: .right, files: 60),
                      path: Self.root)
        let window = mount(box)
        pump(window, seconds: 0.5)

        // Not vacuous: both panes materialised tables with rows in them.
        let before = tableRowCounts(window.contentView!)
        #expect(before.count == 2, "expected two pane tables, got \(before)")
        #expect(before.allSatisfy { $0 == 60 }, "panes did not lay out their rows: \(before)")

        // The swap as `invalidateComparisonState()` does it: both trees emptied synchronously, then
        // refilled from the new root in the same turn.
        box.left = PaneTree(side: .left, version: 2, nodes: [])
        box.right = PaneTree(side: .right, version: 2, nodes: [])
        box.path = "/newroot"
        box.left = Self.tree(side: .left, files: 19, version: 3)
        box.right = Self.tree(side: .right, files: 19, version: 3)

        let rounds = roundsToSettle(window)
        let views = viewCount(window.contentView!)
        // The exception's own comparison, with a margin: the real window also carries the toolbar,
        // both action bars and the details sidebar, and everything in it spends the budget.
        #expect(rounds < views / 4,
                "tree swap took \(rounds) layout rounds against a \(views)-view window — AppKit raises once passes exceed views")
        #expect(rounds < 400, "tree swap never settled (\(rounds) rounds)")
    }

    /// The same swap into a nearly empty window: the right pane paints 19 nodes and the left none.
    /// The budget is smallest here, so a fixed amount of churn is likeliest to exceed it.
    @Test func testSwapIntoANearlyEmptyWindowStaysInsideItsShrunkenBudget() throws {
        let box = Box(left: Self.tree(side: .left, files: 60),
                      right: Self.tree(side: .right, files: 60),
                      path: Self.root)
        let window = mount(box)
        pump(window, seconds: 0.5)
        #expect(tableRowCounts(window.contentView!).allSatisfy { $0 == 60 })

        // Both trees dropped; only the right one comes back, and only shallowly.
        box.left = PaneTree(side: .left, version: 2, nodes: [])
        box.right = PaneTree(side: .right, version: 2, nodes: [])
        box.path = "/newroot"
        box.right = Self.tree(side: .right, files: 19, version: 3)

        let rounds = roundsToSettle(window)
        let views = viewCount(window.contentView!)
        #expect(rounds < views / 4,
                "swap into a nearly-empty window took \(rounds) rounds against \(views) views")
        #expect(rounds < 400, "swap never settled (\(rounds) rounds)")
    }
}
