import Testing
import SwiftUI
@testable import SyncCloud
import Design
import Sync

/// The banner's two visibility rules, on the real view struct. Neither had any coverage: a dead
/// Undo button on a banner for a destructive operation — or a missing live one — was invisible to
/// every suite, and so was the Reduce Motion suppression of the countdown bar.
@MainActor
@Suite struct OperationBannerViewTests {

    private func view(isUndoable: Bool, canUndo: Bool) -> OperationBannerView {
        OperationBannerView(
            banner: OperationBanner(message: "Moved 2 items", severity: .success, isUndoable: isUndoable),
            glassLevel: .frosted,
            canUndo: canUndo,
            onUndo: {}, onClose: {}, onHover: { _ in })
    }

    /// Undo shows only when the outcome is a single undo step AND the stack still has it. All four
    /// combinations, because the two false reasons fail differently in the app: `isUndoable` false
    /// is a bulk outcome ⌘Z cannot honestly claim; `canUndo` false is an operation already undone
    /// elsewhere, where the button would be dead.
    @Test(arguments: [(true, true, true), (true, false, false), (false, true, false), (false, false, false)])
    func undoShowsOnlyForAnUndoableOutcomeStillOnTheStack(isUndoable: Bool, canUndo: Bool, expected: Bool) {
        #expect(view(isUndoable: isUndoable, canUndo: canUndo).showsUndo == expected)
    }

    /// The countdown bar mirrors the real dismiss timer and vanishes under Reduce Motion. The
    /// seconds come from the scheduler's own delays, so this also pins the sticky-error rule:
    /// an error banner has no window and therefore no bar, whatever the motion setting.
    @Test func countdownFollowsTheSchedulerWindowAndReduceMotion() {
        let success = view(isUndoable: false, canUndo: false).autoDismissSeconds
        #expect(success != nil, "success banners auto-dismiss, so the bar has a window to mirror")
        #expect(OperationBannerView.showsCountdown(autoDismissSeconds: success, reduceMotion: false))
        #expect(!OperationBannerView.showsCountdown(autoDismissSeconds: success, reduceMotion: true),
                "Reduce Motion must suppress the animated bar")

        let sticky = OperationBannerView(
            banner: OperationBanner(message: "x", severity: .error),
            glassLevel: .frosted, canUndo: false,
            onUndo: {}, onClose: {}, onHover: { _ in }).autoDismissSeconds
        #expect(sticky == nil, "error banners are sticky — no window, no bar")
        #expect(!OperationBannerView.showsCountdown(autoDismissSeconds: sticky, reduceMotion: false))
    }

    /// The call-site half of the extracted rules (a rule extracted for testability is one revert
    /// from unused): `body` must decide through `showsUndo` / `showsCountdown`, not through a
    /// re-inlined copy that this suite can no longer see.
    @Test func theBodyReadsTheExtractedRulesNotInlineCopies() throws {
        let source = try macAppFile("OperationBannerView.swift")
        #expect(source.contains("if showsUndo {"),
                "body no longer gates the Undo button on the tested rule")
        #expect(source.contains("if showsCountdown {"),
                "body no longer gates the countdown bar on the tested rule")
        // The negative direction: the raw conjunctions must not reappear inline, or the truth
        // tables above stop describing the shipped gates. Spelled as ingredient pairs rather than
        // one exact phrase, so a reordered `canUndo && banner.isUndoable` — or the countdown's
        // `guard let seconds …, !reduceMotion` that survived the first extraction — cannot slip
        // past a ban that only knew one spelling.
        let lines = source.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let undoReinlines = lines.filter {
            $0.contains("isUndoable") && $0.contains("canUndo") && !$0.contains("showsUndo")
        }
        #expect(undoReinlines.isEmpty,
                "the Undo conjunction was re-inlined — the tested rule is a parallel copy again: \(undoReinlines)")
        // Conditional lines only: the declaration, the static rule's signature and body, and the
        // delegation all mention reduceMotion legitimately — what must not exist is a BRANCH on
        // it outside the rule, which is the shape the surviving copy had
        // (`guard let seconds = autoDismissSeconds, !reduceMotion else`).
        let countdownReinlines = lines.filter {
            ($0.contains("guard ") || $0.contains("if ")) && $0.contains("reduceMotion")
        }
        #expect(countdownReinlines.isEmpty,
                "a branch consults reduceMotion outside the tested countdown rule — a parallel copy of the gate: \(countdownReinlines)")

        // And the instance property must DELEGATE to the static the truth table drives — a
        // re-derived instance body would let the shipped gate drift from the tested one while
        // every assertion above stays green.
        #expect(source.contains("Self.showsCountdown(autoDismissSeconds: autoDismissSeconds, reduceMotion: reduceMotion)"),
                "the instance showsCountdown no longer delegates to the tested static rule")
    }
}
