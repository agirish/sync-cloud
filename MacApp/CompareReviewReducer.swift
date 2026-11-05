import Foundation

/// Pure decision logic for the Compare-pane review state: the duplicate-copy review
/// (`duplicateReview`) and any guided review (`reviewStore`). Kept out of `ContentView`'s `@State`
/// glue so each event is one testable row. The invariant: an event that drops a review also ends
/// any guided review and restores the pre-review comparison, unless the user changed the
/// comparison themselves (then it just drops it). `CompareReviewReducerTests` checks it for every
/// event.
enum CompareReviewEvent: Equatable {
    /// The bottom tab changed. `toCompare`/`fromCompare` are whether the new/old tab is the
    /// Compare tab (plain bools, so the reducer depends on no tab type).
    case tabSwitched(toCompare: Bool, fromCompare: Bool)
    /// The user manually switched a pane's provider (a change they chose — don't restore the
    /// comparison). `isLeft` says which pane they repointed: while a duplicate review is set but
    /// no longer active, the OTHER pane may still be carrying the review's programmatic pin, and
    /// that pin is not something the user chose.
    case providerSwitched(isLeft: Bool)
    /// A tab changed a pane's source. The user chose it, as with `.providerSwitched`, but the tab
    /// carries the navigation, so `adoptProviderForTab` does not re-home the pane. That rules out
    /// `.undoProviderPin`, which re-homes the sibling pane onto its pre-review folder: it would
    /// yank a pane off the folder its own tab names, and the next save would write that over the
    /// tab. So the review's pin on the other pane stays; a stranded pin is a far smaller harm than
    /// repointing a pane the user is looking at.
    case tabChangedSource
    /// The user edited a pane provider's root path in Settings (the pane ids are unchanged but
    /// the folders underneath them are not). Like a provider switch: a change the user chose,
    /// so drop the review without restoring — but every review framed on the old roots must end.
    case comparisonRootEdited
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
    /// Undo just the review's provider pin on the pane the user did NOT repoint, leaving their
    /// choice and the other folders alone. Narrower than `.restoreCompareState` because the user
    /// is mid-gesture on the other pane.
    ///
    /// **This re-homes the sibling pane** onto its pre-review folder: its root is moving, and a
    /// pane left on its current path would claim one source while showing another's tree, which
    /// the next save would persist. `undoProviderPin` does the re-home itself. A caller that must
    /// not have a pane re-homed under it cannot take this effect (see `.tabChangedSource`).
    case undoProviderPin(keepingUserChoiceOnLeft: Bool)
}

/// Whether a duplicate review's provider pin has been left stranded, and on which pane.
///
/// `.tabChangedSource` undoes nothing, so the review's pin can outlive the review, which is worth
/// a warning. Only the sibling of the pane the tab moved can hold one; the user chose the source
/// on the pane they clicked in. Asks about that one pane, not whether the pair changed: when the
/// pre-review pair was already the review's provider on both sides there is no pin to strand, and
/// a warning about a loss that did not happen is worse than silence.
enum StrandedProviderPin {
    /// The pane the tab did NOT move, when it is still sitting on a source the review chose;
    /// `nil` when that pane is where the user left it — whatever the pane they just moved is doing.
    static func stranded(movedPane isLeft: Bool,
                         savedLeft: String, savedRight: String,
                         currentLeft: String, currentRight: String) -> Sibling? {
        let sibling = isLeft
            ? Sibling(isLeft: false, saved: savedRight, current: currentRight)
            : Sibling(isLeft: true, saved: savedLeft, current: currentLeft)
        return sibling.saved == sibling.current ? nil : sibling
    }

    /// The pane that kept the pin, with the two ids the warning has to name: what the review left
    /// it on, and what the user had before the review.
    struct Sibling: Equatable {
        var isLeft: Bool
        var saved: String
        var current: String
        /// Through the same door every other pane-naming line in the host goes through.
        var name: String { PaneSideChoice.name(isLeft) }
    }
}

enum CompareReviewReducer {
    /// The effects `ContentView` should apply for `event`, given `state`. Order is the apply order.
    static func effects(for event: CompareReviewEvent, state: CompareReviewState) -> [CompareReviewEffect] {
        // Ending the guided review is a no-op unless one is running; keep the effect list exact.
        let endGuided: [CompareReviewEffect] = state.isGuidedReviewing ? [.endGuidedReview] : []

        switch event {
        case .providerSwitched(let isLeft):
            // The user chose to change the comparison — drop the review WITHOUT restoring (that
            // would fight their choice). Still end any guided review framed on the old panes.
            guard state.hasDuplicateReview else { return endGuided }
            // …but only while the review is active, so the comparison they redefine is the one in
            // front of them. Once inactive (an Organize lens re-focused the shared left pane), the
            // other pane still carries `compareCopies`' pin, which they never chose; dropping the
            // snapshot without undoing it would strand that pin for good.
            if state.duplicateReviewActive {
                return endGuided + [.clearDuplicateReview]
            }
            return endGuided + [.clearDuplicateReview, .undoProviderPin(keepingUserChoiceOnLeft: isLeft)]

        case .tabChangedSource:
            // Same shape as a swap: no pin undo, because `.undoProviderPin` would re-home the
            // sibling pane (see the case's note). The stale review still goes, and a guided review
            // framed on the old pair still ends.
            return endGuided + (state.hasDuplicateReview ? [.clearDuplicateReview] : [])

        case .comparisonRootEdited, .panesSwapped:
            // The user changed the comparison: drop the review without restoring, and end any
            // guided review. Restoring after a root edit would re-focus saved paths under roots
            // that no longer exist. A swap needs no pin undo: the pin travels with its pane.
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
            // left pane was reset while away). An active review leaving for Organize is kept, so
            // the round trip restores it.
            if toCompare, state.hasDuplicateReview {
                return [.refocusCopies]
            }
            return []
        }
    }
}
