import Combine
import Foundation
import Sync

/// Owns the review session across `DifferencesView` mounts. The host mounts that view
/// conditionally (bottom tab; an empty differences list unmounts it), so session state in its
/// `@State` would die on a tab peek or when an external change resolves the last difference.
/// The host holds this as `@StateObject` and keeps the view mounted while `isReviewing`; a
/// decision completing while the view is unmounted still lands here.
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

    /// The one way an outcome lands in the store. Id-addressed, since the user may have jumped
    /// rows while a copy ran, and token-guarded: during `syncFile`'s unbounded await the user can
    /// exit and start a new session over the same un-rescanned set, with identical ids, so a
    /// membership check alone would let a stale outcome advance it. Capture the token from the
    /// session decided against, before the await.
    /// - Returns: Whether the outcome was applied (so the caller can check for completion).
    @discardableResult
    func apply(_ outcome: ReviewSession.Outcome, for id: UUID, token: UUID) -> Bool {
        guard var current = session, current.sessionToken == token else { return false }
        current.record(outcome, for: id)
        session = current
        return true
    }

    /// Records a per-item Verify verdict, with `apply`'s token guard: a verdict hashed under a
    /// torn-down session must not label an item in its replacement.
    @discardableResult
    func recordVerdict(_ verdict: ReviewSession.VerifyVerdict, for id: UUID, token: UUID) -> Bool {
        guard var current = session, current.sessionToken == token else { return false }
        current.recordVerdict(verdict, for: id)
        session = current
        return true
    }

    /// Runs a decision that returns from an unbounded await and lands its outcome in the session
    /// it was started against.
    ///
    /// **`token` must be the caller's**, captured in the same synchronous slot that raised
    /// `isActing`, never re-read here. `reviewPrimary` enters a `Task` before calling this, so a
    /// teardown and fresh `startReview` in that hop would hand the new session's token to the old
    /// session's item, and with identical ids `apply`'s check would pass and skip an undecided
    /// item.
    ///
    /// `isActing` is cleared by `defer`, so it comes down on every exit, including the early
    /// return when the session was torn down in that hop (pane swap, provider switch, root edit,
    /// Esc). No copy started then, so nothing else would clear it, and `startReview` doesn't, so
    /// the next review would open with its buttons disabled. Order relative to `apply` doesn't
    /// matter: both `@Published` writes land in one synchronous main-actor run.
    /// - Returns: Whether the outcome was applied — false once the session was replaced or torn
    ///   down, so the caller knows not to treat this as a completed step.
    @discardableResult
    func decide(for id: UUID, token: UUID, perform: () async -> ReviewSession.Outcome) async -> Bool {
        defer { isActing = false }
        guard session != nil else { return false }
        let outcome = await perform()
        return apply(outcome, for: id, token: token)
    }

    /// Ends the session immediately, for the host's comparison-changing events (pane swap,
    /// provider switch, root edit): the frozen queue describes the old comparison, and the card
    /// would label it against the new pane names. `isActing` is left alone: an in-flight copy's
    /// completion clears it, and its outcome is dropped by the session guard.
    public func endSession() {
        session = nil
    }
}

/// State machine for the inline guided review (the Differences header's "Review…" mode):
/// a queue of differences frozen when the session starts, a cursor, and per-item outcomes.
/// A pure value type held by ``ReviewSessionStore``, so every transition is unit-testable.
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
        /// A side couldn't be hashed (unreadable, not downloaded, vanished).
        case unverifiable
    }

    /// The session's identity. Two sessions over the same un-rescanned differences have the same
    /// queue and ids, so async work spanning an exit and restart is guarded on this token instead
    /// (see `ReviewSessionStore.apply`). Part of the synthesized `==` on purpose: copies of one
    /// session share it, and distinct sessions differ.
    let sessionToken = UUID()
    /// Whether the session moves items instead of copying (move modifier held at entry).
    let isMove: Bool
    /// The frozen review queue, in the table order visible when the session started.
    let queue: [FileDifference]
    /// The Path column's anchor (the compared folder's name), frozen with the queue it labels.
    /// The live `lastScanRootNames` would label these rows with whatever the panes scan next,
    /// where the user is deciding copies. nil renders bare parents and "Top level".
    let pathRootName: String?
    private(set) var currentIndex: Int = 0
    private(set) var outcomes: [UUID: Outcome] = [:]
    private(set) var verdicts: [UUID: VerifyVerdict] = [:]

    /// nil when there is nothing to review. `pathRootName` has no default on purpose: every
    /// caller must decide what anchor travels with the queue.
    init?(queue: [FileDifference], isMove: Bool, pathRootName: String?) {
        guard !queue.isEmpty else { return nil }
        self.queue = queue
        self.pathRootName = pathRootName
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

    /// Records the outcome for the given item. Id-addressed, not cursor-addressed: the outcome
    /// lands asynchronously, and must stamp the item synced, not whatever is current now. The
    /// cursor advances only when the decided item is current: forward, then wrapping to the
    /// earliest undecided. No-op for unknown or already-decided ids.
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
