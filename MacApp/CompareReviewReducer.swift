import Foundation

/// Pure decision logic for the Compare-pane review state — the duplicate-copy review
/// (`duplicateReview`) and any active guided review (`reviewStore`). `ContentView` used to make
/// these decisions inline in each event handler (the tab-picker binding, the provider-id onChanges,
/// the swap/compare-copies/done/trash paths), and TWICE a handler forgot part of the teardown:
/// once it dropped the review without restoring the auto-pinned provider, once it restored without
/// ending the guided review. Both were unreachable by the app's tests because they lived in
/// `@State` glue.
///
/// Centralizing the decision here turns each event into one testable row: the invariant "an event
/// that drops a review must also end any guided review AND restore the pre-review comparison —
/// unless the user themselves changed the comparison (then just drop it)" is now checked for every
/// event by `CompareReviewReducerTests`, so a future handler can't quietly diverge.
enum CompareReviewEvent: Equatable {
    /// The bottom tab changed. `toCompare`/`fromCompare` are whether the new/old tab is the
    /// Compare tab (kept as bools so this stays independent of `ContentView.BottomTab`).
    case tabSwitched(toCompare: Bool, fromCompare: Bool)
    /// The user manually switched a pane's provider (a change they chose — don't restore).
    case providerSwitched
    /// The user swapped the panes (redefines the comparison — don't restore).
    case panesSwapped
    /// A "Compare copies" hand-off is starting; end any prior review before the new one is set.
    case compareCopiesStarted
    /// The review's "Done" button.
    case reviewDone
    /// The review's "Trash right copy" completed.
    case rightCopyTrashed
}

/// The slice of Compare state the decision depends on.
struct CompareReviewState: Equatable {
    /// A duplicate-copy review is set (`duplicateReview != nil`).
    var hasDuplicateReview: Bool
    /// Both panes are still focused on the two reviewed copies (`duplicateReviewActive`).
    var duplicateReviewActive: Bool
    /// A guided review session is running (`reviewStore.isReviewing`).
    var isGuidedReviewing: Bool
}

/// A side effect for `ContentView` to perform. The reducer only decides WHICH; `ContentView` owns
/// the implementations (they touch `@State`, providers, panes, and the scan).
enum CompareReviewEffect: Equatable {
    /// End the active guided review (`endReviewForComparisonChange`).
    case endGuidedReview
    /// Drop the duplicate-copy review without restoring (`duplicateReview = nil`).
    case clearDuplicateReview
    /// Put the panes back to the pre-review comparison (`restoreCompareState`) — implies dropping
    /// the review too; always emitted together with `.clearDuplicateReview`.
    case restoreCompareState
    /// Re-focus both panes on the two copies and re-diff (returning to Compare mid-review).
    case refocusCopies
}

enum CompareReviewReducer {
    /// The effects `ContentView` should apply for `event`, given `state`. Order is the apply order.
    static func effects(for event: CompareReviewEvent, state: CompareReviewState) -> [CompareReviewEffect] {
        // Ending the guided review is a no-op unless one is running; keep the effect list exact.
        let endGuided: [CompareReviewEffect] = state.isGuidedReviewing ? [.endGuidedReview] : []

        switch event {
        case .providerSwitched, .panesSwapped:
            // The user chose to change the comparison — drop the review WITHOUT restoring (that
            // would fight their choice). Still end any guided review framed on the old panes.
            return endGuided + (state.hasDuplicateReview ? [.clearDuplicateReview] : [])

        case .compareCopiesStarted:
            // End any prior review; the caller establishes the new duplicateReview itself.
            return endGuided

        case .reviewDone, .rightCopyTrashed:
            // Explicit end: nothing to do without a review; otherwise tear down the guided review
            // AND restore the pre-review comparison (the auto-pinned provider must not leak).
            guard state.hasDuplicateReview else { return [] }
            return endGuided + [.clearDuplicateReview, .restoreCompareState]

        case .tabSwitched(let toCompare, let fromCompare):
            // Leaving Compare with a review the user already navigated away from (inactive): it's
            // abandoned — tear it down exactly like Done, so the provider pin doesn't leak.
            if fromCompare, state.hasDuplicateReview, !state.duplicateReviewActive {
                return endGuided + [.clearDuplicateReview, .restoreCompareState]
            }
            // Returning to Compare with a review still set: re-focus the two copies (the shared
            // left pane was reset while away). An ACTIVE review leaving for Tidy is kept, not torn
            // down, so the round-trip restores it.
            if toCompare, state.hasDuplicateReview {
                return [.refocusCopies]
            }
            return []
        }
    }
}
