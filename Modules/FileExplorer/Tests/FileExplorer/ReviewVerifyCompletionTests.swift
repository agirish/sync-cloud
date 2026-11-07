import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Pins what a finished per-item Verify may write back to the review card
/// (`ReviewCardView.applyVerifyCompletion`): the verdict always goes out (session-guarded
/// downstream by `ReviewSessionStore.recordVerdict`), while the spinner write belongs only to a
/// completion whose card hasn't advanced.
@MainActor
@Suite struct ReviewVerifyCompletionTests {

    /// Runs a completion and reports what it wrote.
    private func run(sameContent: Bool?, stopped: Bool = false, liveToken: UUID, startedToken: UUID)
        -> (verdicts: [ReviewSession.VerifyVerdict], clearedSpinner: Bool) {
        var verdicts: [ReviewSession.VerifyVerdict] = []
        var cleared = false
        ReviewCardView.applyVerifyCompletion(
            sameContent: sameContent,
            stopped: stopped,
            liveToken: liveToken,
            startedToken: startedToken,
            report: { verdicts.append($0) },
            clearSpinner: { cleared = true }
        )
        return (verdicts, cleared)
    }

    /// A verify stopped because the card left Review answers nil, and that nil is about the stop,
    /// not the files: no verdict goes out, since `.unverifiable` would tell the user a readable
    /// pair couldn't be checked. The unstopped nil beside it is the control.
    @Test func aStoppedVerifyReportsNoVerdict() {
        let token = UUID()
        #expect(run(sameContent: nil, stopped: true, liveToken: token, startedToken: token).verdicts.isEmpty)
        #expect(run(sameContent: nil, liveToken: token, startedToken: token).verdicts == [.unverifiable])
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

    /// What this guard must not cause. Verify a large pair, click another row, click back:
    /// `.task(id: item.id)` has re-minted the token twice, so the completion's token is stale
    /// though its verdict is a real hash of a real item. Dropping it would leave no spinner and no
    /// answer, so the verdict is still reported (its session token decides whether it lands).
    @Test func aCompletionFromAnAdvancedCardStillReportsItsVerdict() {
        let result = run(sameContent: false, liveToken: UUID(), startedToken: UUID())
        #expect(result.verdicts == [.differed], "a legitimate verdict must not be discarded by the spinner guard")
    }

    /// What the token guard exists for: a large pair returning after the card advanced must not
    /// clear the spinner of the item now on screen. `.task(id:)` already reset that flag for the
    /// new item, whose own verify may be running.
    @Test func aCompletionFromAnAdvancedCardDoesNotTouchTheSpinner() {
        let result = run(sameContent: true, liveToken: UUID(), startedToken: UUID())
        #expect(!result.clearedSpinner, "a stale completion must not clear the current item's spinner")
    }
}
