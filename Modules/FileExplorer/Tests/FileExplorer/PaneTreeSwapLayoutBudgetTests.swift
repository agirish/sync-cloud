import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// What a provider switch does to the window's layout budget.
///
/// AppKit runs update-constraints passes until the window stops dirtying itself, and raises
/// `NSGenericException` once it "has already had more update constraints passes than there are
/// views in the window". Both halves of that comparison matter, and the second one is not a
/// constant: `FileSyncManager.invalidateComparisonState()` drops BOTH pane trees synchronously, so
/// a provider switch empties the window's view tree and refills it from a different root. The
/// budget collapses at exactly the moment the churn peaks.
///
/// `PaneColumnsLayoutLoopTests` pins that a *click* settles. These pin the swap: rounds-to-settle
/// against the view count that budgets them.
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

    /// The host's state, both panes. Both sit on one `path` because the first crash had them there
    /// — switching the right provider pointed it at the folder the left pane already showed, which
    /// looked like a shared-anchor bug. It was not: a later crash had the panes on different roots.
    /// The configuration is kept because it is still the harder one to settle, not because it is
    /// the crash's shape.
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

    /// Two panes side by side on one root — the app's shape reduced to what lays out.
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

    /// Every view in the window — the exception's actual budget.
    private func viewCount(_ v: NSView) -> Int {
        1 + v.subviews.reduce(0) { $0 + viewCount($1) }
    }

    private func dirtyCount(_ v: NSView) -> Int {
        (v.needsLayout ? 1 : 0) + (v.needsUpdateConstraints ? 1 : 0)
            + v.subviews.reduce(0) { $0 + dirtyCount($1) }
    }

    /// Layout rounds needed before nothing in the window is dirty any more, measured from the
    /// moment a change lands. NOT preceded by a pump: pumping first measures the settled state and
    /// the assertion becomes vacuous.
    /// **This driver cannot see the AppKit display-cycle guard, and that is measured.**
    /// `layoutIfNeeded()` runs constraint updates with the runaway guards disarmed: a deliberate
    /// never-settling sibling ping-pong survives 400 rounds of it (469,000 `updateConstraints`
    /// calls) without raising, while one second of the RUNLOOP raises on the first cycle. So a low
    /// round count here says the tree stops dirtying itself under a manual pump — worth having, and
    /// not the same claim as "this window will not blow AppKit's pass budget". The runloop-driven
    /// counterpart is `ColumnsDisplayCycleTests`; see `docs/columns-layout-loop.md`.
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

    /// The crash's sequence: two populated panes on one root, then both trees dropped and refilled
    /// from a different root in a single turn.
    @Test func testProviderSwitchTreeSwapSettlesWellInsideTheWindowsViewBudget() throws {
        let box = Box(left: Self.tree(side: .left, files: 60),
                      right: Self.tree(side: .right, files: 60),
                      path: Self.root)
        let window = mount(box)
        pump(window, seconds: 0.5)

        // Not vacuous: both panes really materialised tables with rows in them.
        let before = tableRowCounts(window.contentView!)
        #expect(before.count == 2, "expected two pane tables, got \(before)")
        #expect(before.allSatisfy { $0 == 60 }, "panes did not lay out their rows: \(before)")

        // The swap, exactly as `invalidateComparisonState()` does it: both trees emptied
        // synchronously, then refilled from the new root in the same turn.
        box.left = PaneTree(side: .left, version: 2, nodes: [])
        box.right = PaneTree(side: .right, version: 2, nodes: [])
        box.path = "/newroot"
        box.left = Self.tree(side: .left, files: 19, version: 3)
        box.right = Self.tree(side: .right, files: 19, version: 3)

        let rounds = roundsToSettle(window)
        let views = viewCount(window.contentView!)
        // The exception's own comparison. A margin, not equality: the real window carries the
        // toolbar, both action bars and the details sidebar, and its budget is spent by everything
        // in it, not just by the panes.
        #expect(rounds < views / 4,
                "tree swap took \(rounds) layout rounds against a \(views)-view window — AppKit raises once passes exceed views")
        #expect(rounds < 400, "tree swap never settled (\(rounds) rounds)")
    }

    /// The same swap while the panes are nearly empty — the moment the log caught, where the right
    /// pane had painted 19 nodes and the left had not painted at all. This is where the budget is
    /// smallest, so it is where a fixed amount of churn is likeliest to exceed it.
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
