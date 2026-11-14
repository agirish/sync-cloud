import Testing
import SwiftUI
@testable import SyncCloud
import Design
import Sync

/// The banner's two visibility rules, on the real view struct: Undo shows only when it can work,
/// and Reduce Motion hides the countdown bar.
@MainActor
@Suite struct OperationBannerViewTests {

    private func view(isUndoable: Bool, canUndo: Bool) -> OperationBannerView {
        OperationBannerView(
            banner: OperationBanner(message: "Moved 2 items", severity: .success, log: .info, isUndoable: isUndoable),
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
            banner: OperationBanner(message: "x", severity: .error, log: .error),
            glassLevel: .frosted, canUndo: false,
            onUndo: {}, onClose: {}, onHover: { _ in }).autoDismissSeconds
        #expect(sticky == nil, "error banners are sticky — no window, no bar")
        #expect(!OperationBannerView.showsCountdown(autoDismissSeconds: sticky, reduceMotion: false))
    }

    /// VoiceOver hears the message when it appears, and that ⌘Z takes it back when the Undo button
    /// is there.
    @Test func theAnnouncementIsTheMessageAndItsUndo() {
        let deleted = OperationBanner.success("Deleted “Test3.md”", undoable: true)
        #expect(OperationBannerView.announcement(for: deleted, offersUndo: true)
                == "Deleted “Test3.md”. Undo available, Command Z")
        #expect(OperationBannerView.announcement(for: deleted, offersUndo: false) == "Deleted “Test3.md”",
                "Undo announced with no button to take it")
        let sentence = OperationBanner.warning("Reclaimed 4 KB from 1 of 2 groups — the rest stay listed.", undoable: true, log: .warn)
        #expect(OperationBannerView.announcement(for: sentence, offersUndo: true)
                == "Reclaimed 4 KB from 1 of 2 groups — the rest stay listed. Undo available, Command Z")
        // The window posts it on every new message, with the button's Undo rule, and no Undo while
        // a long run greys it.
        let window = (try? macAppFile("ContentView+ResultMessage.swift")) ?? ""
        #expect(CodeText(window).contains("OperationBannerView.announce(banner, offersUndo: banner.isUndoable && (undoManager?.canUndo ?? false)\n && runWriteLockReason == nil)"),
                "no announcement is posted when a message appears, or it offers an Undo a run has greyed")
    }

    /// A finished file's follow-up buttons, in the PDF tools' words.
    @Test func followUpsAreTheToolsOwnDoors() {
        #expect(OperationBannerView.title(for: .openInEdit("/a/Lease.pdf")) == "Open in Edit")
        #expect(OperationBannerView.title(for: .revealInBrowse(["/a/Lease.pdf"])) == "Reveal in Browse")
        #expect(OperationBannerView.help(for: .openInEdit("/a/Lease.pdf")) == "Open “Lease.pdf” in Edit")
        #expect(OperationBannerView.help(for: .revealInBrowse(["/a", "/b"])) == "Show the 2 files in Browse")
    }

    /// `body` must decide through `showsUndo` / `showsCountdown`, not a re-inlined copy this suite
    /// can't see: a rule extracted for testing is one revert from unused.
    @Test func theBodyReadsTheExtractedRulesNotInlineCopies() throws {
        let source = try macAppFile("OperationBannerView.swift")
        #expect(source.contains("if showsUndo {"),
                "body no longer gates the Undo button on the tested rule")
        #expect(source.contains("if showsCountdown {"),
                "body no longer gates the countdown bar on the tested rule")
        // The raw conjunctions must not reappear inline, or the truth tables above stop describing
        // the shipped gates. Matched as ingredient pairs, not one phrase, so a reordered
        // `canUndo && banner.isUndoable` can't slip past.
        let lines = sourceCodeOnly(source).split(separator: "\n")
        let undoReinlines = lines.filter {
            $0.contains("isUndoable") && $0.contains("canUndo") && !$0.contains("showsUndo")
        }
        #expect(undoReinlines.isEmpty,
                "the Undo conjunction was re-inlined — the tested rule is a parallel copy again: \(undoReinlines)")
        // Conditional lines only: the declaration, the static rule and the delegation all name
        // reduceMotion legitimately. What must not exist is a branch on it outside the rule, such
        // as `guard let seconds = autoDismissSeconds, !reduceMotion else`.
        let countdownReinlines = lines.filter {
            ($0.contains("guard ") || $0.contains("if ")) && $0.contains("reduceMotion")
        }
        #expect(countdownReinlines.isEmpty,
                "a branch consults reduceMotion outside the tested countdown rule — a parallel copy of the gate: \(countdownReinlines)")

        // The instance property must delegate to the tested static, or the shipped gate could
        // drift from it with every assertion above still green.
        #expect(source.contains("Self.showsCountdown(autoDismissSeconds: autoDismissSeconds, reduceMotion: reduceMotion)"),
                "the instance showsCountdown no longer delegates to the tested static rule")
    }
}
