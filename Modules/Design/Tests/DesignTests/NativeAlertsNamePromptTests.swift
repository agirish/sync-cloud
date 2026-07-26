import Testing
@testable import Design

/// Pins the rename / new-folder prompt's re-prompt contract.
///
/// The bug these exist for: confirming the sheet with an empty (or whitespace-only) name returned
/// nil, and nil is this API's *Cancel* signal — so `FileActionHandler` and every other caller read
/// it as "the user backed out". The dialog closed with no rename, no new folder, and no
/// explanation, while any OTHER invalid name got a reason and a second try. The loop lives in
/// `NativeAlerts.runNamePrompt` with its two modal presentations injected precisely because a
/// blank entry ending the loop is indistinguishable from a cancel when observed from outside —
/// which is how it went unnoticed. Here the two are distinguishable: a cancel presents once and
/// explains nothing, a rejection presents again and explains why.
@Suite struct NativeAlertsNamePromptTests {

    /// Drives `runNamePrompt` with a scripted sequence of what the user "types", recording what
    /// the prompt showed and what it explained.
    @MainActor
    private final class Session {
        private(set) var presentedDrafts: [String] = []
        private(set) var explanations: [(name: String, reason: String)] = []
        private var entries: [String?]
        private var next = 0

        /// - Parameter entries: one element per round; a String is confirmed text, nil is Cancel.
        init(_ entries: [String?]) { self.entries = entries }

        func present(_ draft: String) -> String? {
            presentedDrafts.append(draft)
            defer { next += 1 }
            // Running past the script means the loop asked for a round the test didn't expect —
            // surface it as a cancel so the test fails on its assertions rather than trapping.
            guard next < entries.count else { return nil }
            return entries[next]
        }

        func explain(_ name: String, _ reason: String) { explanations.append((name, reason)) }
    }

    /// The app's real rule (`FileSyncManager.validateItemName`), reduced to the two cases that
    /// matter here. Design can't import Sync, and doesn't need to — it takes the rule as a closure.
    private let validate: (String) -> String? = { name in
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A name is required." }
        if name.contains("/") { return "Names can't contain \"/\"." }
        return nil
    }

    /// The finding itself: a blank confirm must come back for another try, with a reason.
    @MainActor
    @Test func blankNameRePromptsWithAReasonInsteadOfSilentlyCancelling() {
        let session = Session(["   ", "Receipts"])
        let result = NativeAlerts.runNamePrompt(
            initialValue: "untitled folder",
            validate: validate,
            present: session.present,
            explain: session.explain
        )

        #expect(result == "Receipts")
        #expect(session.presentedDrafts.count == 2, "the blank entry ended the prompt instead of re-asking")
        #expect(session.explanations.count == 1)
        #expect(session.explanations.first?.reason == "A name is required.")
    }

    /// A blank entry behaves exactly like any other invalid one — that parity is the fix. Both
    /// re-present, both explain, both hand the rejected text back so it can be corrected in place.
    @MainActor
    @Test func blankNameFollowsTheSamePathAsAnyOtherInvalidName() {
        let blank = Session(["", "Taxes"])
        _ = NativeAlerts.runNamePrompt(initialValue: "untitled folder", validate: validate,
                                       present: blank.present, explain: blank.explain)
        let slashed = Session(["a/b", "Taxes"])
        _ = NativeAlerts.runNamePrompt(initialValue: "untitled folder", validate: validate,
                                       present: slashed.present, explain: slashed.explain)

        #expect(blank.presentedDrafts.count == slashed.presentedDrafts.count)
        #expect(blank.explanations.count == slashed.explanations.count)
        // Each re-prompt is pre-filled with what was actually typed, not reset to the initial value.
        #expect(blank.presentedDrafts == ["untitled folder", ""])
        #expect(slashed.presentedDrafts == ["untitled folder", "a/b"])
    }

    /// Cancel is still the only thing that returns nil — the channel a blank name used to steal.
    @MainActor
    @Test func cancelIsTheOnlyNilResult() {
        let session = Session([nil])
        let result = NativeAlerts.runNamePrompt(
            initialValue: "Report", validate: validate,
            present: session.present, explain: session.explain
        )

        #expect(result == nil)
        #expect(session.presentedDrafts == ["Report"])
        #expect(session.explanations.isEmpty, "a cancel must not lecture the user")
    }

    /// A name that passes on the first try is returned trimmed, with nothing explained.
    @MainActor
    @Test func acceptedNameIsReturnedTrimmedOnTheFirstRound() {
        let session = Session(["  Receipts  "])
        let result = NativeAlerts.runNamePrompt(
            initialValue: "untitled folder", validate: validate,
            present: session.present, explain: session.explain
        )

        #expect(result == "Receipts")
        #expect(session.presentedDrafts.count == 1)
        #expect(session.explanations.isEmpty)
    }

    /// Empty can never escape as a *result*, whatever the caller's validator says: nil is the
    /// Cancel channel, so a validator that accepted a blank name would otherwise reintroduce the
    /// phantom cancel from the other side.
    @MainActor
    @Test func emptyIsRejectedEvenWhenTheCallerValidatorAcceptsIt() {
        let permissive: (String) -> String? = { _ in nil }
        #expect(NativeAlerts.nameRejectionReason(for: "", validate: permissive) != nil)
        #expect(NativeAlerts.nameRejectionReason(for: "Receipts", validate: permissive) == nil)
    }

    /// …and when the caller DOES have wording for it, that wording wins over the built-in fallback.
    @MainActor
    @Test func callerWordingWinsForTheEmptyCase() {
        #expect(NativeAlerts.nameRejectionReason(for: "", validate: { _ in "Folders need a name." })
            == "Folders need a name.")
    }
}
