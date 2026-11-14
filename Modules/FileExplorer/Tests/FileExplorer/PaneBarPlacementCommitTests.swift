import Testing
import AppKit
import SwiftUI
import Sync
@testable import FileExplorer

/// Who commits the action bar's edge, and why a selection change never calls `onBarEdgeFlip`.
///
/// `PaneBarPlacement.flipIfEdgeMoved` calls back only when `reresolveMovedEdge()` finds the
/// committed `atTop` moved. The host commits synchronously from its own `body` (`ContentView`
/// computes `placement.resolveAtTop(…)` on every render), so by the time a geometry callback runs
/// the answer already agrees: a selection change can never produce a flip. Only geometry moving
/// under an unchanged selection can, which in the app is a scroll, and a scroll doesn't re-render
/// the host, because `PaneBarPlacement` is a plain class whose per-frame writes invalidate nothing.
/// That asymmetry is deliberate: it stops the bar showing at one edge and hopping to the other.
///
/// A fixture that passes `onBarEdgeFlip` (as `ColumnsDisplayCycleTests.TwoPaneHarness` does) isn't
/// covering it. In the Tree no headless lever can arm the callback: moving geometry either
/// re-renders the root, so the host commits first, or moves AppKit's clip view without re-driving
/// SwiftUI's geometry preferences. Columns reads its rows' bottoms from each column's table
/// (`ColumnListProbe`), which observes the clip, so a scroll there can be armed; the last two
/// tests pin that.
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

    /// The bar's edge changes on a selection change, without a flip callback, because the host
    /// committed it synchronously from `body`. Both halves are asserted: without the first this
    /// would pass over a dormant path, and without the second it wouldn't say what it is for.
    @Test func aSelectionChangeMovesTheEdgeWithoutAskingForAFlip() throws {
        let box = Box(tree: PaneBarHostHarness.tree(folders: 40))
        let counter = Counter()
        let (window, placement) = mount(box, counter: counter)
        // Drops the SwiftUI graph and the pane's live subscription rather than leaving it to ARC.
        // Not `close()`: see `docs/flaky-tests.md`, "The wait that hangs instead of failing".
        defer { window.contentView = nil }
        pump(window, seconds: 0.3)

        #expect(placement.atTop == false, "nothing is selected yet, so the bar rests at the bottom")

        // The lowest row inside the viewport, the one a bottom-docked bar would cover. Taken from
        // live geometry, not by index, so a density or font change can't move it off the band.
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

        // …and this is why no callback follows: a fresh resolve agrees with what the host already
        // committed, so `PaneBarPlacement.flipIfEdgeMoved` returns (`reresolveMovedEdge()` is
        // false).
        //
        // This is the load-bearing assertion, not the flip count below: the callback is dispatched
        // with `DispatchQueue.main.async` and lands after this synchronous pump, so `flips == 0`
        // holds even if the agreement check is removed. The count only corroborates.
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

    /// Columns' row bottoms are in the viewport's own space: the first row ends about a row below
    /// the viewport's top. A probe converting into another space (the window's bottom-up one, the
    /// clip's) would be hundreds of points off and the bar would flip early or never; every other
    /// assertion about bottoms is relative and wouldn't notice.
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

    /// Scrolling a column flips the bar once. The lowest visible row is selected, so the bar goes
    /// to the top; the column then scrolls until that row rises clear of the band, and the bar is
    /// asked back down exactly once.
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
