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

    // MARK: - What a search run is for

    /// A left/right mix-up here searches the right tree and stamps the answer with the wrong side.
    /// `PaneSearchResults.==` reads the side first, so the pane would then either never compare its
    /// own results equal (re-rendering forever) or never notice a change at all — and neither
    /// symptom points back here.
    @Test func testEachPaneStampsItsOwnSide() {
        #expect(PaneLogic.searchPlan(isLeft: true, isSingleSource: false, query: "tax").side == .left)
        #expect(PaneLogic.searchPlan(isLeft: false, isSingleSource: false, query: "tax").side == .right)
    }

    /// Walking the OTHER pane's tree is the only part of a search that touches something the user is
    /// not looking at, and it is the expensive part. It must not happen when there is nothing to
    /// annotate.
    @Test func testAnEmptyQueryNeverWalksTheOtherTree() {
        #expect(!PaneLogic.searchPlan(isLeft: true, isSingleSource: false, query: "").annotatesSides)
        #expect(PaneLogic.searchPlan(isLeft: true, isSingleSource: false, query: "tax").annotatesSides)
    }

    /// The rail has no opposite pane, so "left only" would describe a comparison it is not making —
    /// and the tree it would walk is the hidden right pane's, which is not on screen at all.
    @Test func testTheRailNeverAnnotatesSides() {
        #expect(!PaneLogic.searchPlan(isLeft: true, isSingleSource: true, query: "tax").annotatesSides)
    }

    // MARK: - When the search re-runs

    /// `.task(id:)` restarts exactly when this compares unequal, so this `==` is the definition of
    /// "when does the search re-run".
    @Test func testTypingRestartsTheSearch() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "ta", treeVersion: 1, otherTreeVersion: 1)
                != PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1, otherTreeVersion: 1))
    }

    /// **The field that is easy to leave out.** A result set names paths in the tree that was
    /// published when it ran; a scan, a delete or a hidden-files toggle rebuilds that tree, and the
    /// stale hits then point at rows that no longer exist — the walk reveals nothing and selects a
    /// ghost.
    @Test func testARepublishRestartsTheSearch() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1, otherTreeVersion: 1)
                != PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 2, otherTreeVersion: 1))
    }

    /// The OTHER pane's republish matters too, and only for a reason that is invisible from this
    /// pane's own tree: the side annotation is read out of it. A copy across, or a rescan over
    /// there, leaves every "left only" on screen describing a tree that no longer exists — which is
    /// the one answer the user searched to get, reported wrong.
    @Test func testTheOtherPanesRepublishRestartsTheSearch() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1, otherTreeVersion: 1)
                != PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1, otherTreeVersion: 2))
    }

    /// The two panes keep independent queries and independent counters, so their keys must never
    /// collide — one pane's recomputation must not stand in for the other's.
    @Test func testTheTwoPanesRecomputeSeparately() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1, otherTreeVersion: 1)
                != PaneSearchRecomputeKey(isLeft: false, query: "tax", treeVersion: 1, otherTreeVersion: 1))
    }

    /// …and an unchanged key does NOT restart it. Without this the debounce would re-run on every
    /// one of `ContentView`'s renders, which any of the manager's ~56 published properties triggers.
    @Test func testAnUnchangedKeyDoesNotRestartTheSearch() {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 7, otherTreeVersion: 2)
                == PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 7, otherTreeVersion: 2))
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
