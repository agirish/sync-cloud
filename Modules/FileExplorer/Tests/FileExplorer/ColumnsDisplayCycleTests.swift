import Testing
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Design
import Sync
@testable import FileExplorer

/// The Columns display-cycle runaway, measured on the driver that can actually see it.
///
/// See `docs/columns-layout-loop.md`. Every earlier fixture drove the window with
/// `window.layoutIfNeeded()` and reported "settles in 2 rounds"; that verdict is vacuous, because
/// AppKit's runaway guards are not armed on the manual path at all. Measured directly, on a
/// deliberate never-settling sibling ping-pong:
///
/// | driver | guard armed | outcome |
/// |---|---|---|
/// | `layoutIfNeeded()` x400 | yes | survives — 469,000 `updateConstraints` calls, never raises |
/// | one second of the runloop | yes | raises on the first cycle |
///
/// So the metric here is taken across RUNLOOP turns, and it is continuous — update-constraints
/// passes per display cycle — rather than the binary survived/crashed the standing record warns
/// has almost no power.
@MainActor
@Suite struct ColumnsDisplayCycleTests {

    /// Counts AppKit's update-constraints passes. `updateConstraintsIfNeeded` is public API and is
    /// called once per pass on BOTH drivers (verified: 4,690 calls across 400 manual
    /// `layoutIfNeeded`s, 853 across a second of runloop), so the count needs no private API and no
    /// swizzling.
    final class PassCountingWindow: NSWindow {
        private(set) var passes = 0
        override func updateConstraintsIfNeeded() {
            passes += 1
            super.updateConstraintsIfNeeded()
        }
        func takePasses() -> Int { defer { passes = 0 }; return passes }
    }

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

    /// The user's stored values, verbatim, from `com.abhishekgirish.SyncCloud` — the configuration
    /// every crash was taken under.
    private static let realPreviewWidth: CGFloat = 502.35546875
    private static let realColumnWidth: CGFloat = 210

    final class Box: ObservableObject {
        @Published var tree: PaneTree
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
        init(tree: PaneTree) { self.tree = tree }
    }

    final class Fixture {
        let root: String
        init(files: Int) {
            root = NSTemporaryDirectory() + "columns-cycle-" + UUID().uuidString
            let dir = URL(fileURLWithPath: root)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<files {
                try? Data("x".utf8).write(to: dir.appendingPathComponent(Self.name(i)))
            }
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        static func name(_ i: Int) -> String {
            "Quarterly Business Review \(i) — Consolidated Findings (final).txt"
        }

        func tree(files: Int, version: Int) -> PaneTree {
            let nodes = (0..<files).map { i -> FileNode in
                FileNode(id: "\(root)/\(Self.name(i))", name: Self.name(i), isDirectory: false,
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

    private func mount(_ box: Box, root: String, width: CGFloat) -> PassCountingWindow {
        let defaults = ScratchDefaults("ColumnsDisplayCycleTests")
        defaults.set(true, forKey: PaneViewMode.previewColumnDefaultsKey)
        defaults.set(Double(Self.realColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        defaults.set(Double(Self.realPreviewWidth), forKey: PaneViewMode.previewColumnWidthDefaultsKey)
        let host = NSHostingView(rootView: Harness(box: box, root: root, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let window = PassCountingWindow(contentRect: host.frame, styleMask: [.titled],
                                        backing: .buffered, defer: false)
        window.contentView = host
        return window
    }

    /// Spins the runloop — and NOTHING else — until the window has spent `quietTurns` consecutive
    /// turns without a single update-constraints pass. Returns the passes seen on each turn.
    ///
    /// **No `layoutIfNeeded`: that is the whole point.** `LayoutPumpWait` cannot be reused here for
    /// exactly that reason — it pumps by hand, which is the driver AppKit's guards are disarmed on,
    /// and it would also perturb the very count being taken.
    ///
    /// **Bounded by TURNS, not by seconds**, per `docs/flaky-tests.md` mechanism 2 and for the
    /// reason `LayoutPumpWait.pumpFloor` spells out: what a congested machine is short of is
    /// main-actor turns, not wall clock, so a seconds budget buys fewer turns exactly when more are
    /// needed. A fixed turn count would have the same defect from the other side — quiescence would
    /// be assumed rather than observed. Expiry is a FAILURE naming the call site, never a silent
    /// short read: a window still churning when the bound runs out is the finding, not the setup.
    @discardableResult
    private func pumpUntilQuiet(_ window: PassCountingWindow,
                                quietTurns: Int = 8,
                                maxTurns: Int = 1500,
                                _ location: SourceLocation = #_sourceLocation) -> [Int] {
        var perTurn: [Int] = []
        var quiet = 0
        while perTurn.count < maxTurns {
            _ = window.takePasses()
            _ = CFRunLoopRunInMode(.defaultMode, 0.005, false)
            let passes = window.passes
            perTurn.append(passes)
            quiet = (passes == 0) ? quiet + 1 : 0
            if quiet >= quietTurns { return perTurn }
        }
        let why = "the window never went quiet: \(maxTurns) turns, \(perTurn.reduce(0, +)) "
            + "passes total, last twenty \(Array(perTurn.suffix(20)))"
        Issue.record("\(why)", sourceLocation: location)
        return perTurn
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

    /// The crash's own sequence, in the crash's own configuration, on the runloop driver.
    ///
    /// The budget is AppKit's own: it raises once a window's passes exceed its view count. This
    /// asserts an order of magnitude inside that, because the interesting number is not "did it
    /// survive" but "how close did it come".
    @Test func testProviderSwitchRepublishStaysWellInsideTheDisplayCycleBudget() {
        let fixture = Fixture(files: 40)
        let box = Box(tree: fixture.tree(files: 40, version: 1))
        let window = mount(box, root: fixture.root, width: 760)
        pumpUntilQuiet(window)

        let before = tableRowCounts(window.contentView!)
        #expect(before.contains(40), "columns did not lay out the root column: \(before)")

        // resetNavigation(): the tree is dropped, then the shallow paint from the new root.
        box.tree = PaneTree(side: .left, version: 2, nodes: [])
        box.browsePath = PaneBrowsePath()
        box.tree = fixture.tree(files: 19, version: 3)

        let perTurn = pumpUntilQuiet(window)
        let views = viewCount(window.contentView!)
        let worst = perTurn.max() ?? 0
        let total = perTurn.reduce(0, +)
        // Printed unconditionally: a green assertion over an instrument that never fired reports a
        // healthy pane, which is precisely the failure mode this file exists to avoid.
        print("[cycle] views=\(views) worst=\(worst) total=\(total) turns=\(perTurn.count)")
        let detail = "worst display cycle spent \(worst) update-constraints passes against "
            + "\(views) views (total \(total) to quiescence); AppKit raises once passes exceed views"
        #expect(worst < views / 4, "\(detail)")
    }

    // MARK: - The whole window, as the app builds it

    /// Two panes, both in Columns, drilled, with a live selection and the action bar's placement
    /// wired — the shape `ContentView.treeView` actually mounts, which the single-pane fixture above
    /// omits almost all of. The crash has only ever been taken here.
    final class PaneBox: ObservableObject {
        @Published var tree: PaneTree
        @Published var browsePath = PaneBrowsePath()
        @Published var selection: Set<String> = []
        let root: String
        let isLeft: Bool
        let placement = PaneBarPlacement()
        init(tree: PaneTree, root: String, isLeft: Bool) {
            self.tree = tree; self.root = root; self.isLeft = isLeft
        }
    }

    /// A real on-disk root of folders-with-files: the preview column reads the filesystem, and a
    /// drilled stack needs directories to drill into.
    final class DeepFixture {
        let root: String
        init(folders: Int, filesPerFolder: Int) {
            root = NSTemporaryDirectory() + "columns-deep-" + UUID().uuidString
            let fm = FileManager.default
            for f in 0..<folders {
                let dir = URL(fileURLWithPath: root).appendingPathComponent(Self.folder(f))
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for i in 0..<filesPerFolder {
                    try? Data("x".utf8).write(to: dir.appendingPathComponent(Fixture.name(i)))
                }
            }
        }
        deinit { try? FileManager.default.removeItem(atPath: root) }

        static func folder(_ f: Int) -> String { "Folder \(f) — Archived Correspondence" }

        func tree(side: PaneTree.Side, folders: Int, filesPerFolder: Int, version: Int) -> PaneTree {
            let nodes = (0..<folders).map { f -> FileNode in
                let dir = "\(root)/\(Self.folder(f))"
                let kids = (0..<filesPerFolder).map { i in
                    FileNode(id: "\(dir)/\(Fixture.name(i))", name: Fixture.name(i),
                             isDirectory: false, fileSize: 1,
                             kind: UTType.plainText.identifier)
                }
                return FileNode(id: dir, name: Self.folder(f), isDirectory: true, children: kids)
            }
            return PaneTree(side: side, version: version, nodes: nodes)
        }
    }

    private struct TwoPaneHarness: View {
        @ObservedObject var left: PaneBox
        @ObservedObject var right: PaneBox
        let defaults: UserDefaults
        /// The host state `onBarEdgeFlip` toggles, exactly as `ContentView` does.
        @State private var leftBarAtTop = false
        @State private var rightBarAtTop = false

        var body: some View {
            HStack(spacing: 0) {
                pane(left, barAtTop: $leftBarAtTop)
                pane(right, barAtTop: $rightBarAtTop)
            }
            .defaultAppStorage(defaults)
        }

        @ViewBuilder
        private func pane(_ box: PaneBox, barAtTop: Binding<Bool>) -> some View {
            FileTreeView(
                tree: box.tree,
                otherTree: PaneTree(side: box.isLeft ? .right : .left, version: 1, nodes: []),
                isLoading: false,
                currentPath: box.root,
                selection: Binding(get: { box.selection }, set: { box.selection = $0 }),
                otherSelection: [],
                isLeft: box.isLeft,
                delegate: StubDelegate(),
                isSingleSource: false,
                placement: box.placement,
                onBarEdgeFlip: { withAnimation(.easeInOut(duration: 0.22)) { barAtTop.wrappedValue.toggle() } },
                isActivePane: true,
                viewMode: .columns,
                childrenIndex: PaneChildrenIndex(tree: box.tree, treeRoot: box.root),
                browsePath: Binding(get: { box.browsePath }, set: { box.browsePath = $0 }),
                onColumnNavigate: { box.browsePath = $0 },
                onBackgroundDeselect: { _ in }
            )
            .equatable()
        }
    }

    private func mountTwoPanes(_ left: PaneBox, _ right: PaneBox, width: CGFloat) -> PassCountingWindow {
        let defaults = ScratchDefaults("ColumnsDisplayCycleTests-two")
        defaults.set(true, forKey: PaneViewMode.previewColumnDefaultsKey)
        defaults.set(Double(Self.realColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        defaults.set(Double(Self.realPreviewWidth), forKey: PaneViewMode.previewColumnWidthDefaultsKey)
        let host = NSHostingView(rootView: TwoPaneHarness(left: left, right: right, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        let window = PassCountingWindow(contentRect: host.frame, styleMask: [.titled],
                                        backing: .buffered, defer: false)
        window.contentView = host
        Self.showIfAsked(window)
        return window
    }

    /// SwiftUI's `AppKitPlatformViewHost.enqueueLayoutInvalidation` — the frame that schedules the
    /// extra pass in every crash report — is driven off the display. An offscreen window may never
    /// run it, which would make any headless fixture structurally blind. Opt in with
    /// `COLUMNS_CYCLE_ONSCREEN=1` to measure that arm rather than assume it.
    static func showIfAsked(_ window: NSWindow) {
        guard ProcessInfo.processInfo.environment["COLUMNS_CYCLE_ONSCREEN"] == "1" else { return }
        _ = NSApplication.shared
        window.orderFront(nil)
    }

    /// The real thing: both panes in Columns, drilled one level, a file selected so the preview
    /// column is up — then the right pane's provider switch, which is `resetNavigation()`: drop the
    /// tree, clear the browse path, paint the new root.
    @Test func testTwoPaneProviderSwitchStaysInsideTheDisplayCycleBudget() {
        let fx = DeepFixture(folders: 12, filesPerFolder: 30)
        let other = DeepFixture(folders: 9, filesPerFolder: 21)
        let left = PaneBox(tree: fx.tree(side: .left, folders: 12, filesPerFolder: 30, version: 1),
                           root: fx.root, isLeft: true)
        let right = PaneBox(tree: fx.tree(side: .right, folders: 12, filesPerFolder: 30, version: 1),
                            root: fx.root, isLeft: false)
        let window = mountTwoPanes(left, right, width: 1600)
        pumpUntilQuiet(window)

        // Drill both panes one level and select a file, so each pane is a two-column stack with the
        // preview column up — the configuration every crash report was taken in.
        for box in [left, right] {
            box.browsePath = PaneBrowsePath(components: [DeepFixture.folder(0)])
            box.selection = ["\(box.root)/\(DeepFixture.folder(0))/\(Fixture.name(0))"]
        }
        pumpUntilQuiet(window)

        // The provider switch: `resetNavigation()` on the right pane.
        right.tree = PaneTree(side: .right, version: 2, nodes: [])
        right.browsePath = PaneBrowsePath()
        right.selection = []
        right.tree = other.tree(side: .right, folders: 9, filesPerFolder: 21, version: 3)

        let perTurn = pumpUntilQuiet(window)
        let views = viewCount(window.contentView!)
        let worst = perTurn.max() ?? 0
        let total = perTurn.reduce(0, +)
        print("[cycle:two-pane] views=\(views) worst=\(worst) total=\(total) nonzero=\(perTurn.filter { $0 > 0 })")
        let detail = "worst display cycle spent \(worst) update-constraints passes against "
            + "\(views) views (total \(total)); AppKit raises once passes exceed views"
        #expect(worst < views / 4, "\(detail)")
    }
}
