import Testing
import Foundation
import Sync
@testable import FileExplorer

/// A queue item for the review tests. One helper for both suites in this file.
private func diff(
    _ relativePath: String,
    id: UUID = UUID(),
    type: FileDifference.DifferenceType = .missingOnRight,
    action: FileDifference.SyncAction = .copyToRight
) -> FileDifference {
    FileDifference(
        id: id,
        relativePath: relativePath,
        leftItemPath: "/l/\(relativePath)",
        rightItemPath: "/r/\(relativePath)",
        type: type,
        action: action,
        description: "test"
    )
}

/// Coverage for the guided-review state machine: cursor advancement (including the wrap that
/// jumping around creates), outcome bookkeeping, jump rules, and the header's counts.
@Suite struct ReviewSessionTests {

    /// Decides the CURRENT item — the common path a Copy/Skip on the card takes.
    private func decide(_ session: inout ReviewSession, _ outcome: ReviewSession.Outcome) throws {
        let id = try #require(session.current).id
        session.record(outcome, for: id)
    }

    @Test func emptyQueueRefusesToStart() {
        #expect(ReviewSession(queue: [], isMove: false) == nil)
    }

    @Test func startsAtFirstItemWithNothingDecided() throws {
        let queue = [diff("a"), diff("b")]
        let session = try #require(ReviewSession(queue: queue, isMove: false))
        #expect(session.current?.id == queue[0].id)
        #expect(session.position == 1)
        #expect(session.total == 2)
        #expect(!session.isComplete)
        #expect(session.pending.map(\.id) == queue.map(\.id))
    }

    @Test func recordAdvancesInQueueOrder() throws {
        let queue = [diff("a"), diff("b"), diff("c")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        try decide(&session, .copied)
        #expect(session.current?.id == queue[1].id)
        #expect(session.outcome(for: queue[0].id) == .copied)
        #expect(session.position == 2)
        try decide(&session, .skipped)
        #expect(session.current?.id == queue[2].id)
        #expect(session.copiedCount == 1)
        #expect(session.skippedCount == 1)
    }

    @Test func completingEveryItemEndsTheSession() throws {
        let queue = [diff("a"), diff("b")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        try decide(&session, .copied)
        try decide(&session, .copied)
        #expect(session.isComplete)
        #expect(session.current == nil)
        #expect(session.pending.isEmpty)
        // Position counts decisions, capped at the total — never "3 of 2".
        #expect(session.position == 2)
    }

    @Test func jumpMovesOnlyToPendingItems() throws {
        let queue = [diff("a"), diff("b"), diff("c")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        try decide(&session, .copied)

        // Jumping to the decided first item is refused; the cursor stays put.
        let jumpedToDecided = session.jump(to: queue[0].id)
        #expect(!jumpedToDecided)
        #expect(session.current?.id == queue[1].id)

        // Jumping to a pending later item works; so does an unknown id refusal.
        let jumpedToPending = session.jump(to: queue[2].id)
        #expect(jumpedToPending)
        #expect(session.current?.id == queue[2].id)
        let jumpedToUnknown = session.jump(to: UUID())
        #expect(!jumpedToUnknown)
    }

    @Test func advanceWrapsToUndecidedIslandsLeftByJumps() throws {
        let queue = [diff("a"), diff("b"), diff("c")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        // Jump straight to the last item and decide it: the cursor must wrap back to "a".
        session.jump(to: queue[2].id)
        try decide(&session, .copied)
        #expect(session.current?.id == queue[0].id)
        // Deciding "a" advances to "b" (skipping the already-decided "c").
        try decide(&session, .skipped)
        #expect(session.current?.id == queue[1].id)
        try decide(&session, .copied)
        #expect(session.isComplete)
    }

    @Test func doubleRecordAndUnknownIdsAreNoOps() throws {
        let queue = [diff("a"), diff("b")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        try decide(&session, .copied)
        let afterFirst = session

        // Re-deciding a decided item (an async decision landing twice) must not overwrite
        // the outcome or move the cursor.
        session.record(.skipped, for: queue[0].id)
        #expect(session == afterFirst)

        // An id from outside the queue (stale after a rescan) is refused.
        session.record(.copied, for: UUID())
        #expect(session == afterFirst)
    }

    @Test func recordForNonCurrentItemKeepsTheCursor() throws {
        let queue = [diff("a"), diff("b"), diff("c")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        // A copy of "a" is in flight when the user jumps to "c"; the copy's outcome lands late.
        session.jump(to: queue[2].id)
        session.record(.copied, for: queue[0].id)
        // The outcome stamped "a", not whatever is current — and the user wasn't yanked away.
        #expect(session.outcome(for: queue[0].id) == .copied)
        #expect(session.current?.id == queue[2].id)
        #expect(session.pending.map(\.id) == [queue[1].id, queue[2].id])
    }

    @Test func verdictsAreRecordedPerItem() throws {
        let queue = [diff("a"), diff("b")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        session.recordVerdict(.identical, for: queue[0].id)
        #expect(session.verdict(for: queue[0].id) == .identical)
        #expect(session.verdict(for: queue[1].id) == nil)
    }

    /// A verdict for an id outside the queue (stale after a rescan regenerated row UUIDs) is
    /// refused — same membership rule `record` enforces for outcomes.
    @Test func verdictForAnUnknownIdIsRefused() throws {
        let queue = [diff("a")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        session.recordVerdict(.identical, for: UUID())
        #expect(session.verdicts.isEmpty)
    }

    @Test func pendingPreservesQueueOrderAroundDecisions() throws {
        let queue = [diff("a"), diff("b"), diff("c")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        session.jump(to: queue[1].id)
        try decide(&session, .copied)
        #expect(session.pending.map(\.id) == [queue[0].id, queue[2].id])
    }
}

/// The host-owned store that carries a session across `DifferencesView` unmounts.
@MainActor
@Suite struct ReviewSessionStoreTests {

    @Test func isReviewingTracksTheSession() {
        let store = ReviewSessionStore()
        #expect(!store.isReviewing)
        store.session = ReviewSession(queue: [diff("a")], isMove: false)
        #expect(store.isReviewing)
        store.session = nil
        #expect(!store.isReviewing)
    }

    /// The A3 race: `syncFile` is an unbounded await, and exiting review + starting a NEW
    /// session over the same un-rescanned set keeps the SAME difference ids — so a membership
    /// check can't tell the sessions apart. The stale outcome must be dropped by the token
    /// guard, leaving the replacement session untouched.
    @Test func staleOutcomeAgainstAReplacedSessionIsDropped() throws {
        let store = ReviewSessionStore()
        let queue = [diff("a"), diff("b")]
        let old = try #require(ReviewSession(queue: queue, isMove: false))
        store.session = old
        let staleToken = old.sessionToken   // captured before the "await", as reviewPrimary does

        // Exit + restart over the SAME queue (identical ids), before the old outcome lands.
        let replacement = try #require(ReviewSession(queue: queue, isMove: false))
        store.session = replacement

        #expect(!store.apply(.copied, for: queue[0].id, token: staleToken))
        let session = try #require(store.session)
        #expect(session.outcome(for: queue[0].id) == nil, "the stale outcome must not advance the new session")
        #expect(session.current?.id == queue[0].id)
        #expect(session.sessionToken == replacement.sessionToken)
    }

    /// The counterpart: a LATE outcome for the STILL-CURRENT session applies normally — the
    /// token guard drops cross-session strays, not slow same-session copies.
    @Test func lateOutcomeForTheSameSessionStillApplies() throws {
        let store = ReviewSessionStore()
        let queue = [diff("a"), diff("b")]
        let session = try #require(ReviewSession(queue: queue, isMove: false))
        store.session = session

        #expect(store.apply(.copied, for: queue[0].id, token: session.sessionToken))
        #expect(store.session?.outcome(for: queue[0].id) == .copied)
        #expect(store.session?.current?.id == queue[1].id)
    }

    /// Verdicts take the same guard: a hash finishing after exit + restart must not label an
    /// item in the replacement session.
    @Test func staleVerdictAgainstAReplacedSessionIsDropped() throws {
        let store = ReviewSessionStore()
        let queue = [diff("a")]
        let old = try #require(ReviewSession(queue: queue, isMove: false))
        store.session = old
        let staleToken = old.sessionToken

        store.session = try #require(ReviewSession(queue: queue, isMove: false))

        #expect(!store.recordVerdict(.identical, for: queue[0].id, token: staleToken))
        #expect(store.session?.verdict(for: queue[0].id) == nil)

        // And with the live token it lands.
        let liveToken = try #require(store.session?.sessionToken)
        #expect(store.recordVerdict(.identical, for: queue[0].id, token: liveToken))
        #expect(store.session?.verdict(for: queue[0].id) == .identical)
    }

    /// The A3 defect itself, at the seam that owns it. The store's token check is only as good
    /// as WHEN the token was read: reading it after the decision's await (what `reviewPrimary`
    /// used to do) reads the session that exists on RETURN, so an exit + restart over the same
    /// un-rescanned set — same difference ids — would have the replacement's token compared
    /// against itself and pass. `decide` reads it before `perform` starts, so the outcome is
    /// dropped. Every other test in this file stays green if that capture moves; this one does
    /// not.
    @Test func decideCapturesTheTokenBeforeTheAwaitNotAfter() async throws {
        let store = ReviewSessionStore()
        let queue = [diff("a"), diff("b")]
        store.session = try #require(ReviewSession(queue: queue, isMove: false))
        store.isActing = true

        let replacement = try #require(ReviewSession(queue: queue, isMove: false))
        let applied = await store.decide(for: queue[0].id) {
            // Exit + restart lands WHILE the copy is out — the window the token exists for.
            store.session = replacement
            await Task.yield()
            return .copied
        }

        #expect(!applied, "an outcome from the torn-down session must not advance its replacement")
        let session = try #require(store.session)
        #expect(session.sessionToken == replacement.sessionToken)
        #expect(session.outcome(for: queue[0].id) == nil)
        #expect(session.current?.id == queue[0].id)
        // Cleared regardless: the card must re-enable even when the outcome is dropped.
        #expect(!store.isActing)
    }

    /// The counterpart: an ordinary slow decision on the still-live session applies and advances.
    @Test func decideAppliesAnOutcomeToTheSessionItStartedUnder() async throws {
        let store = ReviewSessionStore()
        let queue = [diff("a"), diff("b")]
        store.session = try #require(ReviewSession(queue: queue, isMove: false))
        store.isActing = true

        let applied = await store.decide(for: queue[0].id) {
            await Task.yield()
            return .copied
        }

        #expect(applied)
        #expect(store.session?.outcome(for: queue[0].id) == .copied)
        #expect(store.session?.current?.id == queue[1].id)
        #expect(!store.isActing)
    }

    /// No session at all (Exit before the decision even started): nothing to decide against, and
    /// the acting flag must come back down anyway.
    ///
    /// `isActing` is raised deliberately here because that is the only state this can be reached
    /// in: `reviewPrimary` sets it synchronously and then hops through a `Task`, so a teardown
    /// inside that hop — a pane swap, provider switch, root edit, or Esc — arrives with the flag
    /// already up and no copy ever started. Leaving it up latches PERMANENTLY: `endSession` defers
    /// clearing to an in-flight copy that does not exist here, and `startReview` does not reset it,
    /// so the next review opens with Copy, Skip and Verify disabled until the app is relaunched.
    /// `decideCapturesTheTokenBeforeTheAwaitNotAfter` already pins the same invariant for the
    /// session-REPLACED exit; this is the session-nil one.
    @Test func decideWithNoSessionClearsTheActingFlag() async {
        let store = ReviewSessionStore()
        store.isActing = true
        var ran = false
        let applied = await store.decide(for: UUID()) {
            ran = true
            return .copied
        }
        #expect(!applied)
        #expect(!ran)
        #expect(!store.isActing,
                "isActing stayed up with no session and no copy — the next review would open dead")
    }

    /// A decision arriving after Exit tore the session down (no replacement) stays dropped.
    @Test func outcomeAfterTeardownIsDropped() throws {
        let store = ReviewSessionStore()
        let queue = [diff("a")]
        let session = try #require(ReviewSession(queue: queue, isMove: false))
        store.session = session
        store.endSession()

        #expect(!store.apply(.copied, for: queue[0].id, token: session.sessionToken))
        #expect(store.session == nil)
    }
}
