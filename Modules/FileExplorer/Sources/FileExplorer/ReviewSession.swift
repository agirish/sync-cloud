import Combine
import Foundation
import Sync

/// Owns the review session ACROSS `DifferencesView` mounts. The view is conditionally mounted
/// by the host (bottom tab, and an empty differences list unmounts it), so session state kept
/// in the view's `@State` would die on a tab peek or when an external change resolves the last
/// live difference mid-review. The host holds this store as `@StateObject` and keeps the view
/// mounted while `isReviewing`; a decision completing while the view happens to be unmounted
/// still lands here.
@MainActor
public final class ReviewSessionStore: ObservableObject {
    /// The active session; nil when not reviewing. Internal — hosts only ask `isReviewing`.
    @Published var session: ReviewSession? = nil
    /// True while the current item's copy/move runs. Lives here, not in view `@State`, so a
    /// remount mid-operation can't re-enable the decision buttons and double-fire the item.
    @Published var isActing: Bool = false

    public init() {}

    /// Whether a review session is active — the host's mount condition.
    public var isReviewing: Bool { session != nil }

    /// The ONE way an outcome lands in the store. Id-addressed (the user may have jumped rows
    /// while a copy ran) and token-guarded: `syncFile` is an unbounded await, and "a session
    /// exists" is not enough — the user can exit review and start a NEW session over the same
    /// un-rescanned set (identical difference ids) before the old outcome arrives, and a
    /// membership check alone would let the stale outcome advance the new session. The token
    /// must be captured from the session the decision was made against, BEFORE the await.
    /// - Returns: Whether the outcome was applied (so the caller can check for completion).
    @discardableResult
    func apply(_ outcome: ReviewSession.Outcome, for id: UUID, token: UUID) -> Bool {
        guard var current = session, current.sessionToken == token else { return false }
        current.record(outcome, for: id)
        session = current
        return true
    }

    /// Records a per-item Verify verdict; same token guard as `apply` — a verdict hashed under
    /// a torn-down session must not label an item in its replacement.
    @discardableResult
    func recordVerdict(_ verdict: ReviewSession.VerifyVerdict, for id: UUID, token: UUID) -> Bool {
        guard var current = session, current.sessionToken == token else { return false }
        current.recordVerdict(verdict, for: id)
        session = current
        return true
    }

    /// Runs a decision that returns from an unbounded await and lands its outcome in the session
    /// it was STARTED against.
    ///
    /// The token is read HERE, synchronously, before `perform` is even started — that ordering
    /// IS the fix. Reading `session?.sessionToken` after the await instead would read whatever
    /// session exists when the copy returns, and since exiting review and restarting over the
    /// same un-rescanned set yields a session with the SAME difference ids, `apply`'s token check
    /// would compare the replacement against itself and pass. Every guard downstream stays
    /// correct while the bug walks straight through, which is why the sequence lives here rather
    /// than being open-coded in the view.
    ///
    /// `isActing` is cleared before the outcome is applied, matching the order the decision
    /// buttons expect (the card re-enables, then the queue advances).
    /// - Returns: Whether the outcome was applied — false once the session was replaced or torn
    ///   down, so the caller knows not to treat this as a completed step.
    @discardableResult
    func decide(for id: UUID, perform: () async -> ReviewSession.Outcome) async -> Bool {
        guard let token = session?.sessionToken else { return false }
        let outcome = await perform()
        isActing = false
        return apply(outcome, for: id, token: token)
    }

    /// Ends the session immediately. For the host's comparison-changing events (pane swap,
    /// provider switch, root edit): the frozen queue's paths and directions describe the OLD
    /// comparison, and the card would relabel them against the new pane names — backwards.
    /// `isActing` is left alone: an in-flight copy's completion clears it, and its outcome
    /// write is dropped by the host's session guard.
    public func endSession() {
        session = nil
    }
}

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

    /// The session's identity. Two sessions over the same un-rescanned differences are
    /// content-identical (same queue, same ids), so async work parked across an exit + restart
    /// can't tell them apart by membership — outcomes and verdicts are guarded on this token
    /// instead (see `ReviewSessionStore.apply`). Part of the synthesized `==` deliberately:
    /// value copies of one session share the token, and distinct sessions are distinct.
    let sessionToken = UUID()
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

    /// Records the outcome for the given item. Id-addressed, not cursor-addressed: a copy's
    /// outcome lands asynchronously, and the user may have jumped the cursor elsewhere while it
    /// ran — the decision must stamp the item that was synced, never whatever is now current.
    /// The cursor advances only when the decided item IS the current one — scanning forward,
    /// then wrapping to the earliest undecided (a jump can leave undecided islands behind).
    /// No-op for unknown ids and for items already decided (nothing may double-record).
    mutating func record(_ outcome: Outcome, for id: UUID) {
        guard outcomes[id] == nil, queue.contains(where: { $0.id == id }) else { return }
        outcomes[id] = outcome
        if current?.id == id {
            advanceToNextPending(after: currentIndex)
        }
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

    /// Membership-guarded like `record`: a verdict for an id outside the queue (stale after a
    /// rescan regenerated row UUIDs) must not accrete into the verdicts map.
    mutating func recordVerdict(_ verdict: VerifyVerdict, for id: UUID) {
        guard queue.contains(where: { $0.id == id }) else { return }
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
