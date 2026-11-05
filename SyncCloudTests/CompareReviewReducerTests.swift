import Testing
@testable import SyncCloud

/// The decision table for `CompareReviewReducer`: which effects each Compare-pane event asks for
/// in each review state, so the teardown rules can't drift.
@Suite struct CompareReviewReducerTests {

    private func state(review: Bool = false, active: Bool = false, guided: Bool = false) -> CompareReviewState {
        CompareReviewState(hasDuplicateReview: review, duplicateReviewActive: active, isGuidedReviewing: guided)
    }
    private func effects(_ e: CompareReviewEvent, _ s: CompareReviewState) -> [CompareReviewEffect] {
        CompareReviewReducer.effects(for: e, state: s)
    }

    // MARK: A user-chosen comparison change drops the review WITHOUT restoring

    @Test func providerSwitchDuringAnActiveReviewDropsItWithoutRestoring() {
        // Active: both panes still show the two copies, so the comparison the user is redefining
        // is the one in front of them. Their choice stands; nothing is put back.
        let active = { self.state(review: true, active: true, guided: $0) }
        #expect(effects(.providerSwitched(isLeft: true), active(true)) == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.providerSwitched(isLeft: true), active(false)) == [.clearDuplicateReview])
        #expect(effects(.providerSwitched(isLeft: false), active(false)) == [.clearDuplicateReview])
        // No review to drop: only a guided session (if any) ends.
        #expect(effects(.providerSwitched(isLeft: true), state(review: false, guided: true)) == [.endGuidedReview])
        #expect(effects(.providerSwitched(isLeft: true), state()) == [])
    }

    @Test func providerSwitchAfterTheReviewWentInactiveReleasesItsPin() {
        // Inactive: the user has moved on (entering an Organize lens refocuses the shared left
        // pane), but `compareCopies` still pins the other pane to the duplicate's provider. The
        // user never chose that pin, and dropping the snapshot without releasing it would strand
        // that pane on the duplicate's provider for good.
        #expect(effects(.providerSwitched(isLeft: true), state(review: true, active: false))
                == [.clearDuplicateReview, .undoProviderPin(keepingUserChoiceOnLeft: true)])
        #expect(effects(.providerSwitched(isLeft: false), state(review: true, active: false))
                == [.clearDuplicateReview, .undoProviderPin(keepingUserChoiceOnLeft: false)])
        #expect(effects(.providerSwitched(isLeft: true), state(review: true, active: false, guided: true))
                == [.endGuidedReview, .clearDuplicateReview, .undoProviderPin(keepingUserChoiceOnLeft: true)])
    }

    /// A tab-driven source change never asks for `.undoProviderPin`, in any state.
    ///
    /// That effect repoints the sibling pane's provider and re-homes it onto the pre-review folder.
    /// `adoptProviderForTab` must never have a pane re-homed under it, since the tab it applies
    /// carries the navigation: the untouched pane would leave the folder its own tab names, and
    /// `saveBrowseTabs` would write that over the tab for good, silently retargeting it to another
    /// cloud.
    ///
    /// Every state, because the pin undo is reached from only one (review set, gone inactive) and
    /// a test that missed it would pass on a reducer that still asked for it.
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
        // The control: it is not inert. The stale review still goes and a guided review framed on
        // the old pair still ends, which is why the dispatch exists.
        #expect(effects(.tabChangedSource, state(review: true, active: false))
                == [.clearDuplicateReview])
        #expect(effects(.tabChangedSource, state(review: true, active: true, guided: true))
                == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.tabChangedSource, state(review: false, guided: true)) == [.endGuidedReview])
        #expect(effects(.tabChangedSource, state()) == [])
        // The difference from `.providerSwitched` in the one state that separates them, stated as
        // a comparison so the two can't be quietly merged.
        #expect(effects(.tabChangedSource, state(review: true, active: false))
                != effects(.providerSwitched(isLeft: true), state(review: true, active: false)))
    }

    @Test func swapBehavesLikeAProviderSwitch() {
        #expect(effects(.panesSwapped, state(review: true, guided: true)) == [.endGuidedReview, .clearDuplicateReview])
        #expect(effects(.panesSwapped, state(review: true)) == [.clearDuplicateReview])
    }

    @Test func rootEditBehavesLikeAProviderSwitch() {
        // A root edit drops both reviews, since the duplicate review's keeper and copy paths live
        // under the edited root. It must not restore: the user chose the edit, and the saved
        // relative paths belong to roots that no longer exist.
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
        // A restore must come with ending the guided review, or a frozen queue keeps running
        // against stale paths under a relabeled card.
        for event: CompareReviewEvent in [.reviewDone, .rightCopyTrashed] {
            #expect(effects(event, state(review: true, guided: true)) == [.endGuidedReview, .clearDuplicateReview, .restoreCompareState])
            #expect(effects(event, state(review: true, guided: false)) == [.clearDuplicateReview, .restoreCompareState])
            #expect(effects(event, state(review: false, guided: true)) == [])   // nothing to end/restore
        }
    }

    // MARK: Leaving Compare

    @Test func abandoningAnInactiveReviewAlsoRestores() {
        // Dropping an abandoned review must also restore, or the auto-pinned provider leaks.
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

    // MARK: Every event, by construction

    /// One value per case, and every payload combination of the branching `tabSwitched`. The enum
    /// can't be `CaseIterable` (three cases carry payloads), so the completeness scan below keeps
    /// this list total: a new case fails it until it is added here, which puts it under the
    /// invariant loop.
    private static let everyEvent: [CompareReviewEvent] = [
        .tabSwitched(toCompare: false, fromCompare: false),
        .tabSwitched(toCompare: false, fromCompare: true),
        .tabSwitched(toCompare: true, fromCompare: false),
        .tabSwitched(toCompare: true, fromCompare: true),
        .providerSwitched(isLeft: true), .providerSwitched(isLeft: false),
        .tabChangedSource,
        .comparisonRootEdited,
        .panesSwapped,
        .compareCopiesStarted,
        .reviewDone,
        .rightCopyTrashed,
    ]

    /// `everyEvent` names every declared case, so the event type's claim that its teardown
    /// invariant is checked for every event stays true when a case is added.
    @Test func theEventListNamesEveryDeclaredCase() throws {
        let source = try macAppFile("CompareReviewReducer.swift")
        let header = try #require(source.range(of: "enum CompareReviewEvent: Equatable {"),
                                  "the event enum moved or was respelled — update this anchor")
        let afterHeader = source[header.upperBound...]
        // The enum is top-level, so the first column-0 close is its own; nested braces are indented.
        let end = try #require(afterHeader.range(of: "\n}"), "the event enum never closes")
        let body = afterHeader[..<end.lowerBound]
        let declared = Set(body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") && !$0.hasPrefix("case .") }
            .compactMap { line in
                line.dropFirst("case ".count).prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
            }
            .map(String.init)
            .filter { !$0.isEmpty })
        try #require(declared.count > 5, "only \(declared.count) cases parsed — the parser is broken, not the enum")

        let listed = Set(Self.everyEvent.map { event in
            Mirror(reflecting: event).children.first?.label ?? String(describing: event)
        })
        #expect(listed == declared,
                "everyEvent and the enum disagree — an event outside the invariant loop can quietly diverge: declared \(declared.sorted()), listed \(listed.sorted())")

        // The set holds one exemplar per case, so it can't see `tabSwitched` losing payload
        // combinations. The count keeps the branching case's full truth table in the loop.
        let tabSwitchedCombos = Self.everyEvent.filter {
            Mirror(reflecting: $0).children.first?.label == "tabSwitched"
        }
        #expect(tabSwitchedCombos.count == 4,
                "tabSwitched has two Bools — all four combinations belong in everyEvent, found \(tabSwitchedCombos.count)")
    }

    /// The teardown invariants, for every event in every state, which no handler may break:
    /// - a review is only ever cleared while one is set;
    /// - restoring the pre-review comparison always accompanies clearing;
    /// - the pin undo, likewise, only accompanies a clear;
    /// - clearing while a guided review runs also ends it, since its framing review is going away;
    /// - `endGuidedReview` is never emitted when no guided review is running.
    @Test func everyEventKeepsTheTeardownInvariantsInEveryState() {
        for event in Self.everyEvent {
            for review in [false, true] {
                for active in [false, true] {
                    for guided in [false, true] {
                        let s = state(review: review, active: active, guided: guided)
                        let out = effects(event, s)
                        let clears = out.contains(.clearDuplicateReview)
                        if clears {
                            #expect(review, "\(event) cleared a review that was not set (state \(s))")
                        }
                        if out.contains(.restoreCompareState) {
                            #expect(clears, "\(event) restored without dropping the review (state \(s))")
                        }
                        if out.contains(where: { if case .undoProviderPin = $0 { return true }; return false }) {
                            #expect(clears, "\(event) undid the pin of a review it kept (state \(s))")
                        }
                        if clears, guided {
                            #expect(out.contains(.endGuidedReview),
                                    "\(event) dropped the review a guided session was framed on without ending it (state \(s))")
                        }
                        if !guided {
                            #expect(!out.contains(.endGuidedReview),
                                    "\(event) ended a guided review that was not running (state \(s))")
                        }
                    }
                }
            }
        }
    }
}
