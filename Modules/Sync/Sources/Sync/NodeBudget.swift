import Events
import Foundation

/// How much a single walk may read, shared across the fan-out that performs it. A caller owns one
/// and asks afterwards whether it was spent. The whole-tree passes (storage lens, Organize) can't
/// take a budget, since a truncated tree gives a wrong total, but they run a budgeted walk as a
/// probe: under budget the probe is the tree; over it, the tree is too big to analyse unasked.
extension FileSyncManager {

    /// How many nodes this walk may produce before it stops descending. One shared reference across
    /// the builder's concurrent branch copies, so the decision is one decision. No budget (`nil`)
    /// for whole-tree analyses, where a budget would silently under-report.
    ///
    /// The overshoot is bounded: exhaustion is checked before a directory is listed, so subtrees in
    /// flight finish their level. Each listing is charged its size, since the listing is what the
    /// walk pays for and it is known before the children are.
    ///
    /// **The walk root's own listing is never charged** (it runs in `buildTree` before the
    /// recursion), so a folder's direct children aren't bounded by this, only by the filesystem.
    final class NodeBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var stoppedADescent = false
        private var announced = false
        /// The limit, kept for the log line and for the caller's pre-flight report.
        let limit: Int
        /// What to log the first time this budget stops a descent, or `nil` for nothing. A probe
        /// passes `nil`: its caller acts on the finding, and a warning would describe it working.
        private let note: String?

        init(_ limit: Int, note: String? = nil) {
            self.remaining = limit
            self.limit = limit
            self.note = note
        }

        var isExhausted: Bool {
            lock.lock(); defer { lock.unlock() }
            return remaining <= 0
        }

        /// Whether the budget actually stopped the walk: the question a probe asks, not
        /// `isExhausted`. A tree of exactly `limit` entries spends the budget to zero yet is
        /// complete, and reading `isExhausted` would call it too big.
        var didStopADescent: Bool {
            lock.lock(); defer { lock.unlock() }
            return stoppedADescent
        }

        func charge(_ count: Int) {
            lock.lock(); remaining -= count; lock.unlock()
        }

        /// Records that a descent was refused, and announces it once if this budget announces:
        /// the useful fact is that the tree is partial, not which folder was unlucky.
        func noteStopped(_ path: String) {
            lock.lock()
            stoppedADescent = true
            let first = !announced
            announced = true
            let note = self.note
            lock.unlock()
            guard first, let note else { return }
            let limit = self.limit
            Logger.shared.info("\(note) (stopped at \(limit) entries, first at “\(path)”)")
        }
    }
}
