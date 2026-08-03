import Testing
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Design
import Sync
@testable import FileExplorer

/// A republish while the pane is in COLUMNS must leave the window's layout settled.
///
/// Every occurrence of the AppKit display-cycle crash has been taken with both panes in Columns
/// (`paneViewModeLeft/Right = columns`), preview shown, compact density. The 2026-08-02 21:37 report
/// named the mechanism:
///
/// ```
/// OutlineListCoordinator.listTableCellView(_:didUpdateIdealHeight:)
///   ← NSHostingView._willUpdateConstraintsForSubtree()   // inside the pass
/// AppKitPlatformViewHost.enqueueLayoutInvalidation()      // …which schedules another
/// ```
///
/// and the log named the trigger — twice, identically: "switched right provider to iCloud" →
/// "reset navigation to root" → the pane's tree is dropped and replaced by a shallow 19-node one.
///
/// The earlier fixtures missed it by running the pane in TREE mode at COMFORTABLE density with the
/// default preview width. This one uses the configuration the crashes were actually taken under,
/// including the fractional stored preview width, which is what a real resized preview leaves
/// behind.
@MainActor
@Suite struct ColumnsRepublishLayoutLoopTests {

    private struct StubDelegate: FileActionDelegate {
        func handleRefresh() {}
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

    /// The user's stored values, verbatim, from `com.abhishekgirish.SyncCloud`.
    private static let realPreviewWidth: CGFloat = 502.35546875
    private static let realColumnWidth: CGFloat = 210

    final class Box: ObservableObject {
        @Published var tree: PaneTree
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
        init(tree: PaneTree) { self.tree = tree }
    }

    /// A real on-disk root: the preview column reads the filesystem, so synthetic paths give it
    /// nothing to lay out and the column it would add never appears.
    final class Fixture {
        let root: String
        init(files: Int) {
            root = NSTemporaryDirectory() + "columns-loop-" + UUID().uuidString
            let dir = URL(fileURLWithPath: root)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<files {
                let name = "Quarterly Business Review \(i) — Consolidated Findings (final).txt"
                try? Data("x".utf8).write(to: dir.appendingPathComponent(name))
            }
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        func tree(files: Int, version: Int) -> PaneTree {
            let nodes = (0..<files).map { i -> FileNode in
                let name = "Quarterly Business Review \(i) — Consolidated Findings (final).txt"
                return FileNode(id: "\(root)/\(name)", name: name, isDirectory: false,
                                fileSize: 1, kind: UTType.plainText.identifier)
            }
            return PaneTree(side: .left, version: version, nodes: nodes)
        }
    }

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
                delegate: StubDelegate(), diffIndex: .empty, otherPaneName: "R",
                isSingleSource: false, density: .compact, isActivePane: true,
                placement: nil, onBarEdgeFlip: nil, onQuickLook: { _ in },
                onBackgroundDeselect: { _ in }
            )
            .defaultAppStorage(defaults)
        }
    }

    private func mount(_ box: Box, root: String, width: CGFloat) -> NSWindow {
        let defaults = ScratchDefaults("ColumnsRepublishLayoutLoopTests")
        defaults.set(true, forKey: PaneViewMode.previewColumnDefaultsKey)
        defaults.set(Double(Self.realColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        defaults.set(Double(Self.realPreviewWidth), forKey: PaneViewMode.previewColumnWidthDefaultsKey)
        let host = NSHostingView(rootView: Harness(box: box, root: root, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
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

    private func dirtyCount(_ v: NSView) -> Int {
        (v.needsLayout ? 1 : 0) + (v.needsUpdateConstraints ? 1 : 0)
            + v.subviews.reduce(0) { $0 + dirtyCount($1) }
    }

    private func viewCount(_ v: NSView) -> Int {
        1 + v.subviews.reduce(0) { $0 + viewCount($1) }
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

    private func roundsToSettle(_ window: NSWindow, cap: Int = 500) -> Int {
        var rounds = 0
        while rounds < cap, dirtyCount(window.contentView!) > 0 {
            window.layoutIfNeeded()
            rounds += 1
        }
        return rounds
    }

    /// The crash's own sequence, in the crash's own configuration.
    @Test func testProviderSwitchRepublishInColumnsSettles() {
        let fixture = Fixture(files: 40)
        let box = Box(tree: fixture.tree(files: 40, version: 1))
        let window = mount(box, root: fixture.root, width: 760)
        pump(window, seconds: 0.6)

        let before = tableRowCounts(window.contentView!)
        #expect(before.contains(40), "columns did not lay out the root column: \(before)")

        // resetNavigation(): tree dropped, then the shallow 19-node paint from the new root.
        box.tree = PaneTree(side: .left, version: 2, nodes: [])
        box.browsePath = PaneBrowsePath()
        box.tree = fixture.tree(files: 19, version: 3)

        let rounds = roundsToSettle(window)
        let views = viewCount(window.contentView!)
        #expect(rounds < views / 4,
                "republish took \(rounds) layout rounds against \(views) views — AppKit raises once passes exceed views")
    }

    /// The same republish while the pane's width moves, which is what a real provider switch does to
    /// a Columns pane: the column stack re-fits and the preview column's share changes with it.
    @Test func testRepublishWhileTheColumnStackRefitsSettles() {
        let fixture = Fixture(files: 40)
        let box = Box(tree: fixture.tree(files: 40, version: 1))
        let window = mount(box, root: fixture.root, width: 900)
        pump(window, seconds: 0.6)
        #expect(tableRowCounts(window.contentView!).contains(40))

        var worst = 0
        var worstWidth: CGFloat = 0
        var version = 2
        for width in stride(from: CGFloat(900), through: 420, by: -60) {
            window.setContentSize(NSSize(width: width, height: 700))
            box.tree = PaneTree(side: .left, version: version, nodes: [])
            box.tree = fixture.tree(files: 19, version: version + 1)
            version += 2
            let rounds = roundsToSettle(window)
            if rounds > worst { worst = rounds; worstWidth = width }
        }
        let views = viewCount(window.contentView!)
        #expect(worst < views / 4,
                "a republish took \(worst) layout rounds against \(views) views at width \(worstWidth)")
    }
}
