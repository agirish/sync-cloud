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
    /// Compare tab (kept as bools so this stays independent of the retired `ContentView.BottomTab`).
    case tabSwitched(toCompare: Bool, fromCompare: Bool)
    /// The user manually switched a pane's provider (a change they chose — don't restore the
    /// comparison). `isLeft` says which pane they repointed: while a duplicate review is set but
    /// no longer active, the OTHER pane may still be carrying the review's programmatic pin, and
    /// that pin is not something the user chose.
    case providerSwitched(isLeft: Bool)
    /// **A TAB changed a pane's source** — the user chose it, exactly as with `.providerSwitched`,
    /// but the tab carries the navigation, so its caller (`adoptProviderForTab`) deliberately does
    /// not `resetNavigation()`. That one difference rules out `.undoProviderPin`, which repoints the
    /// SIBLING pane and leaves re-homing it to a reset that will never come — the sibling would be
    /// left claiming one source while showing another's tree, and the next save would write that
    /// tab's source over for good.
    ///
    /// So the review's pin on the other pane is deliberately left in place here. That is what
    /// happened before tabs dispatched anything at all, it is the conservative half of the choice,
    /// and stranding a pin is a far smaller harm than repointing a pane the user is looking at.
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
    /// Undo just the review's provider pin on the pane the user did NOT repoint, leaving their own
    /// choice — and the panes' folders — alone. Narrower than `.restoreCompareState` on purpose:
    /// the user is mid-gesture on the other pane, so putting the saved folders back would yank
    /// them out of it.
    ///
    /// **Only for a caller that resets the navigation immediately afterwards.** This writes the
    /// sibling pane's provider id and deliberately restores no folder, because `undoProviderPin`'s
    /// own note says the caller's `resetNavigation()` re-homes both panes a moment later. A caller
    /// that does not reset leaves that pane claiming one source while showing another's tree at a
    /// path under the wrong root — which the next save then persists. See `.tabChangedSource`.
    case undoProviderPin(keepingUserChoiceOnLeft: Bool)
}

/// **Whether a duplicate review's programmatic provider pin has actually been left stranded — and
/// on which pane.**
///
/// `.tabChangedSource` deliberately undoes nothing (see the case's own note), so the review's pin
/// can outlive the review. That is a loss the user can see and cannot explain, and it is worth a
/// WARNING — but only when there is a pin left behind, and the pane that can hold one is the
/// SIBLING of the pane the tab moved. The user chose the source on the pane they clicked in;
/// nothing there is a leftover.
///
/// **Asked as "has the PAIR moved from the pre-review pair" instead, it warned when nothing was
/// stranded at all.** `compareCopies` pins both panes and `ProviderPinPlan` writes nothing for a
/// side already on the target — so a user whose pre-review pair was already that provider on BOTH
/// sides has no pin to strand anywhere, and a tab moving one pane still made the pair differ. The
/// line then asserted, at warning level, that a pin was stranded and "Nothing will restore that",
/// naming a loss that had not happened. A WARN about a loss that did not occur is worse than
/// silence: it is the same defect class this flow's other lines were fixed for.
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
            // …but only while the review is ACTIVE, i.e. both panes still show the two copies, so
            // the comparison they are redefining is the one in front of them. Once the review is
            // inactive the user has already moved on (entering an Organize lens re-focuses the shared
            // left pane, which is exactly how this state is reached), and the other pane is still
            // pinned to the duplicate's provider by `compareCopies` — bookkeeping they never
            // chose. Dropping the snapshot there stranded that pin permanently: the pane they
            // were comparing against before the review silently became the duplicate's provider.
            if state.duplicateReviewActive {
                return endGuided + [.clearDuplicateReview]
            }
            return endGuided + [.clearDuplicateReview, .undoProviderPin(keepingUserChoiceOnLeft: isLeft)]

        case .tabChangedSource:
            // Same shape as a swap, and for a related reason: no pin undo, because the caller does
            // not reset the navigation this event's `.undoProviderPin` would depend on. The stale
            // review still goes, and a guided review framed on the old pair still ends.
            return endGuided + (state.hasDuplicateReview ? [.clearDuplicateReview] : [])

        case .comparisonRootEdited, .panesSwapped:
            // The user chose to change the comparison — drop the review WITHOUT restoring (that
            // would fight their choice). Still end any guided review framed on the old panes.
            // A root edit reaches here too: restoring would re-focus saved relative paths under
            // roots that no longer exist, and the caller's rescan covers the new roots. A swap
            // needs no pin undo either: it exchanges the two ids, so the pin travels with the
            // pane rather than being stranded.
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
            // left pane was reset while away). An ACTIVE review leaving for Organize is kept, not torn
            // down, so the round-trip restores it.
            if toCompare, state.hasDuplicateReview {
                return [.refocusCopies]
            }
            return []
        }
    }
}
