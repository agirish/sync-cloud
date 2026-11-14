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
        // Find lands where the selection is, as every pane-scoped affordance does.
        (false, nil, .left, true),
        (false, nil, .right, false),
        // `activePane` is nil whenever nothing is selected, so Find needs a floor or ⌘F would do
        // nothing on a fresh window.
        (false, nil, nil, true),
        // The rail is the only pane on screen: a right answer would open a field nobody can see.
        (true, nil, .right, true),
        (true, nil, nil, true),
        // Explicit focus (⌃⇥) outranks the selection fallback; the inputs disagree so the test can
        // tell which one the rule read.
        (false, .left, .right, true),
        (false, .right, .left, false),
        // Nothing selected anywhere: the fallback floors at the left pane, so explicit focus is
        // the only way to reach the right one.
        (false, .right, nil, false),
        // A `focusedSide` left over from Compare must not survive into the rail: the rail's guard
        // comes before focus.
        (true, .right, nil, true),
    ] as [(Bool, PaneTree.Side?, PaneLogic.ActivePane?, Bool)])
    func testFindSearchesThePaneInEffect(isSingleSource: Bool, focusedSide: PaneTree.Side?,
                                         activePane: PaneLogic.ActivePane?, searchesLeft: Bool) {
        #expect(PaneLogic.focusedPaneIsLeft(isSingleSource: isSingleSource, focusedSide: focusedSide,
                                            activePane: activePane) == searchesLeft)
    }

    /// ⌃⇥ flips the pane in effect, not the stored value: a stored `nil` has no opposite, and the
    /// press would look dead half the time. The last two fixtures put `focusedSide` and `activePane`
    /// in disagreement, so ignoring `focusedSide` can't pass.
    @Test func testTheFocusSwitchFlipsTheEffectivePaneNotTheStoredOne() {
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: nil, activePane: nil) == .right)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: nil, activePane: .right) == .left)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: .right, activePane: .left) == .left)
        #expect(PaneLogic.focusSwitchTarget(isSingleSource: false, focusedSide: .left, activePane: .right) == .right)
    }

    /// Pressing it twice returns to the start, including from the implicit start state, where the
    /// first press materialises a stored side.
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
    /// the pane; moving focus would drop the next ⌘F on the left pane. Each `current` differs from
    /// the clicked side, so ignoring the empty check can't pass.
    @Test func testDeselectingLeavesFocusWhereItWas() {
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: true, current: .right) == .right)
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: false, current: .left) == .left)
        #expect(PaneLogic.focusedSideAfterSelectionWrite([], isLeft: false, current: nil) == nil)
    }

    // MARK: - What a search run is for

    /// Each pane stamps its own side. `PaneSearchResults.==` reads the side first, so a mix-up would
    /// re-render the pane forever or never notice a change, neither pointing back here.
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

    /// A same-query recomputation is a republish (a scan or copy moved a tree, not the user) and must
    /// not bump the reveal nonce, or every background republish would steal the selection
    /// (`PaneSearchRevealNonceTests`).
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
    /// as the same string.
    @Test func testAWhitespaceOnlyEditIsNotANewQuestion() {
        #expect(!PaneLogic.searchAsksNewQuestion(previous: results("tax", generation: 1),
                                                 results: results("  tax ", generation: 2)))
    }

    // MARK: - When a recomputation publishes nothing

    /// A republish with nothing typed publishes nothing: results compare by generation, so a new
    /// generation for an empty query would re-render the window and both panes for nothing.
    @Test func testAnEmptyQueryRepublishStaysIdle() {
        #expect(PaneLogic.searchStaysIdle(previous: .empty(side: .left), query: ""))
        #expect(PaneLogic.searchStaysIdle(previous: results("", generation: 4), query: ""))
        // Whitespace is no query either — `PaneSearchResults` stores it normalized to empty.
        #expect(PaneLogic.searchStaysIdle(previous: results("", generation: 4), query: "  "))
        // Idle results differ from what is held only by the stamp: that re-render is what this saves.
        #expect(results("", generation: 4) != results("", generation: 5))
    }

    /// It never swallows a real change: a typed query runs, and so does clearing one, or the old
    /// hits stay drawn with nothing in the field.
    @Test func testAQueryOrItsClearingStillRuns() {
        #expect(!PaneLogic.searchStaysIdle(previous: .empty(side: .left), query: "tax"))
        #expect(!PaneLogic.searchStaysIdle(previous: results("tax", generation: 2), query: ""))
        #expect(!PaneLogic.searchStaysIdle(previous: results("tax", generation: 2), query: "tax"))
    }

    /// The idle check must run before the generation is bumped and the results written.
    /// `recomputeSearch` is on `ContentView`, which a test can't mount, so its order is read from
    /// source.
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
        let bump = try #require(body.range(of: ".generation + 1"),
                                "the generation bump moved — re-aim this check")
        let write = try #require(body.range(of: "leftSearchResults = results"),
                                 "the results write moved — re-aim this check")
        #expect(idle.lowerBound < bump.lowerBound && idle.lowerBound < write.lowerBound,
                "the idle check runs after the generation is bumped, so an empty republish still publishes")
    }

    /// The side annotation reads the other pane's tree before its type filter: a file that filter
    /// hides is still on that side. Read from source.
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

    /// `.task(id:)` restarts exactly when this compares unequal, so `==` defines when the search
    /// re-runs. Each row changes one field: typing; a republish (a scan, delete or hidden-files toggle
    /// rebuilds the tree, so stale hits would select a ghost); the other pane's republish, which the
    /// side annotation reads; and the other pane itself, whose query and counters are its own.
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
