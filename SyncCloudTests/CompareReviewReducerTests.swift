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
        // INACTIVE: the user has already moved on — entering a Tidy lens re-focuses the shared
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

    // MARK: Every event, by construction

    /// One value per case (every payload combination for the branching `tabSwitched`). The enum
    /// cannot be `CaseIterable` — three cases carry payloads — so the completeness scan below is
    /// what keeps this list total: a ninth case fails that scan until it is added here, and adding
    /// it here is what puts it under the invariant loop.
    private static let everyEvent: [CompareReviewEvent] = [
        .tabSwitched(toCompare: false, fromCompare: false),
        .tabSwitched(toCompare: false, fromCompare: true),
        .tabSwitched(toCompare: true, fromCompare: false),
        .tabSwitched(toCompare: true, fromCompare: true),
        .providerSwitched(isLeft: true), .providerSwitched(isLeft: false),
        // This line has no `.tabChangedSource` — browse tabs are v4. The completeness scan reads
        // THIS line's enum, so the list stays per-line by construction.
        .comparisonRootEdited,
        .panesSwapped,
        .compareCopiesStarted,
        .reviewDone,
        .rightCopyTrashed,
    ]

    /// The event type's own doc claims its teardown invariant "is now checked for every event" —
    /// which was aspirational while nine hand-written tests enforced it: a tenth case added
    /// tomorrow got zero coverage and the comment stayed wrong. This makes the claim structural.
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

        // The scan above holds one exemplar PER CASE, so it cannot see three of tabSwitched's
        // four payload combinations quietly disappearing from the list. The count pins what the
        // set cannot: the branching case keeps its full truth table in the loop.
        let tabSwitchedCombos = Self.everyEvent.filter {
            Mirror(reflecting: $0).children.first?.label == "tabSwitched"
        }
        #expect(tabSwitchedCombos.count == 4,
                "tabSwitched has two Bools — all four combinations belong in everyEvent, found \(tabSwitchedCombos.count)")
    }

    /// The teardown invariants, for EVERY event in every state — the properties no handler may
    /// break whatever new event arrives:
    /// - a review is only ever cleared while one is set;
    /// - restoring the pre-review comparison always accompanies clearing (never a restore of a
    ///   review that stays);
    /// - the pin undo is likewise only an accessory to a clear;
    /// - clearing while a guided review runs must also end the guided review (the review it was
    ///   framed on is going away);
    /// - and `endGuidedReview` is exact — never emitted when no guided review is running.
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
