import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// A click in a column must leave the pane's layout settled. AppKit raises `NSGenericException`
/// ("…more … passes than there are views in the window") when a window never stops dirtying
/// itself, which a drill can cause if pane and host resolve the bar's edge from different
/// selections. These pin one source for the anchor, and no flip the host would un-flip.
@MainActor
@Suite struct PaneColumnsLayoutLoopTests {

    private typealias Box = PaneBarHostHarness.Box
    private typealias Counter = PaneBarHostHarness.Counter

    private func mount(_ box: Box, counter: Counter) -> (NSWindow, PaneBarPlacement) {
        PaneBarHostHarness.mount(box, counter: counter)
    }

    private func pump(_ window: NSWindow, seconds: Double) {
        PaneBarHostHarness.pump(window, seconds: seconds)
    }

    /// Clicking a folder low in a column must not make the pane ask the host to move the bar for a
    /// selection the host isn't showing a bar for.
    @Test func testDrillOnALowRowDoesNotFlipAnEdgeTheHostWillUnflip() throws {
        let box = Box(tree: PaneBarHostHarness.tree(folders: 40))
        let counter = Counter()
        let (window, placement) = mount(box, counter: counter)
        // Drops the SwiftUI graph and the pane's live subscription rather than leaving it to ARC.
        // Not `close()`: see `docs/flaky-tests.md`, "The wait that hangs instead of failing".
        defer { window.contentView = nil }
        pump(window, seconds: 0.3)

        // Proof the pane really laid out: the root column's rows, and nothing else yet.
        #expect(PaneLayoutSettle.tableRowCounts(window.contentView!) == [40])
        // The lowest row inside the viewport, which a bottom-docked bar would cover, from live geometry.
        let target = try #require(
            placement.rowBottoms
                .filter { $0.value - placement.viewportGlobalMinY <= placement.viewportHeight }
                .max(by: { $0.value < $1.value })
        )
        let inViewport = target.value - placement.viewportGlobalMinY
        #expect(inViewport > placement.viewportHeight - placement.coverage,
                "target row is not inside the bar's coverage band — the flip path would not be exercised")

        let settledBodies = counter.bodies
        // The tap: open that folder's column and select it. The host's bar selection stays empty
        // for this turn, as `activePane`'s tiebreak leaves it after a click.
        var path = box.browsePath
        path.drill(into: (target.key as NSString).lastPathComponent, atDepth: 0)
        box.browsePath = path
        box.selection = [target.key]
        pump(window, seconds: 1.0)

        // The drilled column is open: the click did what a click does.
        #expect(PaneLayoutSettle.tableRowCounts(window.contentView!) == [40, 4])
        // …and no edge flip, because the bar isn't showing. Fails if the pane resolves from its own
        // raw selection while the host commits from its empty one.
        #expect(counter.flips == 0)
        #expect(placement.atTop == false)
        let cost = counter.bodies - settledBodies
        #expect(cost < 50, "drill re-rendered the pane \(cost)× — layout is not settling")
    }

    /// The anchor has one source. A pane re-resolving after a scroll reasons from the selection the
    /// host committed, so it can never hand back a different edge than the host's next render will.
    @Test func testReresolveCannotDisagreeWithTheHostsCommit() {
        let placement = PaneBarPlacement()
        placement.viewportHeight = 600
        placement.viewportGlobalMinY = 0
        placement.coverage = 64
        placement.rowBottoms = ["low": 580, "high": 40]

        // Host: a bar acting on nothing (the inactive pane, or the turn after a click).
        #expect(placement.resolveAtTop(selection: []) == false)
        // Pane, after geometry moved: same answer, because it reasons from the same selection.
        #expect(placement.reresolveAtTop() == false)

        // Host: a bar acting on the low row.
        #expect(placement.resolveAtTop(selection: ["low"]) == true)
        #expect(placement.reresolveAtTop() == true)
    }
}
