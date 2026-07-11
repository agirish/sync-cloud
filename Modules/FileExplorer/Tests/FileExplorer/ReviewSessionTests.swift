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
        session.record(.copied)
        #expect(session.current?.id == queue[1].id)
        #expect(session.outcome(for: queue[0].id) == .copied)
        #expect(session.position == 2)
        session.record(.skipped)
        #expect(session.current?.id == queue[2].id)
        #expect(session.copiedCount == 1)
        #expect(session.skippedCount == 1)
    }

    @Test func completingEveryItemEndsTheSession() throws {
        let queue = [diff("a"), diff("b")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        session.record(.copied)
        session.record(.copied)
        #expect(session.isComplete)
        #expect(session.current == nil)
        #expect(session.pending.isEmpty)
        // Position counts decisions, capped at the total — never "3 of 2".
        #expect(session.position == 2)
    }

    @Test func jumpMovesOnlyToPendingItems() throws {
        let queue = [diff("a"), diff("b"), diff("c")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        session.record(.copied)

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
        session.record(.copied)
        #expect(session.current?.id == queue[0].id)
        // Deciding "a" advances to "b" (skipping the already-decided "c").
        session.record(.skipped)
        #expect(session.current?.id == queue[1].id)
        session.record(.copied)
        #expect(session.isComplete)
    }

    @Test func recordAfterCompletionIsANoOp() throws {
        let queue = [diff("a")]
        var session = try #require(ReviewSession(queue: queue, isMove: false))
        session.record(.copied)
        let finished = session
        session.record(.skipped)
        #expect(session == finished)
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
        session.record(.copied)
        #expect(session.pending.map(\.id) == [queue[0].id, queue[2].id])
    }
}
