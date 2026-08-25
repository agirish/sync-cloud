import Events
import Foundation

/// **How much a single walk is allowed to read**, shared across the fan-out that performs it.
///
/// Hoisted out of `buildTree` so a CALLER can own one and ask afterwards whether it was spent.
/// That question is the whole basis of the size guard on the whole-tree passes: the storage lens
/// and the Organize scans cannot take a budget — they total sizes and group duplicates, where a
/// truncated tree is a wrong ANSWER rather than a partial view — but they can run a budgeted walk
/// as a PROBE. Under the budget, the probe IS the tree and nothing was wasted; over it, the walk
/// stopped early and the caller now knows the tree is too big to analyse without asking first.
extension FileSyncManager {

    /// **How many nodes this walk may produce before it stops descending.**
    ///
    /// A shared reference across the fan-out's branch copies of the (value-type)
    /// builder, for `UnreadableListingLog`'s reason: the branches run concurrently and
    /// the decision has to be one decision. `nil` means unbounded, which is what every
    /// whole-tree analysis needs (duplicates, the storage lens, the filing taxonomy) —
    /// a budget there would silently under-report rather than merely under-display.
    ///
    /// The overshoot is deliberate and bounded: exhaustion is checked before a
    /// directory is listed, so subtrees already in flight finish the level they are on.
    /// Charging is the listing's size, not the nodes actually built, because the
    /// listing is what the walk pays for (see `buildTree`'s note that enumeration is
    /// the floor) and it is known before the children are.
    ///
    /// **The walk root's own listing is never charged**, because it happens in `buildTree` before
    /// the recursion starts. So a folder with an enormous number of DIRECT children is not bounded
    /// by this at all. Left as it is: that is one directory enumeration rather than a traversal, so
    /// it is bounded by the filesystem instead — but the name "node budget" oversells it, and
    /// `aTreeExactlyAtTheBudgetIsNotTruncated` is where this was discovered.
    final class NodeBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var stoppedADescent = false
        private var announced = false
        /// The limit, kept for the log line and for the caller's pre-flight report.
        let limit: Int
        /// What to say the first time this budget stops a descent, or `nil` to say nothing.
        ///
        /// `nil` is what a PROBE passes. A probe's whole job is to find out whether the tree is too
        /// big, and it hands that finding to its caller to act on — a warning in the log saying the
        /// walk stopped would be describing the probe working correctly.
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

        /// **Whether the budget actually stopped the walk**, which is not the same question as
        /// `isExhausted` and is the one a probe asks.
        ///
        /// A tree holding exactly `limit` entries spends the budget to zero and is nonetheless
        /// complete — there was no next directory for the exhaustion to stop. Reading `isExhausted`
        /// as "truncated" would report that tree as too big to analyse, which is the one case where
        /// being wrong is least excusable: it is the boundary, so it is what anyone tuning the
        /// number will land on.
        var didStopADescent: Bool {
            lock.lock(); defer { lock.unlock() }
            return stoppedADescent
        }

        func charge(_ count: Int) {
            lock.lock(); remaining -= count; lock.unlock()
        }

        /// Records that a descent was refused, and announces it once if this budget announces.
        ///
        /// Once, because a walk that ran out has thousands more directories behind it and the
        /// useful fact is that the tree is partial, not which particular folder was unlucky.
        func noteStopped(_ path: String) {
            lock.lock()
            stoppedADescent = true
            let first = !announced
            announced = true
            let note = self.note
            lock.unlock()
            guard first, let note else { return }
            let limit = self.limit
            Task { @MainActor in
                Logger.shared.warning("\(note) (stopped at \(limit) entries, first at “\(path)”)")
            }
        }
    }
}
