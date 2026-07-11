import Foundation
import Sync

/// State machine for the inline guided review (the Differences header's "Review…" mode):
/// a queue of differences frozen when the session starts, a cursor, and per-item outcomes.
/// Pure value type owned by the view as `@State` — every transition is unit-testable.
///
/// The queue is a snapshot on purpose: a successful sync removes its row from the live
/// `differences` list, but the review table keeps showing every queued item with its outcome
/// badge, so the session doubles as a receipt of what happened.
struct ReviewSession: Equatable {
    /// What happened to a queue item during this session.
    enum Outcome: Equatable {
        /// `syncFile` resolved the difference (copied, moved, or keep-both'd).
        case copied
        /// The user skipped it, or the sync came back unresolved (collision Skip, failure —
        /// both of which already told the user via their own prompt/alert).
        case skipped
    }

    /// Result of the card's per-item content verification.
    enum VerifyVerdict: Equatable {
        case identical
        case differed
        /// A side couldn't be hashed (unreadable, too large, vanished).
        case unverifiable
    }

    /// Whether the session moves items instead of copying (move modifier held at entry).
    let isMove: Bool
    /// The frozen review queue, in the table order visible when the session started.
    let queue: [FileDifference]
    private(set) var currentIndex: Int = 0
    private(set) var outcomes: [UUID: Outcome] = [:]
    private(set) var verdicts: [UUID: VerifyVerdict] = [:]

    /// nil when there is nothing to review.
    init?(queue: [FileDifference], isMove: Bool) {
        guard !queue.isEmpty else { return nil }
        self.queue = queue
        self.isMove = isMove
    }

    /// The item under review; nil once every item has an outcome.
    var current: FileDifference? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var isComplete: Bool { outcomes.count == queue.count }
    var total: Int { queue.count }

    /// 1-based position for "Reviewing N of M": one past the decided count, capped at the total
    /// (jumping around can't inflate it — it counts decisions, not cursor moves).
    var position: Int { min(outcomes.count + 1, queue.count) }

    var copiedCount: Int { outcomes.values.lazy.filter { $0 == .copied }.count }
    var skippedCount: Int { outcomes.values.lazy.filter { $0 == .skipped }.count }

    /// Undecided items in queue order — the "Copy Remaining…" targets.
    var pending: [FileDifference] { queue.filter { outcomes[$0.id] == nil } }

    func outcome(for id: UUID) -> Outcome? { outcomes[id] }
    func verdict(for id: UUID) -> VerifyVerdict? { verdicts[id] }

    /// Records the outcome for the current item, then advances to the next undecided item —
    /// scanning forward first, then wrapping to the earliest undecided (a jump can leave
    /// undecided islands behind the cursor). No-op once complete.
    mutating func record(_ outcome: Outcome) {
        guard let current else { return }
        outcomes[current.id] = outcome
        advanceToNextPending(after: currentIndex)
    }

    /// Moves the cursor to a still-pending item (a review-table row click). Decided items are
    /// not revisitable — re-deciding one could double-copy.
    /// - Returns: Whether the jump happened.
    @discardableResult
    mutating func jump(to id: UUID) -> Bool {
        guard outcomes[id] == nil, let index = queue.firstIndex(where: { $0.id == id }) else {
            return false
        }
        currentIndex = index
        return true
    }

    mutating func recordVerdict(_ verdict: VerifyVerdict, for id: UUID) {
        verdicts[id] = verdict
    }

    private mutating func advanceToNextPending(after index: Int) {
        if let next = ((index + 1)..<queue.count).first(where: { outcomes[queue[$0].id] == nil }) {
            currentIndex = next
        } else if let wrapped = queue.indices.first(where: { outcomes[queue[$0].id] == nil }) {
            currentIndex = wrapped
        } else {
            currentIndex = queue.count
        }
    }
}
