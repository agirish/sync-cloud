import Foundation
import Sync

/// Remembers which paths came back dataless, so a row scrolling back into view does not re-stat.
///
/// The cloud badge is resolved lazily, per row, by one `lstat` off the main actor — deliberately, so
/// a 40,000-node tree pays nothing for rows nobody looks at. What it did not have was any memory:
/// `FileRowView`'s keyed `.task` re-runs every time a row is realized, and a `List` realizes and
/// discards rows continuously while scrolling, so walking up and down the same folder re-statted the
/// same paths indefinitely — each one costing a detached `Task`, two actor hops and a syscall.
///
/// **Why not fold the flag into the tree walk instead.** It was the obvious alternative: the walk
/// already stats every node, so it could carry `isCloudOnly` on `FileNode` and the row would read a
/// `Bool`. But `resourceValues` does not surface the `SF_DATALESS` flag, so the walk would need a
/// SECOND syscall per node — 40,000 extra `lstat`s against a cloud provider's synthetic filesystem,
/// paid up front, on the path that decides how long "show me this folder" takes. That trades scroll
/// cost for load cost, and both are things the panes are being asked to do better. A memo keeps the
/// laziness and removes only the repetition.
///
/// **Staleness.** Entries are dropped wholesale when a pane republishes its tree, which is the same
/// moment every other fact on the row (size, date, existence) is refreshed — so the badge is exactly
/// as current as the rest of the row, and no more. A materializing download is handled separately
/// and precisely, by `forget(_:)`, because that one the app started and is watching.
@MainActor
enum CloudOnlyBadgeCache {
    private static var known: [String: Bool] = [:]

    /// Bound on the memo. Cleared wholesale at the cap rather than evicted one entry at a time:
    /// that is O(1) and costs at most one repeated `lstat` per path afterwards, which is the same
    /// trade `DetailsMetadataCache.warnedPaths` makes. Sized well above any plausible number of
    /// rows scrolled through between two republishes.
    private static let capacity = 8192

    /// The remembered answer for `path`, or nil if it has not been statted since the last republish.
    static func cached(_ path: String) -> Bool? { known[path] }

    static func record(_ path: String, isCloudOnly: Bool) {
        if known.count >= capacity { known.removeAll(keepingCapacity: true) }
        known[path] = isCloudOnly
    }

    /// Drops one path's answer — used when a download the app requested has landed, so the next
    /// realization of that row asks the filesystem again instead of serving the pre-download answer.
    static func forget(_ path: String) { known[path] = nil }

    /// Drops everything. Called when a pane republishes its tree.
    static func clear() { known.removeAll(keepingCapacity: true) }

    /// The stat itself, memoized. Runs off the main actor: `lstat` is cheap but it is still I/O, and
    /// against an unmounted or slow provider "cheap" is not a promise the main thread can rely on.
    static func isCloudOnly(atPath path: String) async -> Bool {
        if let hit = cached(path) { return hit }
        let answer = await Task.detached { MaterializationStatus.isCloudOnly(atPath: path) }.value
        record(path, isCloudOnly: answer)
        return answer
    }
}
