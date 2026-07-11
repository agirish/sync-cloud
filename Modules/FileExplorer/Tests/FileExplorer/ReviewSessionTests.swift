import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Coverage for the guided-review state machine: cursor advancement (including the wrap that
/// jumping around creates), outcome bookkeeping, jump rules, and the header's counts.
@Suite struct ReviewSessionTests {

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
        store.session = ReviewSession(
            queue: [FileDifference(
                relativePath: "a", leftItemPath: "/l/a", rightItemPath: "/r/a",
                type: .missingOnRight, action: .copyToRight, description: "test")],
            isMove: false)
        #expect(store.isReviewing)
        store.session = nil
        #expect(!store.isReviewing)
    }
}
