import Testing
import AppKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// A pane row's ideal HEIGHT must not depend on the width it is offered.
///
/// AppKit raises `NSGenericException` — "marked as needing another update constraints pass, but it
/// has already had more … passes than there are views in the window" — once a window will not stop
/// dirtying itself. The crash of 2026-08-02 21:37 named the mechanism outright:
///
/// ```
/// OutlineListCoordinator.listTableCellView(_:didUpdateIdealHeight:)
///   ← NSHostingView.SizeConstraints.update(from:)
///   ← NSHostingView._willUpdateConstraintsForSubtree()   // inside the pass
/// AppKitPlatformViewHost.enqueueLayoutInvalidation()      // …which schedules another pass
///   → NSHostingView.setNeedsUpdate() → -[NSView setNeedsUpdateConstraints:]
/// ```
///
/// A row reported a new ideal height *during* the update-constraints pass, so the list enqueued
/// another one, in which the row reported a new height again. A row whose name can WRAP has exactly
/// that shape: its height is a function of the width the list offers, and the list's width is a
/// function of the total content height (the scroller). Short synthetic names never wrap, which is
/// why every earlier fixture — and `PaneTreeSwapLayoutBudgetTests` — measured a settled window.
@MainActor
@Suite struct PaneRowHeightStabilityTests {

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

    private static let root = "/root"

    /// Names of the length real documents actually have. `long: false` gives the short synthetic
    /// names every earlier fixture used, so the two can be compared in one run.
    private static func tree(files: Int, long: Bool) -> PaneTree {
        let nodes = (0..<files).map { i -> FileNode in
            let name = long
                ? "Quarterly Business Review \(i) — Consolidated Findings and Appendix (final draft v3).pdf"
                : "file\(i)"
            return FileNode(id: "\(root)/\(name)", name: name, isDirectory: false,
                            fileSize: 1024 * (i + 1))
        }
        return PaneTree(side: .left, version: 1, nodes: nodes)
    }

    private struct Harness: View {
        let tree: PaneTree
        @State private var selection: Set<String> = []

        var body: some View {
            FileTreeView(
                tree: tree,
                otherTree: PaneTree(side: .right, version: 1, nodes: []),
                isLoading: false,
                currentPath: PaneRowHeightStabilityTests.root,
                selection: $selection,
                otherSelection: [],
                isLeft: true,
                delegate: StubDelegate()
            )
        }
    }

    private func mount(_ tree: PaneTree, width: CGFloat) -> NSWindow {
        let host = NSHostingView(rootView: Harness(tree: tree))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
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

    private func rowCount(_ view: NSView) -> Int {
        var n = 0
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { n += t.numberOfRows }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return n
    }

    /// The distinct heights the list's row views are sitting at. One value means every row settled
    /// on the same height; the loop shows up as rows disagreeing.
    private func rowHeights(_ view: NSView) -> Set<CGFloat> {
        var heights: Set<CGFloat> = []
        func walk(_ v: NSView) {
            if v is NSTableRowView { heights.insert(v.frame.height.rounded()) }
            for sub in v.subviews { walk(sub) }
        }
        walk(view)
        return heights
    }

    /// **This driver cannot see the AppKit display-cycle guard, and that is measured.**
    /// `layoutIfNeeded()` runs constraint updates with the runaway guards disarmed: a deliberate
    /// never-settling sibling ping-pong survives 400 rounds of it (469,000 `updateConstraints`
    /// calls) without raising, while one second of the RUNLOOP raises on the first cycle. So a low
    /// round count here says the tree stops dirtying itself under a manual pump — worth having, and
    /// not the same claim as "this window will not blow AppKit's pass budget". The runloop-driven
    /// counterpart is `ColumnsDisplayCycleTests`; see `docs/columns-layout-loop.md`.
    private func roundsToSettle(_ window: NSWindow, cap: Int = 500) -> Int {
        var rounds = 0
        while rounds < cap, dirtyCount(window.contentView!) > 0 {
            window.layoutIfNeeded()
            rounds += 1
        }
        return rounds
    }

    /// Narrowing the pane must not make a row's height a moving target.
    ///
    /// The width sweep is the point: a real pane's width moves (the split divider, the details
    /// sidebar, a window resize), and each new width re-asks every wrapping name how tall it wants
    /// to be. This walks the pane down through the widths where a long name crosses from one line
    /// to two and measures whether the window ever stops dirtying itself.
    @Test func testALongNameDoesNotMakeRowHeightAMovingTarget() {
        let window = mount(Self.tree(files: 40, long: true), width: 900)
        pump(window, seconds: 0.5)
        #expect(rowCount(window.contentView!) == 40, "pane did not lay out its rows — test is vacuous")

        var worst = 0
        var worstWidth: CGFloat = 0
        for width in stride(from: CGFloat(900), through: 260, by: -40) {
            window.setContentSize(NSSize(width: width, height: 600))
            let rounds = roundsToSettle(window)
            if rounds > worst { worst = rounds; worstWidth = width }
        }
        let views = viewCount(window.contentView!)
        let heights = rowHeights(window.contentView!)
        #expect(worst < views / 4,
                "a width change took \(worst) layout rounds against \(views) views — AppKit raises once passes exceed views")
        #expect(heights.count == 1, "rows settled at disagreeing heights \(heights.sorted()) — height is width-dependent")
    }

    /// A row's height must be an INTEGER at every density and text size.
    ///
    /// A hosting view whose ideal height is fractional can never equal the integral height the
    /// table gives its row, so every constraints pass reports a fresh "new" ideal height and
    /// enqueues another — which is the shape of the crash this suite exists for. Asserting
    /// integrality here is cheap and rules that cause out across the whole settings matrix, which
    /// no single mounted pane test can do.
    @Test func testRowHeightIsIntegralAtEveryDensityAndTextSize() {
        // The shipped scales, not a hardcoded list: when `FontSize` moved to the knee curve the
        // old literals (1.15, 1.3) stopped being sizes any user can select, and a sweep over
        // phantom scales proves nothing about the settings matrix.
        for density in [ListDensity.compact, ListDensity.comfortable] {
            for scale in FontSize.allCases.map(\.scale) {
                let row = FileRowView(
                    node: FileRowInfo(FileNode(id: "/a/Some Document Name.pdf",
                                               name: "Some Document Name.pdf",
                                               isDirectory: false, fileSize: 4096)),
                    isIgnored: false, diffStatus: nil, containedDiffCount: 0,
                    density: density, fonts: PaneRowFonts(scale: scale))
                let host = NSHostingView(rootView: row.frame(width: 320))
                let h = host.fittingSize.height
                #expect(h > 0, "row measured no height at \(density)/\(scale) — measurement is vacuous")
                #expect(h == h.rounded(),
                        "row height \(h) is fractional at \(density)/scale \(scale); a fractional ideal height can never match the table's integral row height")
            }
        }
    }

    /// The same sweep with the short synthetic names every earlier fixture used. This is the
    /// control: it is what made the previous investigations measure a settled window and conclude
    /// there was no runaway to find.
    @Test func testShortNamesAreTheControlAndStaySettled() {
        let window = mount(Self.tree(files: 40, long: false), width: 900)
        pump(window, seconds: 0.5)
        #expect(rowCount(window.contentView!) == 40)

        var worst = 0
        for width in stride(from: CGFloat(900), through: 260, by: -40) {
            window.setContentSize(NSSize(width: width, height: 600))
            worst = max(worst, roundsToSettle(window))
        }
        let heights = rowHeights(window.contentView!)
        #expect(heights.count == 1, "even short names disagreed on height: \(heights.sorted())")
    }
}
