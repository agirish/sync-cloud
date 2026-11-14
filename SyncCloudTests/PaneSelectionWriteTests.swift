import Testing
import Foundation
import Sync
@testable import SyncCloud

/// The order of a pane click's two halves. A click commits its own pane synchronously and clears
/// the other a runloop turn later: clearing synchronously reloads that pane's `List` mid-commit
/// and drops the click. The deferred clear must not wipe a second click that lands in the other
/// pane before it drains, or that click reads as ignored. An explicit scheduler makes the
/// interleaving exact, not a race the test hopes to hit.
@MainActor
@Suite struct PaneSelectionWriteTests {
    /// Stands in for `FileSyncManager`'s selection properties.
    private final class State: PaneSelectionState {
        var selectedLeftPaths: Set<String> = []
        var selectedRightPaths: Set<String> = []
        var lastSelectionSurface: SelectionSurface? = nil
    }

    /// Collects the deferred blocks instead of running them, so a test decides when, and whether,
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

        // Click the right pane before that block drains, as when the main thread is busy rebuilding a
        // Columns stack.
        write(["/right/b"], isLeft: false, state, sequencer, queue)
        #expect(state.selectedRightPaths == ["/right/b"])

        queue.drain()

        // Without the token guard, the left click's queued clear would write `[]` over it here.
        #expect(state.selectedRightPaths == ["/right/b"],
                "the earlier left-pane click's deferred clear wiped the right-pane click")
        // The invariant still holds: the newer click's own deferral cleared the left pane.
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

    /// Three clicks bouncing across the seam: only the last may survive, and it must.
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
        // Before the drain both panes hold a selection: the deliberate one-frame window
        // `PaneLogic.activePane`'s left-wins tiebreak covers.
        #expect(state.selectedRightPaths == ["/right/stale"])

        queue.drain()
        #expect(state.selectedLeftPaths == ["/left/a"])
        #expect(state.selectedRightPaths.isEmpty, "the one-pane-selected invariant stopped being enforced")
    }

    @Test func testADeselectLeavesTheOtherPaneAloneAndQueuesNothing() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()
        state.selectedRightPaths = ["/right/b"]

        write([], isLeft: true, state, sequencer, queue)

        // An empty write is a deselect and enforces nothing, which keeps the right-click "Copy N
        // items from other pane" menu working.
        #expect(state.selectedRightPaths == ["/right/b"])
        #expect(queue.blocks.isEmpty, "a deselect queued a clear it has no business queueing")
    }

    /// A deselect must not consume a token either: doing so would cancel a live deferral without
    /// queueing a replacement, and the other pane would keep a stale selection forever.
    @Test func testADeselectDoesNotCancelALiveDeferral() {
        let state = State(), sequencer = PaneSelectionSequencer(), queue = Queue()
        state.selectedRightPaths = ["/right/stale"]

        write(["/left/a"], isLeft: true, state, sequencer, queue)
        // SwiftUI re-writing an unchanged empty set into the other pane, which it does freely.
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

/// A pane click must claim the Space → Quick Look surface token, or the Differences table keeps
/// priority and Space previews its row while the user works in a pane. Driven through
/// `applySelectionWrite`, which every pane selection write passes through.
@MainActor
@Suite struct PaneSelectionSurfaceTokenTests {
    private final class State: PaneSelectionState {
        var selectedLeftPaths: Set<String> = []
        var selectedRightPaths: Set<String> = []
        /// Counts writes: the token is `@Published` and the panes re-render off it, so a redundant write
        /// per click is a cost.
        private(set) var surfaceWrites = 0
        var lastSelectionSurface: SelectionSurface? = nil {
            didSet { surfaceWrites += 1 }
        }
    }

    private func write(_ selection: Set<String>, isLeft: Bool, _ state: State,
                       _ sequencer: PaneSelectionSequencer) {
        PaneLogic.applySelectionWrite(selection, isLeft: isLeft, state: state,
                                      sequencer: sequencer, schedule: { _ in })
    }

    @Test(arguments: [(["/left/a"], true), (["/right/b"], false)] as [(Set<String>, Bool)])
    func aPaneSelectionClaimsTheSurfaceToken(paths: Set<String>, isLeft: Bool) {
        let state = State()
        state.lastSelectionSurface = .differences
        write(paths, isLeft: isLeft, state, PaneSelectionSequencer())
        #expect(state.lastSelectionSurface == .pane)
    }

    /// A clear means "not this any more", not "the panes now": handing the token to an empty surface
    /// would make Space dead.
    @Test func anEmptyWriteDoesNotClaimTheToken() {
        let state = State()
        state.lastSelectionSurface = .differences
        write([], isLeft: true, state, PaneSelectionSequencer())
        #expect(state.lastSelectionSurface == .differences)
    }
}

extension PaneSelectionSurfaceTokenTests {
    /// The guard that keeps a run of pane clicks from republishing the token on every one.
    @Test func repeatedPaneClicksWriteTheTokenOnlyOnce() {
        let state = State(), sequencer = PaneSelectionSequencer()
        write(["/left/a"], isLeft: true, state, sequencer)
        let afterFirst = state.surfaceWrites
        write(["/left/b"], isLeft: true, state, sequencer)
        write(["/left/c"], isLeft: true, state, sequencer)
        #expect(state.surfaceWrites == afterFirst, "the token was republished on an unchanged value")
    }
}
