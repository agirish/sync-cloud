import Testing
import Sync
@testable import SyncCloud

/// The host's half of the pane search: which pane ⌘F opens, and when the debounced recomputation
/// re-runs.
@MainActor
@Suite struct PaneSearchHostTests {

    // MARK: - Which pane ⌘F opens

    /// The pane holding the selection is the pane every other pane-scoped affordance points at —
    /// where the action bar draws, whose wash is strong — so it is where Find has to land too.
    @Test func testFindFollowsTheSelectedPane() {
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: false, activePane: .left))
        #expect(!PaneLogic.searchTargetIsLeft(isSingleSource: false, activePane: .right))
    }

    /// `activePane` is nil whenever nothing is selected, which is most of the time. That is not an
    /// answer, so Find needs a floor rather than a shrug — without one ⌘F would do nothing at all
    /// on a freshly opened window.
    @Test func testFindFallsBackToTheLeftPaneWithNoSelection() {
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: false, activePane: nil))
    }

    /// The rail IS the left pane on another surface, and it is the only pane on screen — a right
    /// answer here would open a field nobody can see, including when the RIGHT pane (hidden behind
    /// the rail) happens to be the one holding a selection.
    @Test func testTheSingleSourceRailAlwaysSearchesItself() {
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: true, activePane: .right))
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: true, activePane: nil))
    }

    // MARK: - When the search re-runs

    /// `.task(id:)` restarts exactly when this compares unequal, so this `==` is the definition of
    /// "when does the search re-run".
    @Test func testTypingRestartsTheSearch() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "ta", treeVersion: 1)
                != PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1))
    }

    /// **The field that is easy to leave out.** A result set names paths in the tree that was
    /// published when it ran; a scan, a delete or a hidden-files toggle rebuilds that tree, and the
    /// stale hits then point at rows that no longer exist — the walk reveals nothing and selects a
    /// ghost.
    @Test func testARepublishRestartsTheSearch() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1)
                != PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 2))
    }

    /// The two panes keep independent queries and independent counters, so their keys must never
    /// collide — one pane's recomputation must not stand in for the other's.
    @Test func testTheTwoPanesRecomputeSeparately() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1)
                != PaneSearchRecomputeKey(isLeft: false, query: "tax", treeVersion: 1))
    }

    /// …and an unchanged key does NOT restart it. Without this the debounce would re-run on every
    /// one of `ContentView`'s renders, which any of the manager's ~56 published properties triggers.
    @Test func testAnUnchangedKeyDoesNotRestartTheSearch() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 7)
                == PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 7))
    }

    // MARK: - The field's own state

    /// A fresh pane is not searching, and draws nothing.
    @Test func testAFreshFieldIsIdle() {
        let state = PaneSearchFieldState()
        #expect(state.query.isEmpty)
        #expect(!state.isExpanded)
        #expect(state.hitIndex == PaneSearchWalk.restart)
    }
}
