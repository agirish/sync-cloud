import Foundation
import Sync

/// Remembers which paths came back dataless, so a row scrolling back into view doesn't re-stat.
///
/// The cloud badge is resolved lazily, per row, by one `lstat` off the main actor, so a 40,000-node
/// tree pays nothing for rows nobody looks at. But `FileRowView`'s keyed `.task` re-runs every time
/// a row is realized, and a `List` realizes and discards rows continuously while scrolling, so
/// without a memo the same paths would be re-statted indefinitely, each costing a detached `Task`,
/// two actor hops and a syscall.
///
/// Not folded into the tree walk: `resourceValues` doesn't surface `SF_DATALESS`, so the walk would
/// need a second syscall per node, 40,000 extra `lstat`s against a provider's synthetic filesystem
/// on the path that decides how long "show me this folder" takes. A memo keeps the laziness and
/// removes only the repetition.
///
/// Staleness: a pane's entries are dropped when it republishes its tree, the moment every other
/// fact on the row (size, date, existence) is refreshed, so the badge is as current as the rest of
/// the row. A materializing download is handled precisely, by `forget(_:)`, because the app
/// started it and is watching.
@MainActor
public enum CloudOnlyBadgeCache {
    /// The one table every pane shares.
    /// The one table every pane shares. The state lives in a `Table`, not in statics, so a test
    /// can exercise the rules on a table of its own (as `isCloudOnly`'s `stat` is injectable): the
    /// capacity wipe can only be proved by tripping it, and tripping the shared table would drop
    /// entries suites running in parallel assert on. Every static below forwards here unchanged.
    private static let table = Table()

    /// The remembered answer for `path`, or nil if it hasn't been statted since the last republish.
    /// Public for File ▸ Download, resolved on every `ContentView` body pass, which must not pay an
    /// `lstat` there: a selected row has been drawn, so its badge has already recorded the answer.
    public static func cached(_ path: String) -> Bool? { table.cached(path) }

    static func record(_ path: String, isCloudOnly: Bool) {
        table.record(path, isCloudOnly: isCloudOnly)
    }

    /// Drops one path's answer, when a download the app requested has landed, so the row's next
    /// realization asks the filesystem again instead of serving the pre-download answer.
    static func forget(_ path: String) { table.forget(path) }

    /// Drops every entry at or under `root` (`Table.clear(underRoot:)`).
    static func clear(underRoot root: String) { table.clear(underRoot: root) }

    /// The stat itself, memoized (`Table.isCloudOnly(atPath:stat:)`).
    static func isCloudOnly(
        atPath path: String,
        stat: @MainActor (String) async -> Bool? = { p in
            await Task.detached { MaterializationStatus.isCloudOnlyIfKnown(atPath: p) }.value
        }
    ) async -> Bool {
        await table.isCloudOnly(atPath: path, stat: stat)
    }
}

@MainActor
extension CloudOnlyBadgeCache {

/// The memo's storage and every rule that operates on it. A class with an injectable `capacity`,
/// and not private, so the rules can be pinned without writing the process-wide table
/// (`CloudOnlyBadgeCache.table`). The app makes one, at the default capacity.
///
/// `@MainActor` on the enclosing extension doesn't reach a nested type, so it is stated here: the
/// table is the memo's mutable state and every caller is already on the main actor.
@MainActor
final class Table {
    private var known: [String: Bool] = [:]

    /// Bumped by every invalidation: `clear(underRoot:)`, `forget`, and the wholesale wipe `record`
    /// performs when the table is full. A stat already in flight when one happens returns its answer
    /// to the caller but doesn't write it to the memo. An ordinary `record` doesn't bump (see
    /// `isCloudOnly(atPath:stat:)` for why, and for the finer check that covers what the counter
    /// can't).
    ///
    /// Without it, a republish landing mid-stat would clear the table and the resuming stat would
    /// write its pre-republish answer straight back, serving every later realization of that row
    /// until the next republish. `forget(_:)` is the sharper case: it is called because a download
    /// was requested, so the in-flight answer it races is the stale "still cloud-only" one. The same
    /// guard as `DetailsMetadataCache`'s ("last requested wins, not last to come back").
    private var generation = 0

    /// Bound on the memo. Cleared wholesale at the cap rather than evicted one entry at a time:
    /// O(1), and at most one repeated `lstat` per path afterwards, the trade
    /// `DetailsMetadataCache.warnedPaths` makes. Sized well above the rows anyone scrolls through
    /// between two republishes.
    private let capacity: Int

    init(capacity: Int = 8192) {
        self.capacity = capacity
    }

    /// The remembered answer for `path`, or nil if it hasn't been statted since the last republish.
    func cached(_ path: String) -> Bool? { known[path] }

    /// Writes one answer, dropping the whole table first if it is full.
    ///
    /// The wipe bumps the generation because it is a bulk invalidation: it throws away every
    /// answer, including one a download's watch wrote a moment ago, the freshest fact in the table.
    /// Without the bump, a stat out across the whole sequence would pass both halves of
    /// `isCloudOnly`'s guard (the generation unmoved, the wiped entry nil again) and write its
    /// pre-download answer in. An ordinary `record` doesn't bump: it only adds an answer, and
    /// bumping there would stop the memo memoizing at all (`isCloudOnly`).
    func record(_ path: String, isCloudOnly: Bool) {
        if known.count >= capacity {
            known.removeAll(keepingCapacity: true)
            generation &+= 1
        }
        known[path] = isCloudOnly
    }

    /// Drops one path's answer, when a download the app requested has landed, so the row's next
    /// realization asks the filesystem again instead of serving the pre-download answer.
    func forget(_ path: String) {
        known[path] = nil
        generation &+= 1
    }

    /// Drops every entry at or under `root`. Called when a pane republishes its tree: the memo is
    /// process-wide but a republish refreshes only that pane's rows, so a whole-table clear would
    /// wipe the answers the other pane's rows still serve from and re-stat them for nothing. The only
    /// way to drop entries in bulk.
    ///
    /// Prefix match is per path component, not per character: `/a/bc` must survive a clear under
    /// `/a/b`, so the separator is appended before matching (and the exact root is matched too; only
    /// files are recorded, but the memo shouldn't need to know that).
    ///
    /// A root that isn't an absolute path is a no-op, on purpose. `SettingsManager.path(for:)`
    /// answers `""` for a provider id it can't resolve (a removed provider, or a pane rendering
    /// before providers load), and `PaneLogic.fullPath` passes `""` through. Normalized, that root
    /// would become the prefix `"/"`, which every absolute key matches, so the pane that failed to
    /// resolve would wipe the other pane's answers too. Nothing is invalidated then, so the
    /// generation doesn't bump either.
    ///
    /// `"/"` itself passes the absolute test and normalizes to `""`, whose prefix is `"/"`, so a pane
    /// rooted at the filesystem root clears every absolute entry: the truthful answer for that root.
    ///
    /// Matching is case-sensitive, on purpose. The memo is a `[String: Bool]`, so a lookup already
    /// is; a case-insensitive clear would drop entries `cached(_:)` can still be asked for under
    /// another spelling, and a case-insensitive miss would leave entries this should take. The two
    /// spellings agree today only because keys come from the tree walk, which descends from the
    /// root string `PaneLogic.fullPath` built, and neither side promises that.
    ///
    /// The generation still bumps, as a whole-table clear's would: a stat in flight under this root
    /// must not re-adopt the answer just thrown away. That it also stops an in-flight stat under the
    /// other root from memoizing is deliberate over-invalidation: one counter, one rare repeated
    /// `lstat`, no per-root bookkeeping to get wrong (the trade `forget(_:)` makes too).
    func clear(underRoot root: String) {
        guard let scope = ClearScope(root: root) else { return }
        known = known.filter { !scope.contains($0.key) }
        generation &+= 1
    }

    /// The stat itself, memoized. Runs off the main actor: `lstat` is cheap but it is still I/O, and
    /// against an unmounted or slow provider "cheap" is no promise the main thread can rely on.
    ///
    /// `stat` answers three ways, and only two are memoizable. It is
    /// `MaterializationStatus.isCloudOnlyIfKnown`, which says nil when the path can't be statted at
    /// all, since "not dataless" and "not there" are opposite facts `lstat` reports through the
    /// same failure. Folding nil into `false` would write an entry asserting local content for a
    /// path with no file, served to every later realization without a syscall. The download poll
    /// and this stat are the memo's two writers, and both must keep nil out.
    ///
    /// The caller still gets `false`, so rendering doesn't change: a row for a missing path carries
    /// no badge either way. Only the caching does: a non-answer isn't a fact, so the next
    /// realization asks the filesystem again.
    ///
    /// `stat` is injectable so the invalidation race has a seam to be tested through: the real one
    /// is a detached `lstat`, and a test can't otherwise land a `clear(underRoot:)` inside that
    /// window.
    func isCloudOnly(
        atPath path: String,
        stat: @MainActor (String) async -> Bool? = { p in
            await Task.detached { MaterializationStatus.isCloudOnlyIfKnown(atPath: p) }.value
        }
    ) async -> Bool {
        if let hit = cached(path) { return hit }
        let started = generation
        let answer = await stat(path)
        // Superseded while we were out: hand the answer back (it is this caller's best available
        // truth) but leave the memo alone (`generation`).
        //
        // Two ways to be superseded, and the counter sees only one. An invalidation bumps it. A
        // `record` doesn't, on purpose: one row's answer landing would invalidate every other row's
        // in-flight stat, and a list realizes rows by the dozen, so the memo would stop memoizing
        // under the scrolling it exists for. But a `record` that landed while this stat was out is
        // still newer: the sharp case is a download's watch recording `false` as the content
        // arrives, racing the arming re-stat still carrying the pre-download `true`. This entry was
        // nil on the way in (a hit returns above), so anything here now was written while we were
        // out, by someone who saw more than we did.
        guard generation == started, cached(path) == nil else { return answer ?? false }
        // A stat that couldn't answer memoizes nothing (see above).
        if let answer { record(path, isCloudOnly: answer) }
        return answer ?? false
    }
}

/// The normalized scope of a `clear(underRoot:)`: which keys it covers, decided once for the whole
/// table rather than per entry.
///
/// A value, and not private, so the rule can be pinned without touching the process-wide table:
/// `/` can't be tested through the table, since clearing it would wipe the memo from under suites
/// running in parallel. Failable is the guard: `Table.clear(underRoot:)` says why an unresolvable
/// root must scope nothing. Nested directly on `CloudOnlyBadgeCache`, not inside `Table`, so it
/// keeps the name it is addressed by.
struct ClearScope: Equatable {
    /// The root itself, with every trailing separator removed. `/` normalizes to `""`, whose
    /// separator-suffixed form is `/`, the prefix every absolute key matches.
    let exact: String
    /// `exact` plus the separator: the prefix a descendant must carry. Matching on this rather
    /// than on `exact` keeps `/a/bc` out of a clear under `/a/b`.
    let descendantPrefix: String

    init?(root: String) {
        guard root.hasPrefix("/") else { return nil }
        var exact = root
        while exact.hasSuffix("/") { exact.removeLast() }
        self.exact = exact
        self.descendantPrefix = exact + "/"
    }

    /// Whether `key` names an entry at or under this root. Case-sensitive
    /// (`Table.clear(underRoot:)`).
    func contains(_ key: String) -> Bool {
        key == exact || key.hasPrefix(descendantPrefix)
    }
}
}
