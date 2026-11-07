import Testing
import Foundation
import Sync
@testable import SyncCloud

/// The host's half of the pane search: which pane ⌘F opens, and when the debounced recomputation
/// re-runs.
@MainActor
@Suite struct PaneSearchHostTests {

    // MARK: - Which pane ⌘F opens

    /// `(single source, explicit focus, the selected pane, ⌘F searches the left pane)`.
    @Test(arguments: [
        // The pane holding the selection is where every pane-scoped affordance points (the action
        // bar, the strong wash), so Find lands there too.
        (false, nil, .left, true),
        (false, nil, .right, false),
        // `activePane` is nil whenever nothing is selected, which is most of the time, so Find
        // needs a floor; without one ⌘F would do nothing on a fresh window.
        (false, nil, nil, true),
        // The rail is the left pane and the only one on screen: a right answer would open a field
        // nobody can see, even when the hidden right pane holds a selection.
        (true, nil, .right, true),
        (true, nil, nil, true),
        // Explicit focus (⌃⇥) outranks the selection fallback; the inputs disagree, since agreeing
        // inputs can't tell which one the rule read.
        (false, .left, .right, true),
        (false, .right, .left, false),
        // Nothing selected anywhere: the fallback floors at the left pane, so explicit focus is
        // the only way to reach the right one.
        (false, .right, nil, false),
        // A `focusedSide` left over from Compare must not survive into the rail, the only pane on
        // screen: the rail's guard comes before the focus is consulted.
        (true, .right, nil, true),
    ] as [(Bool, PaneTree.Side?, PaneLogic.ActivePane?, Bool)])
    func testFindSearchesThePaneInEffect(isSingleSource: Bool, focusedSide: PaneTree.Side?,
                                         activePane: PaneLogic.ActivePane?, searchesLeft: Bool) {
        #expect(PaneLogic.focusedPaneIsLeft(isSingleSource: isSingleSource, focusedSide: focusedSide,
                                            activePane: activePane) == searchesLeft)
    }

    /// ⌃⇥ flips the pane in effect, not the stored value. With focus implicit (nil) the first press
    /// moves off the fallback's pane; a stored `nil` has no opposite and the press would look dead
    /// half the time. The last two fixtures put `focusedSide` and `activePane` in disagreement, so
    /// a build that ignored `focusedSide` can't pass.
    @Test func testTheFocusSwitchFlipsTheEffectivePaneNotTheStoredOne() {
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: nil, activePane: nil) == .right)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: nil, activePane: .right) == .left)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: .right, activePane: .left) == .left)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: .left, activePane: .right) == .right)
    }

    /// Pressing it twice returns to the start, making it a toggle, not a walk, including from the
    /// implicit start state, where the first press materialises a stored side.
    @Test func testTwoFocusSwitchesReturnToTheStartingPane() {
        let first = PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: nil, activePane: .left)
        let second = PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: first, activePane: .left)
        #expect(first == .right)
        #expect(second == .left)
    }

    /// Clicking in a pane moves focus to the clicked side, even away from a side ⌃⇥ chose, so the
    /// two never become rival answers.
    @Test func testSelectingInAPaneTakesFocus() {
        #expect(PaneLogic.focusedSideAfterSelectionWrite(["/a"], isLeft: false, current: .left) == .right)
        #expect(PaneLogic.focusedSideAfterSelectionWrite(["/a"], isLeft: true, current: .right) == .left)
        #expect(PaneLogic.focusedSideAfterSelectionWrite(["/a"], isLeft: true, current: nil) == .left)
    }

    /// An empty write is a deselect (Escape, the action bar's ✕, the cross-pane clear), not leaving
    /// the pane; moving focus would drop the next ⌘F on the left pane after Escape. Each `current`
    /// differs from what the clicked side would give, so ignoring the empty check can't pass.
    @Test func testDeselectingLeavesFocusWhereItWas() {
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: true, current: .right) == .right)
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: false, current: .left) == .left)
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: false, current: nil) == nil)
    }

    // MARK: - What a search run is for

    /// A left/right mix-up would stamp the answer with the wrong side. `PaneSearchResults.==` reads
    /// the side first, so the pane would re-render forever or never notice a change, and neither
    /// symptom points back here.
    @Test func testEachPaneStampsItsOwnSide() {
        #expect(PaneLogic.searchPlan(isLeft: true, isSingleSource: false, query: "tax").side == .left)
        #expect(PaneLogic.searchPlan(isLeft: false, isSingleSource: false, query: "tax").side == .right)
    }

    /// Walking the other pane's tree is the expensive part of a search, so it must not happen when
    /// there is nothing to annotate.
    @Test func testAnEmptyQueryNeverWalksTheOtherTree() {
        #expect(!PaneLogic.searchPlan(isLeft: true, isSingleSource: false, query: "").annotatesSides)
        #expect(PaneLogic.searchPlan(isLeft: true, isSingleSource: false, query: "tax").annotatesSides)
    }

    /// The rail has no opposite pane, so "left only" would describe a comparison it isn't making,
    /// from the hidden right pane's tree.
    @Test func testTheRailNeverAnnotatesSides() {
        #expect(!PaneLogic.searchPlan(isLeft: true, isSingleSource: true, query: "tax").annotatesSides)
    }

    // MARK: - When a recomputation is allowed to reveal

    private func results(_ query: String, generation: Int) -> PaneSearchResults {
        PaneSearchResults(side: .left, generation: generation, query: query,
                          tree: PaneTree(side: .left, version: 1, nodes: []), otherPaths: nil)
    }

    /// A recomputation with the same query is a republish (a scan or copy moved a tree, not the
    /// user) and must not bump the reveal nonce, or every background republish would steal the
    /// selection (`PaneSearchRevealNonceTests`).
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

    /// `PaneSearchResults` stores the normalized query, so a whitespace-only edit reaches this rule
    /// as the same string; asserted so that ordering is named, not an accident.
    @Test func testAWhitespaceOnlyEditIsNotANewQuestion() {
        #expect(!PaneLogic.searchAsksNewQuestion(previous: results("tax", generation: 1),
                                                 results: results("  tax ", generation: 2)))
    }

    // MARK: - When a recomputation publishes nothing

    /// A republish with nothing typed publishes nothing. Every tree publish re-keys the search
    /// task, and results compare by generation, so a new generation for an empty query would
    /// re-render the window and both panes with identical output.
    @Test func testAnEmptyQueryRepublishStaysIdle() {
        #expect(PaneLogic.searchStaysIdle(previous: .empty(side: .left), query: ""))
        #expect(PaneLogic.searchStaysIdle(previous: results("", generation: 4), query: ""))
        // Whitespace is no query either — `PaneSearchResults` stores it normalized to empty.
        #expect(PaneLogic.searchStaysIdle(previous: results("", generation: 4), query: "  "))
        // The idle results would equal what is held but for the stamp, which is the re-render
        // this rule saves.
        #expect(results("", generation: 4) != results("", generation: 5))
    }

    /// And it never swallows a real change: a typed query must run, and so must clearing one, or
    /// the old hits stay drawn with nothing in the field.
    @Test func testAQueryOrItsClearingStillRuns() {
        #expect(!PaneLogic.searchStaysIdle(previous: .empty(side: .left), query: "tax"))
        #expect(!PaneLogic.searchStaysIdle(previous: results("tax", generation: 2), query: ""))
        #expect(!PaneLogic.searchStaysIdle(previous: results("tax", generation: 2), query: "tax"))
    }

    /// The rule only saves the publish if it runs before the generation is bumped and the results
    /// written. `recomputeSearch` is on `ContentView`, which a test can't mount, so its order is
    /// read from source.
    @Test func testTheIdleCheckRunsBeforeAnythingIsPublished() throws {
        let source = try macAppFile("ContentView+PaneSearch.swift")
        let start = try #require(source.range(of: "func recomputeSearch(isLeft: Bool) async {"),
                                 "`recomputeSearch` is gone or renamed — re-aim this check")
        let body = source[start.upperBound...]
        let idle = try #require(body.range(of: "guard !PaneLogic.searchStaysIdle("),
                                "`recomputeSearch` no longer returns early for an idle search")
        // The guard must return, not fall through to the bump below it.
        let guardEnd = try #require(body[idle.upperBound...].range(of: "else {"))
        #expect(body[guardEnd.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("return }"),
                "the idle guard no longer returns")
        let bump = try #require(body.range(of: "SearchGeneration) + 1"),
                                "the generation bump moved — re-aim this check")
        let write = try #require(body.range(of: "leftSearchResults = results"),
                                 "the results write moved — re-aim this check")
        #expect(idle.lowerBound < bump.lowerBound && idle.lowerBound < write.lowerBound,
                "the idle check runs after the generation is bumped, so an empty republish still publishes")
    }

    /// The side annotation reads the other pane's tree before its type filter: a file that filter
    /// hides is still on that side. Read from source for the same reason as above.
    @Test func testTheSideAnnotationReadsTheOtherPanesWholeFolder() throws {
        let source = try macAppFile("ContentView+PaneSearch.swift")
        let start = try #require(source.range(of: "func recomputeSearch(isLeft: Bool) async {"),
                                 "`recomputeSearch` is gone or renamed — re-aim this check")
        let body = source[start.upperBound...]
        #expect(body.contains("syncManager.searchSideAnnotationNodes(forPaneIsLeft: isLeft)"))
        #expect(!body.contains("relativePaths(in: otherTree)") && !body.contains("relativePaths(in: pane.otherTree)"),
                "the annotation reads the other pane's filtered tree again")
    }

    // MARK: - When the search re-runs

    /// `.task(id:)` restarts exactly when this compares unequal, so this `==` is the definition of
    /// "when does the search re-run". Each row changes one field from the first key: typing; a
    /// republish (the field easy to leave out: results name paths in the tree published when they
    /// ran, and a scan, delete or hidden-files toggle rebuilds it, so stale hits select a ghost);
    /// the other pane's republish, since the side annotation is read from it; and the other pane,
    /// whose query and counters are its own, so one pane's recomputation can't stand in for it.
    @Test(arguments: [
        PaneSearchRecomputeKey(isLeft: true, query: "ta", treeVersion: 1, otherTreeVersion: 1),
        PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 2, otherTreeVersion: 1),
        PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1, otherTreeVersion: 2),
        PaneSearchRecomputeKey(isLeft: false, query: "tax", treeVersion: 1, otherTreeVersion: 1),
    ])
    func testAChangedKeyRestartsTheSearch(changed: PaneSearchRecomputeKey) {
        #expect(PaneSearchRecomputeKey(isLeft: true, query: "tax", treeVersion: 1, otherTreeVersion: 1) != changed)
    }

    /// An unchanged key doesn't restart it, or the debounce would re-run on every `ContentView`
    /// render, which any of the manager's many published properties triggers.
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
