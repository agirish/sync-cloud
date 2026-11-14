import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// Who commits the action bar's edge, and why a selection change never calls `onBarEdgeFlip`: the
/// host commits `placement.resolveAtTop(…)` synchronously from `body`, so a geometry callback finds
/// it already agrees. Only a scroll under an unchanged selection flips, and it doesn't re-render the
/// host. In Columns a scroll can be armed headlessly (`ColumnListProbe` observes the clip), which the
/// last two tests pin.
@MainActor
@Suite struct PaneBarPlacementCommitTests {

    private typealias Box = PaneBarHostHarness.Box
    private typealias Counter = PaneBarHostHarness.Counter

    private func mount(_ box: Box, counter: Counter) -> (NSWindow, PaneBarPlacement) {
        PaneBarHostHarness.mount(box, counter: counter)
    }

    private func pump(_ window: NSWindow, seconds: Double) {
        PaneBarHostHarness.pump(window, seconds: seconds)
    }

    /// A selection change moves the bar's edge without a flip callback, because the host committed
    /// it synchronously from `body`.
    @Test func aSelectionChangeMovesTheEdgeWithoutAskingForAFlip() throws {
        let box = Box(tree: PaneBarHostHarness.tree(folders: 40))
        let counter = Counter()
        let (window, placement) = mount(box, counter: counter)
        // Drops the SwiftUI graph and the pane's live subscription rather than leaving it to ARC.
        // Not `close()`: see `docs/flaky-tests.md`, "The wait that hangs instead of failing".
        defer { window.contentView = nil }
        pump(window, seconds: 0.3)

        #expect(placement.atTop == false, "nothing is selected yet, so the bar rests at the bottom")

        // The lowest row inside the viewport, which a bottom-docked bar would cover, from live geometry.
        let target = try #require(
            placement.rowBottoms
                .filter { $0.value - placement.viewportGlobalMinY <= placement.viewportHeight }
                .max(by: { $0.value < $1.value }),
            "no row bottoms were reported — the pane never laid out"
        )
        let inViewport = target.value - placement.viewportGlobalMinY
        #expect(inViewport > placement.viewportHeight - placement.coverage,
                "target row is not inside the bar's coverage band — the placement math is not engaged")

        box.selection = [target.key]
        box.hostSelection = [target.key]
        pump(window, seconds: 0.3)

        // The edge really did move, so this is not a test of a dormant path…
        #expect(placement.atTop, "selecting a covered row must put the bar at the top")

        // …and no callback follows, because a fresh resolve agrees with the host's commit. This is
        // the load-bearing assertion: the callback is dispatched async and lands after this
        // synchronous pump, so `flips == 0` below holds even without the agreement check.
        #expect(placement.reresolveAtTop() == placement.atTop,
                "a re-resolve must agree with the committed edge — that agreement is what makes the callback return")
        #expect(counter.flips == 0,
                "a selection change must not produce an edge-flip callback: the host commits it synchronously from body")
    }

    // MARK: - Columns: a scroll re-resolves the bar

    /// Suspends while the run loop runs, laying the window out a frame at a time. A synchronous
    /// `CFRunLoopRunInMode` inside a `@MainActor` test never drains the main queue, where the flip
    /// callback is dispatched, so the two tests below can't use `pump(_:seconds:)`.
    @discardableResult
    private func waitUntil(_ window: NSWindow, _ timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
        await LayoutPumpWait.pump(window, upTo: timeout, until: condition).held
    }

    /// Columns' row bottoms are in the viewport's own space; a probe in another space would be
    /// hundreds of points off, which every relative assertion would miss.
    @Test func columnRowBottomsAreInTheViewportsSpace() async throws {
        let box = Box(tree: PaneBarHostHarness.tree(folders: 40))
        let (window, placement) = mount(box, counter: Counter())
        defer { window.contentView = nil }
        let first = "\(PaneBarHostHarness.root)/folder0"
        await waitUntil(window) { placement.rowBottoms[first] != nil && placement.viewportHeight > 0 }
        let bottom = try #require(placement.rowBottoms[first], "the first row was never reported")
        let below = bottom - placement.viewportGlobalMinY
        #expect(below > 10 && below < 60, "the first row ends \(below)pt below the viewport's top, not about a row")
    }

    /// Scrolling a column flips the bar once: with the lowest row selected the bar is at the top,
    /// and once that row scrolls clear of the band it is asked back down exactly once.
    @Test func scrollingAColumnFlipsTheBarOnce() async throws {
        let box = Box(tree: PaneBarHostHarness.tree(folders: 40))
        let counter = Counter()
        let (window, placement) = mount(box, counter: counter)
        defer { window.contentView = nil }
        await waitUntil(window) { !placement.rowBottoms.isEmpty && placement.viewportHeight > 0 }
        let target = try #require(
            placement.rowBottoms
                .filter { $0.value - placement.viewportGlobalMinY <= placement.viewportHeight }
                .max(by: { $0.value < $1.value }),
            "no row bottoms were reported — the pane never laid out")
        box.selection = [target.key]
        box.hostSelection = [target.key]
        await waitUntil(window) { placement.atTop }
        try #require(placement.atTop, "selecting the lowest visible row did not raise the bar")
        #expect(counter.flips == 0, "a selection change asked for a flip")

        let list = try #require(PaneRowRevealTests.scrollViews(window.contentView!).first { $0.documentView is NSTableView },
                                "no column list")
        let clip = list.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + 160))
        list.reflectScrolledClipView(clip)
        await waitUntil(window) { counter.flips > 0 }
        #expect(counter.flips == 1, "scrolling the selected row clear of the band flipped the bar \(counter.flips) times")
        #expect(!placement.atTop, "the bar stayed at the top after its row rose clear")
    }
}
