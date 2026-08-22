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
        // The negative direction: the raw conjunction must not reappear inline in body, or the
        // truth table above stops describing the shipped gate.
        #expect(!source.contains("if banner.isUndoable && canUndo"),
                "the Undo gate was re-inlined — the tested rule is a parallel copy again")
    }
}
