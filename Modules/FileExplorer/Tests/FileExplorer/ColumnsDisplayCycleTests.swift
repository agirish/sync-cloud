import Testing
import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers
import Design
import Sync
@testable import FileExplorer

/// The Columns display-cycle runaway, measured on the driver that can see it (see
/// `docs/columns-layout-loop.md`). AppKit's runaway guard never fires on a window driven by
/// `layoutIfNeeded()`: a deliberately never-settling layout survives hundreds of manual passes but
/// raises within a second of the run loop. So these drive the run loop, and measure a continuous
/// number, update-constraints passes per display cycle, rather than survived or crashed.
@MainActor
@Suite struct ColumnsDisplayCycleTests {

    /// Counts AppKit's update-constraints passes. `updateConstraintsIfNeeded` is public API, called
    /// once per pass on both drivers, so the count needs no private API or swizzling.
    final class PassCountingWindow: NSWindow {
        private(set) var passes = 0
        override func updateConstraintsIfNeeded() {
            passes += 1
            super.updateConstraintsIfNeeded()
        }
        func takePasses() -> Int { defer { passes = 0 }; return passes }
    }

    private struct StubDelegate: FileActionDelegate {
        /// Whether every row carries a risky-name badge. Off by default, matching the protocol
        /// extension's nil `riskyNameReason`, under which no row badges.
        var badgesEveryName = false
        /// Counts the badges handed to rows, so the badged arm can't silently measure the pane
        /// without the badge and report "the badge changes nothing".
        var badgesHandedOut: Counter? = nil
        func riskyNameReason(forName name: String, isDirectory: Bool) -> String? {
            guard badgesEveryName else { return nil }
            badgesHandedOut?.count += 1
            return "trailing space"
        }
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

    /// A reference box, because `FileActionDelegate` conformers here are structs and SwiftUI
    /// copies them into the view tree.
    final class Counter: @unchecked Sendable { var count = 0 }

    /// The column width from the app's real defaults (`com.abhishekgirish.SyncCloud`), the
    /// configuration the crashes were taken under.
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
        defaults.set(Double(Self.realColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        let host = NSHostingView(rootView: Harness(box: box, root: root, defaults: defaults))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let window = PassCountingWindow(contentRect: host.frame, styleMask: [.titled],
                                        backing: .buffered, defer: false)
        window.contentView = host
        return window
    }

    /// Spins the run loop, and nothing else, until the window has spent `quietTurns` consecutive
    /// turns without an update-constraints pass. Returns the passes seen on each turn.
    ///
    /// No `layoutIfNeeded`, so not `LayoutPumpWait`: manual layout disarms AppKit's guard and would
    /// perturb the count. Bounded by turns, not seconds (`docs/flaky-tests.md`, "Fixed pumps and
    /// fixed sleeps"), and quiescence is observed, not assumed. Expiry is a failure naming the call
    /// site: a window still churning is the finding.
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

    /// One run-loop turn, in a non-async function because `CFRunLoopRunInMode` is unavailable from
    /// async contexts; 5ms of blocking is what driving a display cycle needs.
    private func spinRunloopOnce() {
        _ = CFRunLoopRunInMode(.defaultMode, 0.005, false)
    }

    /// Spins the run loop until `condition` holds, bounded by turns, failing on expiry with the call
    /// site named. Needed because quiescence isn't arrival: an async step's result isn't there yet
    /// when layout stops moving. Each turn sleeps for real, since `CFRunLoopRunInMode` returns at
    /// once when idle and instant turns advance no clock a timed settle waits on.
    private func pumpUntil(_ window: PassCountingWindow,
                           maxTurns: Int = 400,
                           _ what: String,
                           _ location: SourceLocation = #_sourceLocation,
                           until condition: () -> Bool) async {
        for _ in 0..<maxTurns {
            if condition() { return }
            spinRunloopOnce()
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        Issue.record("\(what) never happened within \(maxTurns) turns", sourceLocation: location)
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

    /// The crash's own sequence and configuration, on the run-loop driver. AppKit raises once a
    /// window's passes exceed its view count; this asserts well inside that, because the number
    /// that matters is how close it came, not whether it survived.
    @Test func testProviderSwitchRepublishStaysWellInsideTheDisplayCycleBudget() {
        let fixture = Fixture(files: 40)
        let box = Box(tree: fixture.tree(files: 40, version: 1))
        let window = mount(box, root: fixture.root, width: 760)
        pumpUntilQuiet(window)

        let before = tableRowCounts(window.contentView!)
        #expect(before.contains(40), "columns did not lay out the root column: \(before)")

        // retargetPane(): this pane's tree is dropped, then the shallow paint from the new root.
        box.tree = PaneTree(side: .left, version: 2, nodes: [])
        box.browsePath = PaneBrowsePath()
        box.tree = fixture.tree(files: 19, version: 3)

        let perTurn = pumpUntilQuiet(window)
        let views = viewCount(window.contentView!)
        let worst = perTurn.max() ?? 0
        let total = perTurn.reduce(0, +)
        // Printed unconditionally: a green check over an instrument that never fired would look
        // like a healthy pane.
        print("[cycle] views=\(views) worst=\(worst) total=\(total) turns=\(perTurn.count)")
        let detail = "worst display cycle spent \(worst) update-constraints passes against "
            + "\(views) views (total \(total) to quiescence); AppKit raises once passes exceed views"
        #expect(worst < views / 4, "\(detail)")
    }

    // MARK: - The whole window, as the app builds it

    /// Two panes, both in Columns, drilled, with a live selection and the action bar's placement
    /// wired: the shape `ContentView.treeView` mounts, and the only one the crash was seen in.
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
        var badges = false
        var badgeCounter: Counter? = nil
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
                delegate: StubDelegate(badgesEveryName: badges, badgesHandedOut: badgeCounter),
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

    private func mountTwoPanes(_ left: PaneBox, _ right: PaneBox, width: CGFloat,
                               badges: Bool = false,
                               badgeCounter: Counter? = nil) -> PassCountingWindow {
        let defaults = ScratchDefaults("ColumnsDisplayCycleTests-two")
        defaults.set(Double(Self.realColumnWidth), forKey: PaneViewMode.columnWidthDefaultsKey)
        let host = NSHostingView(rootView: TwoPaneHarness(left: left, right: right, defaults: defaults, badges: badges,
                                                          badgeCounter: badgeCounter))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        let window = PassCountingWindow(contentRect: host.frame, styleMask: [.titled],
                                        backing: .buffered, defer: false)
        window.contentView = host
        Self.showIfAsked(window)
        return window
    }

    /// SwiftUI's `AppKitPlatformViewHost.enqueueLayoutInvalidation`, the frame that schedules the
    /// extra pass in the crash reports, is driven off the display, and an offscreen window may never
    /// run it. Set `COLUMNS_CYCLE_ONSCREEN=1` to measure on screen rather than assume.
    static func showIfAsked(_ window: NSWindow) {
        guard ProcessInfo.processInfo.environment["COLUMNS_CYCLE_ONSCREEN"] == "1" else { return }
        _ = NSApplication.shared
        window.orderFront(nil)
    }

    /// Both panes in Columns, drilled one level, a file selected, then the right pane's provider
    /// switch (`retargetPane(isLeft: false)`): drop that pane's tree, clear its browse path, paint
    /// the new root. The left pane isn't touched.
    @Test func testTwoPaneProviderSwitchStaysInsideTheDisplayCycleBudget() async {
        let (worst, views) = await twoPaneProviderSwitch(badges: false)
        let detail = "worst display cycle spent \(worst) update-constraints passes against "
            + "\(views) views; AppKit raises once passes exceed views"
        #expect(worst < views / 4, "\(detail)")
    }

    /// The same switch with the risky-name badge (`RiskyNameBadge`) on every row, a suspect in
    /// `docs/columns-layout-loop.md`: it takes width beside a name whose `Text` has no `lineLimit`,
    /// the shape a height oscillation would need. `riskyNameReason` defaults to nil, so the stub
    /// must opt in, and the arm checks badges were really handed out.
    @Test func testTheRiskyNameBadgeDoesNotMoveTheDisplayCycleBudget() async {
        let (worst, views) = await twoPaneProviderSwitch(badges: true)
        let detail = "with badges: worst cycle spent \(worst) passes against \(views) views"
        #expect(worst < views / 4, "\(detail)")
    }

    /// Both arms' shared body, so the only difference between them is the badge.
    private func twoPaneProviderSwitch(badges: Bool,
                                       _ location: SourceLocation = #_sourceLocation)
    async -> (worst: Int, views: Int) {
        let badgeCounter = Counter()
        let fx = DeepFixture(folders: 12, filesPerFolder: 30)
        let other = DeepFixture(folders: 9, filesPerFolder: 21)
        let left = PaneBox(tree: fx.tree(side: .left, folders: 12, filesPerFolder: 30, version: 1),
                           root: fx.root, isLeft: true)
        let right = PaneBox(tree: fx.tree(side: .right, folders: 12, filesPerFolder: 30, version: 1),
                            root: fx.root, isLeft: false)
        let window = mountTwoPanes(left, right, width: 1600, badges: badges,
                                   badgeCounter: badgeCounter)
        pumpUntilQuiet(window)

        // Drill both panes one level and select a file, so each is a two-column stack with a live
        // selection. (The preview is the Info inspector's, so panes have no preview column.)
        for box in [left, right] {
            box.browsePath = PaneBrowsePath(components: [DeepFixture.folder(0)])
            box.selection = ["\(box.root)/\(DeepFixture.folder(0))/\(Fixture.name(0))"]
        }
        await pumpUntil(window, "both panes drilled to two columns") {
            self.tableRowCounts(window.contentView!).count >= 4
        }
        pumpUntilQuiet(window)

        // The arm must really be in its claimed configuration: passing a browse path isn't a pane
        // that drilled, and a plainer pane would report similar numbers. (`onBarEdgeFlip` is wired
        // as in `ContentView` but never fires here, so it is not ruled out.) Checked against what
        // AppKit laid out.
        let tables = tableRowCounts(window.contentView!)
        #expect(tables.count >= 4,
                "both panes were meant to be drilled to a two-column stack; tables: \(tables)")

        // The provider switch: `retargetPane(isLeft: false)`, the right pane only.
        right.tree = PaneTree(side: .right, version: 2, nodes: [])
        right.browsePath = PaneBrowsePath()
        right.selection = []
        right.tree = other.tree(side: .right, folders: 9, filesPerFolder: 21, version: 3)

        let perTurn = pumpUntilQuiet(window)
        let views = viewCount(window.contentView!)
        let worst = perTurn.max() ?? 0
        let total = perTurn.reduce(0, +)
        print("[cycle:two-pane badges=\(badges)] views=\(views) worst=\(worst) "
              + "total=\(total) nonzero=\(perTurn.filter { $0 > 0 })")
        // The arm measured what it claims to have measured.
        if badges {
            #expect(badgeCounter.count > 0,
                    "no row was ever handed a badge — this arm measured the pane WITHOUT it",
                    sourceLocation: location)
        } else {
            #expect(badgeCounter.count == 0, sourceLocation: location)
        }
        return (worst, views)
    }
}
