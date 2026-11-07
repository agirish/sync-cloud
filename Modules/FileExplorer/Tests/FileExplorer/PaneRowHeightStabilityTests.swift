import Testing
import AppKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// A pane row's ideal height must not depend on the width it is offered.
///
/// AppKit raises `NSGenericException` ("…already had more … passes than there are views in the
/// window") once a window won't stop dirtying itself. The path looks like this:
///
/// ```
/// OutlineListCoordinator.listTableCellView(_:didUpdateIdealHeight:)
///   ← NSHostingView.SizeConstraints.update(from:)
///   ← NSHostingView._willUpdateConstraintsForSubtree()   // inside the pass
/// AppKitPlatformViewHost.enqueueLayoutInvalidation()      // …which schedules another pass
///   → NSHostingView.setNeedsUpdate() → -[NSView setNeedsUpdateConstraints:]
/// ```
///
/// A row that reports a new ideal height during the update-constraints pass makes the list enqueue
/// another, in which it reports a new height again. A row whose name can wrap has that shape: its
/// height depends on the width the list offers, and the list's width on the total content height
/// (the scroller). Short synthetic names never wrap, so fixtures using them always settle.
@MainActor
@Suite struct PaneRowHeightStabilityTests {

    private static let root = "/root"

    /// Names of the length real documents have. `long: false` gives short synthetic names, so the
    /// two can be compared in one run.
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
                delegate: NoOpFileActionDelegate()
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

    /// Narrowing the pane must not make a row's height a moving target.
    ///
    /// The width sweep is the point: a real pane's width moves (the split divider, the details
    /// sidebar, a window resize), and each new width re-asks every wrapping name how tall it wants
    /// to be. This walks the pane down through the widths where a long name goes from one line to
    /// two and measures whether the window ever stops dirtying itself.
    @Test func testALongNameDoesNotMakeRowHeightAMovingTarget() async {
        let window = mount(Self.tree(files: 40, long: true), width: 900)
        _ = await LayoutPumpWait.pump(window, upTo: 15) { rowCount(window.contentView!) == 40 }
        #expect(rowCount(window.contentView!) == 40, "pane did not lay out its rows — test is vacuous")

        var worst = 0
        var worstWidth: CGFloat = 0
        for width in stride(from: CGFloat(900), through: 260, by: -40) {
            window.setContentSize(NSSize(width: width, height: 600))
            let rounds = PaneLayoutSettle.roundsToSettle(window)
            if rounds > worst { worst = rounds; worstWidth = width }
        }
        let views = PaneLayoutSettle.viewCount(window.contentView!)
        let heights = rowHeights(window.contentView!)
        #expect(worst < views / 4,
                "the width change to \(worstWidth)pt took \(worst) layout rounds against \(views) views — AppKit raises once passes exceed views")
        #expect(heights.count == 1, "rows settled at disagreeing heights \(heights.sorted()) — height is width-dependent")
    }

    /// A row's height must be an integer at every density and text size.
    ///
    /// A hosting view with a fractional ideal height can never equal the integral height the table
    /// gives its row, so every constraints pass reports a "new" ideal height and enqueues another:
    /// the loop this suite exists for. Asserting integrality is cheap and rules that cause out
    /// across the whole settings matrix, which no single mounted pane test can do.
    @Test func testRowHeightIsIntegralAtEveryDensityAndTextSize() {
        // The shipped scales, not a hardcoded list: literals drift from the sizes a user can
        // select, and a sweep over phantom scales proves nothing about the settings matrix.
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

    /// The same sweep with short synthetic names: the control, which stays settled where long names
    /// might not.
    @Test func testShortNamesAreTheControlAndStaySettled() async {
        let window = mount(Self.tree(files: 40, long: false), width: 900)
        _ = await LayoutPumpWait.pump(window, upTo: 15) { rowCount(window.contentView!) == 40 }
        #expect(rowCount(window.contentView!) == 40)

        var worst = 0
        for width in stride(from: CGFloat(900), through: 260, by: -40) {
            window.setContentSize(NSSize(width: width, height: 600))
            worst = max(worst, PaneLayoutSettle.roundsToSettle(window))
        }
        let heights = rowHeights(window.contentView!)
        #expect(heights.count == 1, "even short names disagreed on height: \(heights.sorted())")
    }
}
