import Testing
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Design
import Sync
@testable import FileExplorer

/// A republish while the pane is in Columns must leave the window's layout settled. The AppKit
/// display-cycle crash comes from a cell's ideal-height update inside a constraints pass scheduling
/// another (`OutlineListCoordinator.listTableCellView(_:didUpdateIdealHeight:)` under
/// `NSHostingView._willUpdateConstraintsForSubtree()`, then
/// `AppKitPlatformViewHost.enqueueLayoutInvalidation()`), triggered by a provider switch that drops
/// the pane's tree for a shallow one. So this runs Columns at compact density, the configuration
/// the crash needs; Tree mode at comfortable density doesn't reproduce it.
@MainActor
@Suite struct ColumnsRepublishLayoutLoopTests {

    /// The column width from the app's real defaults (`com.abhishekgirish.SyncCloud`).
    private static let realColumnWidth: CGFloat = 210

    typealias Box = ColumnsDisplayCycleTests.Box
    typealias Fixture = ColumnsDisplayCycleTests.Fixture

    private struct Harness: View {
        @ObservedObject var box: Box
        let root: String
        let defaults: UserDefaults

        var body: some View {
            PaneColumnsView(
                tree: box.tree, otherTree: PaneTree(side: .right, version: 1, nodes: []),
                childrenIndex: PaneChildrenIndex(tree: box.tree, treeRoot: root), treeRoot: root,
                browsePath: $box.browsePath, onNavigate: { box.browsePath = $0 },
                selection: $box.selection, otherSelection: [], isLeft: true,
                delegate: NoOpFileActionDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in },
                onBackgroundDeselect: { _ in }
            )
            .defaultAppStorage(defaults)
        }
    }

    private func mount(_ box: Box, root: String, width: CGFloat) -> NSWindow {
        let defaults = ScratchDefaults("ColumnsRepublishLayoutLoopTests")
        defaults.set(Double(Self.realColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        let host = NSHostingView(rootView: Harness(box: box, root: root, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        return window
    }

    /// The crash's own sequence, in the crash's own configuration.
    @Test func testProviderSwitchRepublishInColumnsSettles() async {
        let fixture = Fixture(files: 40)
        let box = Box(tree: fixture.tree(files: 40, version: 1))
        let window = mount(box, root: fixture.root, width: 760)
        _ = await LayoutPumpWait.pump(window, upTo: 15) {
            PaneLayoutSettle.tableRowCounts(window.contentView!).contains(40)
        }

        let before = PaneLayoutSettle.tableRowCounts(window.contentView!)
        #expect(before.contains(40), "columns did not lay out the root column: \(before)")

        // retargetPane(): this pane's tree dropped, then the shallow 19-node paint from the new root.
        box.tree = PaneTree(side: .left, version: 2, nodes: [])
        box.browsePath = PaneBrowsePath()
        box.tree = fixture.tree(files: 19, version: 3)

        let rounds = PaneLayoutSettle.roundsToSettle(window)
        let views = PaneLayoutSettle.viewCount(window.contentView!)
        #expect(rounds < views / 4,
                "republish took \(rounds) layout rounds against \(views) views — AppKit raises once passes exceed views")
    }

    /// The same republish while the pane's width moves, which is what a real provider switch does to
    /// a Columns pane: the column stack re-fits.
    @Test func testRepublishWhileTheColumnStackRefitsSettles() async {
        let fixture = Fixture(files: 40)
        let box = Box(tree: fixture.tree(files: 40, version: 1))
        let window = mount(box, root: fixture.root, width: 900)
        _ = await LayoutPumpWait.pump(window, upTo: 15) {
            PaneLayoutSettle.tableRowCounts(window.contentView!).contains(40)
        }
        #expect(PaneLayoutSettle.tableRowCounts(window.contentView!).contains(40))

        var worst = 0
        var worstWidth: CGFloat = 0
        var version = 2
        for width in stride(from: CGFloat(900), through: 420, by: -60) {
            window.setContentSize(NSSize(width: width, height: 700))
            box.tree = PaneTree(side: .left, version: version, nodes: [])
            box.tree = fixture.tree(files: 19, version: version + 1)
            version += 2
            let rounds = PaneLayoutSettle.roundsToSettle(window)
            if rounds > worst { worst = rounds; worstWidth = width }
        }
        let views = PaneLayoutSettle.viewCount(window.contentView!)
        #expect(worst < views / 4,
                "a republish took \(worst) layout rounds against \(views) views at width \(worstWidth)")
    }
}
