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

    @Test func providerSwitchDuringAnActiveReviewDropsItWithoutRestoring() {
        // ACTIVE: both panes still show the two copies, so the comparison the user is redefining
        // is the one in front of them — their choice stands, nothing is put back.
        let active = { self.state(review: true, active: true, guided: $0) }
        #expect(effects(.providerSwitched(isLeft: true), active(true)) == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.providerSwitched(isLeft: true), active(false)) == [.clearDuplicateReview])
        #expect(effects(.providerSwitched(isLeft: false), active(false)) == [.clearDuplicateReview])
        // No review to drop: only a guided session (if any) ends.
        #expect(effects(.providerSwitched(isLeft: true), state(review: false, guided: true)) == [.endGuidedReview])
        #expect(effects(.providerSwitched(isLeft: true), state()) == [])
    }

    @Test func providerSwitchAfterTheReviewWentInactiveReleasesItsPin() {
        // INACTIVE: the user has already moved on — entering an Organize lens re-focuses the shared
        // left pane, which is exactly how this state is reached — so the OTHER pane is still
        // pinned to the duplicate's provider by `compareCopies`. That pin is bookkeeping the user
        // never chose, and dropping the snapshot without releasing it stranded their other pane on
        // the duplicate's provider permanently.
        #expect(effects(.providerSwitched(isLeft: true), state(review: true, active: false))
                == [.clearDuplicateReview, .undoProviderPin(keepingUserChoiceOnLeft: true)])
        #expect(effects(.providerSwitched(isLeft: false), state(review: true, active: false))
                == [.clearDuplicateReview, .undoProviderPin(keepingUserChoiceOnLeft: false)])
        #expect(effects(.providerSwitched(isLeft: true), state(review: true, active: false, guided: true))
                == [.endGuidedReview, .clearDuplicateReview, .undoProviderPin(keepingUserChoiceOnLeft: true)])
    }

    /// **A tab-driven source change never asks for `.undoProviderPin`, in ANY state.**
    ///
    /// That effect repoints the SIBLING pane's provider and deliberately restores no folder,
    /// because its own note says the caller's `resetNavigation()` re-homes both panes a moment
    /// later. `adoptProviderForTab` is the one caller that must never reset — the tab it is
    /// applying carries the navigation — so pairing the two left the untouched pane claiming one
    /// source while showing another's tree at a path under the wrong root, and `saveBrowseTabs`
    /// then wrote that pane's active tab under the wrong source for good. The same "a tab silently
    /// retargeted to another cloud" defect the tab fixes removed on the near pane, reintroduced on
    /// the far one by the review dispatch that was supposed to be the safe part.
    ///
    /// Every state, because the pin undo is reached only from ONE of them (review set, gone
    /// inactive) and a test that missed that state would pass on a reducer that still asked for it.
    @Test func aTabDrivenSourceChangeNeverRepointsTheSiblingPane() {
        for guided in [false, true] {
            for review in [false, true] {
                for active in [false, true] {
                    let produced = effects(.tabChangedSource,
                                           state(review: review, active: active, guided: guided))
                    #expect(!produced.contains(where: {
                        if case .undoProviderPin = $0 { return true } else { return false }
                    }), "a tab source change asked to repoint the sibling pane (review: \(review), active: \(active), guided: \(guided))")
                    #expect(!produced.contains(.restoreCompareState),
                            "a tab source change fought the user's choice by restoring the comparison")
                }
            }
        }
        // …and the control: it is not inert. The stale review still goes and a guided review
        // framed on the old pair still ends, which is why the dispatch is there at all.
        #expect(effects(.tabChangedSource, state(review: true, active: false))
                == [.clearDuplicateReview])
        #expect(effects(.tabChangedSource, state(review: true, active: true, guided: true))
                == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.tabChangedSource, state(review: false, guided: true)) == [.endGuidedReview])
        #expect(effects(.tabChangedSource, state()) == [])
        // The difference from `.providerSwitched` in the one state that separates them, stated as a
        // comparison so the two cannot be quietly merged back together.
        #expect(effects(.tabChangedSource, state(review: true, active: false))
                != effects(.providerSwitched(isLeft: true), state(review: true, active: false)))
    }

    @Test func swapBehavesLikeAProviderSwitch() {
        #expect(effects(.panesSwapped, state(review: true, guided: true)) == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.panesSwapped, state(review: true)) == [.clearDuplicateReview])
    }

    @Test func rootEditBehavesLikeAProviderSwitch() {
        // Round-4 regression guard: the settings.enabledProviders onChange used to tear down
        // inline (endReviewForComparisonChange only) and forgot to clear the duplicate review —
        // whose keeper/copy paths live under the edited root. The event must drop BOTH reviews,
        // and must NOT restore (the user chose the edit; the saved relative paths belong to
        // roots that no longer exist).
        #expect(effects(.comparisonRootEdited, state(review: true, guided: true)) == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.comparisonRootEdited, state(review: true, guided: false)) == [.clearDuplicateReview])
        #expect(effects(.comparisonRootEdited, state(review: false, guided: true)) == [.endGuidedReview])
        #expect(effects(.comparisonRootEdited, state()) == [])
        #expect(!effects(.comparisonRootEdited, state(review: true, active: true, guided: true)).contains(.restoreCompareState))
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
        // An active review (both panes still on the copies) survives the Organize round-trip.
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
