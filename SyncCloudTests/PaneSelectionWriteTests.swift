import Testing
import Foundation
@testable import SyncCloud

/// The ORDER of a pane click's two halves.
///
/// A click commits its own pane synchronously and clears the other pane a runloop turn later —
/// clearing it synchronously reloads that pane's `List` mid-commit and drops the click (`aa9d407`).
/// The deferred clear writes a blind `[]` and carries no memory of which pane the user is on when
/// it finally runs, so a second click landing in the other pane before it drains gets wiped: the
/// row un-highlights, the action bar never appears, and the click reads as ignored.
///
/// These drive `applySelectionWrite` with an explicit scheduler, so the interleaving is exact
/// rather than a race the test hopes to hit.
@MainActor
@Suite struct PaneSelectionWriteTests {

    /// Stands in for `FileSyncManager`'s two selection properties.
    private final class State: PaneSelectionState {
        var selectedLeftPaths: Set<String> = []
        var selectedRightPaths: Set<String> = []
    }

    /// Collects the deferred blocks instead of running them, so a test decides when — and whether —
    /// each drains.
    private final class Queue {
        private(set) var blocks: [() -> Void] = []
        func schedule(_ block: @escaping () -> Void) { blocks.append(block) }
        /// Runs every queued block in the order it was queued, as the main queue would.
        func drain() {
            let pending = blocks
            blocks = []
            for block in pending { block() }
        }
    }

    private func write(_ selection: Set<String>, isLeft: Bool,
                       _ state: State, _ sequencer: PaneSelectionSequencer, _ queue: Queue) {
        PaneLogic.applySelectionWrite(selection, isLeft: isLeft, state: state,
                                      sequencer: sequencer, schedule: queue.schedule)
    }

    // MARK: The click that gets eaten

    @Test func testAClickInTheOtherPaneIsNotWipedByTheFirstClicksDeferredClear() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()

        // Click the left pane. It commits at once; the right pane's clear is queued.
        write(["/left/a"], isLeft: true, state, sequencer, queue)
        #expect(state.selectedLeftPaths == ["/left/a"])
        #expect(queue.blocks.count == 1)

        // Click the right pane BEFORE that block drains — the main thread being busy rebuilding a
        // Columns stack (and mirroring it onto the linked pane) is exactly what keeps it queued.
        write(["/right/b"], isLeft: false, state, sequencer, queue)
        #expect(state.selectedRightPaths == ["/right/b"])

        queue.drain()

        // The right click must survive. Before the token guard, the left click's queued clear wrote
        // `[]` over it here and the click vanished.
        #expect(state.selectedRightPaths == ["/right/b"],
                "the earlier left-pane click's deferred clear wiped the right-pane click")
        // …and the invariant still holds: the newer click's own deferral cleared the left pane.
        #expect(state.selectedLeftPaths.isEmpty)
    }

    /// The same collision the other way round, so the guard can't be one-sided.
    @Test func testAClickInTheLeftPaneIsNotWipedByTheRightsDeferredClear() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()

        write(["/right/b"], isLeft: false, state, sequencer, queue)
        write(["/left/a"], isLeft: true, state, sequencer, queue)
        queue.drain()

        #expect(state.selectedLeftPaths == ["/left/a"],
                "the earlier right-pane click's deferred clear wiped the left-pane click")
        #expect(state.selectedRightPaths.isEmpty)
    }

    /// Three clicks bouncing across the seam — the "changing panes, clicking on each side" gesture.
    /// Only the last one may survive, and it must.
    @Test func testOnlyTheNewestOfAFlurryOfCrossPaneClicksSurvives() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()

        write(["/left/a"], isLeft: true, state, sequencer, queue)
        write(["/right/b"], isLeft: false, state, sequencer, queue)
        write(["/left/c"], isLeft: true, state, sequencer, queue)
        queue.drain()

        #expect(state.selectedLeftPaths == ["/left/c"])
        #expect(state.selectedRightPaths.isEmpty)
    }

    // MARK: What must not change

    @Test func testASingleClickStillClearsTheOtherPaneOnceItsBlockDrains() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()
        state.selectedRightPaths = ["/right/stale"]

        write(["/left/a"], isLeft: true, state, sequencer, queue)
        // Before the drain both panes hold a selection — the deliberate one-frame window
        // `PaneLogic.activePane`'s left-wins tiebreak covers.
        #expect(state.selectedRightPaths == ["/right/stale"])

        queue.drain()
        #expect(state.selectedLeftPaths == ["/left/a"])
        #expect(state.selectedRightPaths.isEmpty, "the one-pane-selected invariant stopped being enforced")
    }

    @Test func testTheClickedPaneCommitsBeforeAnythingIsDeferred() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()
        // Synchronous commit is the whole reason the click lands on the first try — assert it
        // holds with NOTHING drained.
        write(["/left/a"], isLeft: true, state, sequencer, queue)
        #expect(state.selectedLeftPaths == ["/left/a"])
    }

    @Test func testADeselectLeavesTheOtherPaneAloneAndQueuesNothing() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()
        state.selectedRightPaths = ["/right/b"]

        write([], isLeft: true, state, sequencer, queue)

        // An empty write is a deselect: it enforces nothing, which is what keeps the right-click
        // "Copy N items from other pane" menu working.
        #expect(state.selectedRightPaths == ["/right/b"])
        #expect(queue.blocks.isEmpty, "a deselect queued a clear it has no business queueing")
    }

    /// A deselect must not consume a token either: doing so would cancel a live deferral without
    /// queueing a replacement, and the other pane would keep a stale selection forever.
    @Test func testADeselectDoesNotCancelALiveDeferral() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()
        state.selectedRightPaths = ["/right/stale"]

        write(["/left/a"], isLeft: true, state, sequencer, queue)
        // SwiftUI re-writing an unchanged empty set into the OTHER pane, which it does freely.
        write([], isLeft: false, state, sequencer, queue)
        queue.drain()

        #expect(state.selectedLeftPaths == ["/left/a"])
        #expect(state.selectedRightPaths.isEmpty, "the deselect cancelled the live deferral")
    }

    // MARK: The sequencer itself

    @Test func testOnlyTheNewestTokenIsNewest() {
        let sequencer = PaneSelectionSequencer()
        let first = sequencer.commit()
        #expect(sequencer.isNewest(first))
        let second = sequencer.commit()
        #expect(!sequencer.isNewest(first))
        #expect(sequencer.isNewest(second))
    }
}
