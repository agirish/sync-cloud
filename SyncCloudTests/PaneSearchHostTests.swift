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
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: false, focusedSide: nil, activePane: .left))
        #expect(!PaneLogic.searchTargetIsLeft(isSingleSource: false, focusedSide: nil, activePane: .right))
    }

    /// `activePane` is nil whenever nothing is selected, which is most of the time. That is not an
    /// answer, so Find needs a floor rather than a shrug — without one ⌘F would do nothing at all
    /// on a freshly opened window.
    @Test func testFindFallsBackToTheLeftPaneWithNoSelection() {
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: false, focusedSide: nil, activePane: nil))
    }

    /// The rail IS the left pane on another surface, and it is the only pane on screen — a right
    /// answer here would open a field nobody can see, including when the RIGHT pane (hidden behind
    /// the rail) happens to be the one holding a selection.
    @Test func testTheSingleSourceRailAlwaysSearchesItself() {
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: true, focusedSide: nil, activePane: .right))
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: true, focusedSide: nil, activePane: nil))
    }

    // MARK: - Explicit focus (⌃⇥)

    /// The whole point of the explicit side: it OUTRANKS the selection fallback. Both fixtures put
    /// the two inputs in DISAGREEMENT, because a fixture where they agree cannot tell which one the
    /// rule read — and "focused wins" is the only claim being made here.
    @Test func testExplicitFocusOutranksTheSelectedPane() {
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: false, focusedSide: .left, activePane: .right))
        #expect(!PaneLogic.searchTargetIsLeft(isSingleSource: false, focusedSide: .right, activePane: .left))
    }

    /// The case that motivated the whole change: nothing selected anywhere, so the fallback floors
    /// at the left pane and there was previously no way to reach the right one at all.
    @Test func testExplicitFocusAnswersWhenNothingIsSelected() {
        #expect(!PaneLogic.searchTargetIsLeft(isSingleSource: false, focusedSide: .right, activePane: nil))
    }

    /// A `focusedSide` left over from Compare must not survive into the rail, which is the only
    /// pane on screen — the rail's guard has to come FIRST, before the focus is consulted.
    @Test func testTheRailIgnoresAStaleRightFocus() {
        #expect(PaneLogic.searchTargetIsLeft(isSingleSource: true, focusedSide: .right, activePane: nil))
    }

    /// ⌃⇥ flips the pane that is IN EFFECT, not the stored value. With focus still implicit (nil)
    /// the effective target is the fallback's, so the first press has to move off *that* — a flip
    /// of the stored `nil` has no defined opposite and would leave the press looking dead half
    /// the time.
    /// The last two fixtures put `focusedSide` and `activePane` in DISAGREEMENT deliberately. With
    /// them agreeing — which is how this was first written — a build that ignored `focusedSide`
    /// entirely still produced both expected answers, and the test passed with the whole feature
    /// deleted.
    @Test func testTheFocusSwitchFlipsTheEffectivePaneNotTheStoredOne() {
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: nil, activePane: nil) == .right)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: nil, activePane: .right) == .left)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: .right, activePane: .left) == .left)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: .left, activePane: .right) == .right)
    }

    /// Pressing it twice returns to where it started, which is what makes it a toggle rather than a
    /// walk — and it must hold from the implicit start state too, where the first press is the one
    /// that materialises a stored side.
    @Test func testTwoFocusSwitchesReturnToTheStartingPane() {
        let first = PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: nil, activePane: .left)
        let second = PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: first, activePane: .left)
        #expect(first == .right)
        #expect(second == .left)
    }

    /// Clicking in a pane is the mouse's half of the same fact, so it moves focus to the clicked
    /// side — including *away* from a side ⌃⇥ had chosen, which is what keeps the two from becoming
    /// rival answers.
    @Test func testSelectingInAPaneTakesFocus() {
        #expect(PaneLogic.focusedSideAfterSelectionWrite(["/a"], isLeft: false, current: .left) == .right)
        #expect(PaneLogic.focusedSideAfterSelectionWrite(["/a"], isLeft: true, current: .right) == .left)
        #expect(PaneLogic.focusedSideAfterSelectionWrite(["/a"], isLeft: true, current: nil) == .left)
    }

    /// The case the rule exists for: an EMPTY write is a deselect (Escape, the action bar's ✕, the
    /// cross-pane clear), and letting go of a selection is not leaving the pane. Moving focus here
    /// would drop the next ⌘F back on the left-hand floor the moment the user pressed Escape.
    /// Fixtures carry a `current` that DIFFERS from what the clicked side would produce, so a rule
    /// that ignored the empty check could not pass by coincidence.
    @Test func testDeselectingLeavesFocusWhereItWas() {
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: true, current: .right) == .right)
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: false, current: .left) == .left)
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: false, current: nil) == nil)
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

    // MARK: - When a recomputation is allowed to reveal

    private func results(_ query: String, generation: Int) -> PaneSearchResults {
        PaneSearchResults(side: .left, generation: generation, query: query,
                          tree: PaneTree(side: .left, version: 1, nodes: []), otherPaths: nil)
    }

    /// The republish clobber's host-side gate. A recomputation with the SAME query is a republish
    /// — a scan or a copy moved a tree, not the user — and it must not bump the reveal nonce: the
    /// pane-side consequence of getting this wrong is `PaneSearchRevealNonceTests`' stolen
    /// selection, re-fired on every background republish for as long as a query sat in the field.
    @Test func testARepublishIsNotANewQuestion() {
        #expect(!PaneLogic.searchAsksNewQuestion(previous: results("tax", generation: 1),
                                                 results: results("tax", generation: 2)))
    }

    @Test func testATypedQueryIsANewQuestion() {
        #expect(PaneLogic.searchAsksNewQuestion(previous: results("tax", generation: 1),
                                                results: results("taxi", generation: 2)))
        // Including the first activation and the field being cleared, in both directions.
        #expect(PaneLogic.searchAsksNewQuestion(previous: results("", generation: 0),
                                                results: results("tax", generation: 1)))
        #expect(PaneLogic.searchAsksNewQuestion(previous: results("tax", generation: 1),
                                                results: results("", generation: 2)))
    }

    /// `PaneSearchResults` stores the NORMALIZED query, so a whitespace-only edit reaches this
    /// rule as the same string — asserted here so the normalization staying upstream of the rule
    /// is a fact a test names rather than an accident of call order.
    @Test func testAWhitespaceOnlyEditIsNotANewQuestion() {
        #expect(!PaneLogic.searchAsksNewQuestion(previous: results("tax", generation: 1),
                                                 results: results("  tax ", generation: 2)))
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
