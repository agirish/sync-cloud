import Testing
@testable import SyncCloud

/// The decision table for `CompareReviewReducer` — the tests that make the Compare-pane review state
/// regression-resistant. Two of these (`abandoningAnInactiveReviewAlsoRestores`,
/// `endingAReviewAlsoEndsTheGuidedReview`) pin exactly the two bugs that previously shipped from this
/// logic when it lived inline in `ContentView` and was unreachable by tests.
@Suite struct CompareReviewReducerTests {

    private func state(review: Bool = false, active: Bool = false, guided: Bool = false) -> CompareReviewState {
        CompareReviewState(hasDuplicateReview: review, duplicateReviewActive: active, isGuidedReviewing: guided)
    }
    private func effects(_ e: CompareReviewEvent, _ s: CompareReviewState) -> [CompareReviewEffect] {
        CompareReviewReducer.effects(for: e, state: s)
    }

    // MARK: A user-chosen comparison change drops the review WITHOUT restoring

    @Test func providerSwitchDropsReviewWithoutRestoring() {
        #expect(effects(.providerSwitched, state(review: true, guided: true)) == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.providerSwitched, state(review: true, guided: false)) == [.clearDuplicateReview])
        #expect(effects(.providerSwitched, state(review: false, guided: true)) == [.endGuidedReview])
        #expect(effects(.providerSwitched, state()) == [])
    }

    @Test func swapBehavesLikeAProviderSwitch() {
        #expect(effects(.panesSwapped, state(review: true, guided: true)) == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.panesSwapped, state(review: true)) == [.clearDuplicateReview])
    }

    // MARK: Starting a hand-off ends any prior review; the caller sets the new one

    @Test func compareCopiesStartOnlyEndsAPriorGuidedReview() {
        #expect(effects(.compareCopiesStarted, state(review: true, guided: true)) == [.endGuidedReview])
        #expect(effects(.compareCopiesStarted, state(review: true, guided: false)) == [])
        #expect(effects(.compareCopiesStarted, state()) == [])
    }

    // MARK: Explicit end (Done / Trash) — end the guided review AND restore

    @Test func endingAReviewAlsoEndsTheGuidedReview() {
        // Round-3 regression guard: restore must be accompanied by ending the guided review, or a
        // frozen queue keeps running against stale paths under a relabeled card.
        for event: CompareReviewEvent in [.reviewDone, .rightCopyTrashed] {
            #expect(effects(event, state(review: true, guided: true)) == [.endGuidedReview, .clearDuplicateReview, .restoreCompareState])
            #expect(effects(event, state(review: true, guided: false)) == [.clearDuplicateReview, .restoreCompareState])
            #expect(effects(event, state(review: false, guided: true)) == [])   // nothing to end/restore
        }
    }

    // MARK: Leaving Compare

    @Test func abandoningAnInactiveReviewAlsoRestores() {
        // Round-1 regression guard: dropping an abandoned review MUST also restore, or the
        // auto-pinned provider leaks.
        let left = CompareReviewEvent.tabSwitched(toCompare: false, fromCompare: true)
        #expect(effects(left, state(review: true, active: false, guided: true)) == [.endGuidedReview, .clearDuplicateReview, .restoreCompareState])
        #expect(effects(left, state(review: true, active: false, guided: false)) == [.clearDuplicateReview, .restoreCompareState])
    }

    @Test func leavingCompareWithAnActiveReviewKeepsIt() {
        // An active review (both panes still on the copies) survives the Tidy round-trip.
        let left = CompareReviewEvent.tabSwitched(toCompare: false, fromCompare: true)
        #expect(effects(left, state(review: true, active: true, guided: true)) == [])
        #expect(effects(left, state(review: false)) == [])
    }

    // MARK: Returning to Compare

    @Test func returningToCompareWithAReviewRefocusesTheCopies() {
        let back = CompareReviewEvent.tabSwitched(toCompare: true, fromCompare: false)
        #expect(effects(back, state(review: true)) == [.refocusCopies])
        #expect(effects(back, state(review: false)) == [])
    }
}
