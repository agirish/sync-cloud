import Foundation
import Sync

/// Remembers which paths sit outside every cloud folder, so a row that scrolls back into view does
/// not re-walk the provider list.
///
/// The mirror of `CloudOnlyBadgeCache`, one shelf cheaper. Both memo a per-row badge answer; the
/// difference is what an answer costs to get and what makes one go stale.
///
/// **The answer is free to compute and still worth memoizing.** `FileLocation.outsideEveryCloudFolder`
/// is pure string math — no syscall, unlike the ☁ badge's detached `lstat` — but it is asked
/// *eagerly*, on every visible row of every render pass (the shape that earned
/// `RiskyNameBadgeCache` its memo), and each ask lowercases the row's path and prefix-compares it
/// against every discovered root. The path comes from `URL.lastPathComponent` lineage, so it is a
/// string lazily bridged from `NSString`, and `lowercased()` on one of those takes the ObjC slow
/// path — the same reason the risky-name memo's real cost model is its bottom row, not its top.
///
/// **What DOES go stale here, and what the memo is keyed on.** An entry is a fact about a path and
/// the *source list* — add a folder source, remove a provider, re-point one's Location, refresh
/// discovery, and yesterday's answer is about a world that no longer exists. That is the shape of
/// `4cae0471`'s "finding outliving the provider", so it is not managed with a hand-maintained
/// generation counter bumped at each call site: the table holds the `FileLocation.Coverage` its
/// answers were computed under and drops them wholesale the moment a different one is handed in.
/// One forgotten bump cannot happen because there is nothing to bump — the same trade
/// `PaneActionDelegate.ignoreStateToken` makes, and `Coverage` is `Equatable` precisely so it can
/// be made.
///
/// A provider RENAME moves `Coverage` too (the display name rides on `CloudRoot`), which
/// invalidates more than it strictly must — a rename cannot change containment. That is deliberate
/// over-invalidation: one comparison, one rebuild of a lazy table, and no second notion of "the
/// part of the source list that matters" to keep in step with the first.
@MainActor
public enum HomeOnlyBadgeCache {
    /// The one table every pane shares.
    ///
    /// In a `Table` rather than in statics for the reason `CloudOnlyBadgeCache`'s is: the
    /// invalidation cannot be tested any other way. Proving the wipe means actually tripping it,
    /// and tripping it on the shared table drops the entries every suite running in PARALLEL is
    /// asserting on.
    private static let table = Table()

    /// Whether `path` sits inside no cloud source's folder, under `coverage` — see
    /// `Table.isOutsideEveryCloudFolder(path:coverage:)`.
    public static func isOutsideEveryCloudFolder(
        path: String,
        coverage: FileLocation.Coverage
    ) -> Bool {
        table.isOutsideEveryCloudFolder(path: path, coverage: coverage)
    }

    /// Drops every entry. Only the tests need it — production invalidates by handing in a different
    /// `Coverage` — but a memo that outlived a test case would let one case's answers decide
    /// another's. Compiled in rather than `#if DEBUG`-gated: a DEBUG-only seam could not be
    /// asserted against under `swift test -c release` — see `RiskyNameBadgeCache`.
    static func resetForTesting() { table.resetForTesting() }
}

@MainActor
extension HomeOnlyBadgeCache {

/// The memo's storage and its one invalidation rule.
///
/// A class with an injectable `capacity`, and not private, purely so the rules can be pinned
/// without writing the process-wide table — see `HomeOnlyBadgeCache.table`. The app makes exactly
/// one, at the default capacity.
///
/// `@MainActor` on the enclosing extension does NOT reach a nested type, so it is stated here.
@MainActor
final class Table {
    private var known: [String: Bool] = [:]
    /// The source list every entry in `known` was computed under. nil only before the first ask.
    private var coverage: FileLocation.Coverage?

    /// Bound on the memo. Cleared wholesale at the cap rather than evicted one entry at a time:
    /// O(1), and the cost of being wrong is re-running some string math for the rows still on
    /// screen. Sized like `CloudOnlyBadgeCache`'s, well above the number of distinct paths a
    /// session scrolls past between two source-list changes.
    private let capacity: Int

    init(capacity: Int = 8192) {
        self.capacity = capacity
    }

    /// The remembered answer for `path`, or nil if it has not been computed under the current
    /// coverage. Reports staleness as a miss, not as a stale hit.
    func cached(_ path: String, coverage: FileLocation.Coverage) -> Bool? {
        guard self.coverage == coverage else { return nil }
        return known[path]
    }

    /// Whether `path` sits inside no cloud source's folder.
    ///
    /// **The invalidation is the first thing that happens, before the lookup.** Checking it after
    /// serving a hit would be no check at all: the hit is exactly the stale answer being guarded
    /// against. Nothing suspends in here — the whole computation is synchronous string math — so
    /// unlike `CloudOnlyBadgeCache` there is no in-flight-answer race to hold a generation counter
    /// for, and no way for an answer to be superseded between being computed and being written.
    func isOutsideEveryCloudFolder(path: String, coverage: FileLocation.Coverage) -> Bool {
        if self.coverage != coverage {
            known.removeAll(keepingCapacity: true)
            self.coverage = coverage
        }
        if let hit = known[path] { return hit }
        let answer = FileLocation.outsideEveryCloudFolder(path: path, in: coverage)
        if known.count >= capacity { known.removeAll(keepingCapacity: true) }
        known[path] = answer
        return answer
    }

    /// Compiled in rather than `#if DEBUG`-gated for the same reason as the static
    /// `HomeOnlyBadgeCache.resetForTesting()` above.
    func resetForTesting() {
        known.removeAll()
        coverage = nil
    }
}
}
