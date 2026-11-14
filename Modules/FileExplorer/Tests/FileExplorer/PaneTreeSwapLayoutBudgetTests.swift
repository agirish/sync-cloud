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
                delegate: NoOpFileActionDelegate(),
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

    /// A provider switch: two populated panes on one root, then both trees dropped and refilled
    /// from a different root in a single turn, as `invalidateComparisonState()` does it. Without
    /// `refillsLeft`, only the right pane comes back, shallowly: the window is nearly empty, so its
    /// budget is smallest and a fixed amount of churn is likeliest to exceed it.
    @Test(arguments: [true, false])
    func aTreeSwapSettlesWellInsideTheWindowsViewBudget(refillsLeft: Bool) async throws {
        let box = Box(left: Self.tree(side: .left, files: 60),
                      right: Self.tree(side: .right, files: 60),
                      path: Self.root)
        let window = mount(box)
        _ = await LayoutPumpWait.pump(window, upTo: 15) {
            PaneLayoutSettle.tableRowCounts(window.contentView!) == [60, 60]
        }
        // Not vacuous: both panes materialised tables with rows in them.
        #expect(PaneLayoutSettle.tableRowCounts(window.contentView!) == [60, 60])

        box.left = PaneTree(side: .left, version: 2, nodes: [])
        box.right = PaneTree(side: .right, version: 2, nodes: [])
        box.path = "/newroot"
        if refillsLeft { box.left = Self.tree(side: .left, files: 19, version: 3) }
        box.right = Self.tree(side: .right, files: 19, version: 3)

        let rounds = PaneLayoutSettle.roundsToSettle(window, cap: 400)
        let views = PaneLayoutSettle.viewCount(window.contentView!)
        // The exception's own comparison, with a margin: the real window also carries the toolbar,
        // both action bars and the details sidebar, and everything in it spends the budget.
        #expect(rounds < views / 4,
                "tree swap took \(rounds) layout rounds against a \(views)-view window — AppKit raises once passes exceed views")
        #expect(rounds < 400, "tree swap never settled (\(rounds) rounds)")
    }
}
