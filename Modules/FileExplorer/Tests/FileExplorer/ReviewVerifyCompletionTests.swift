import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Pins what a finished per-item Verify is allowed to write back to the review card
/// (`ReviewCardView.applyVerifyCompletion`): the verdict ALWAYS goes out — it is session-guarded
/// downstream by `ReviewSessionStore.recordVerdict` — while the spinner write belongs only to a
/// completion whose card hasn't advanced.
@MainActor
@Suite struct ReviewVerifyCompletionTests {

    /// Runs a completion and reports what it wrote.
    private func run(sameContent: Bool?, liveToken: UUID, startedToken: UUID)
        -> (verdicts: [ReviewSession.VerifyVerdict], clearedSpinner: Bool) {
        var verdicts: [ReviewSession.VerifyVerdict] = []
        var cleared = false
        ReviewCardView.applyVerifyCompletion(
            sameContent: sameContent,
            liveToken: liveToken,
            startedToken: startedToken,
            report: { verdicts.append($0) },
            clearSpinner: { cleared = true }
        )
        return (verdicts, cleared)
    }

    @Test func hashAnswerMapsToTheVerdict() {
        let token = UUID()
        #expect(run(sameContent: true, liveToken: token, startedToken: token).verdicts == [.identical])
        #expect(run(sameContent: false, liveToken: token, startedToken: token).verdicts == [.differed])
        #expect(run(sameContent: nil, liveToken: token, startedToken: token).verdicts == [.unverifiable])
    }

    /// The ordinary case: the card still shows the item that was hashed, so the completion
    /// reports its verdict and hands the spinner back.
    @Test func aCompletionOnTheStillCurrentCardReportsAndClearsTheSpinner() {
        let token = UUID()
        let result = run(sameContent: true, liveToken: token, startedToken: token)
        #expect(result.verdicts == [.identical])
        #expect(result.clearedSpinner)
    }

    /// The regression this guard must NOT cause. Verify a large pair, click another row, click
    /// back: `.task(id: item.id)` re-minted the token twice, so the completion's token is stale
    /// even though its verdict describes a real hash of a real item. Dropping it there left the
    /// user with no spinner and no answer — the verdict must still be reported (the session
    /// token it carries is what decides whether it lands).
    @Test func aCompletionFromAnAdvancedCardStillReportsItsVerdict() {
        let result = run(sameContent: false, liveToken: UUID(), startedToken: UUID())
        #expect(result.verdicts == [.differed], "a legitimate verdict must not be discarded by the spinner guard")
    }

    /// The bug the token guard exists for (D14): a large pair returning after the card advanced
    /// must not clear the spinner of the item now on screen — `.task(id:)` already reset that
    /// flag for the NEW item, whose own verify may be running.
    @Test func aCompletionFromAnAdvancedCardDoesNotTouchTheSpinner() {
        let result = run(sameContent: true, liveToken: UUID(), startedToken: UUID())
        #expect(!result.clearedSpinner, "a stale completion must not clear the current item's spinner")
    }
}
