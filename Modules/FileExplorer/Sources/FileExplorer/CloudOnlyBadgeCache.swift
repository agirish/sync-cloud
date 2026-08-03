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
    /// The one table every pane shares.
    ///
    /// The state lives in a `Table` rather than in statics so a test can exercise the rules on a
    /// table of its OWN — the same reason `isCloudOnly`'s `stat` is injectable. The capacity wipe
    /// in particular cannot be tested any other way: proving it invalidates means actually
    /// tripping it, and tripping it on the shared table drops the entries every suite running in
    /// PARALLEL is asserting on. Every static below forwards here unchanged, so nothing in the app
    /// sees a table at all.
    private static let table = Table()

    /// The remembered answer for `path`, or nil if it has not been statted since the last republish.
    static func cached(_ path: String) -> Bool? { table.cached(path) }

    static func record(_ path: String, isCloudOnly: Bool) {
        table.record(path, isCloudOnly: isCloudOnly)
    }

    /// Drops one path's answer — used when a download the app requested has landed, so the next
    /// realization of that row asks the filesystem again instead of serving the pre-download answer.
    static func forget(_ path: String) { table.forget(path) }

    /// Drops every entry at or under `root` — see `Table.clear(underRoot:)`.
    static func clear(underRoot root: String) { table.clear(underRoot: root) }

    /// The stat itself, memoized — see `Table.isCloudOnly(atPath:stat:)`.
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

/// The memo's storage and every rule that operates on it.
///
/// A class with an injectable `capacity`, and not private, purely so the rules can be pinned
/// without writing the process-wide table — see `CloudOnlyBadgeCache.table`. The app makes exactly
/// one, at the default capacity.
///
/// `@MainActor` on the enclosing extension does NOT reach a nested type, so it is stated here: the
/// table is the memo's mutable state and every caller of it is already on the main actor.
@MainActor
final class Table {
    private var known: [String: Bool] = [:]

    /// Bumped by every invalidation: `clear`, `forget`, and the wholesale wipe `record` performs
    /// when the table is full. A stat that was already in flight when one happened returns its
    /// answer to the caller but does NOT write it to the memo. (An ordinary `record` — one that
    /// does not trip the wipe — does not bump; see `isCloudOnly(atPath:stat:)` for why, and for the
    /// second, finer check that covers what the counter deliberately cannot.)
    ///
    /// Without this the memo re-adopted answers the invalidation had just thrown away: the stat
    /// runs off the main actor, so a pane republish landing mid-stat cleared the table and the
    /// resuming stat wrote its pre-republish answer straight back into the fresh one, where it
    /// served every later realization of that row until the NEXT republish. `forget(_:)` is the
    /// sharper case — it is called precisely because a download was requested, so the in-flight
    /// answer it races is the stale "still cloud-only" one it exists to discard.
    ///
    /// This is the same guard `DetailsMetadataCache` carries for the same reason ("last REQUESTED
    /// wins, not last to come back"); this cache simply never grew one.
    private var generation = 0

    /// Bound on the memo. Cleared wholesale at the cap rather than evicted one entry at a time:
    /// that is O(1) and costs at most one repeated `lstat` per path afterwards, which is the same
    /// trade `DetailsMetadataCache.warnedPaths` makes. Sized well above any plausible number of
    /// rows scrolled through between two republishes.
    private let capacity: Int

    init(capacity: Int = 8192) {
        self.capacity = capacity
    }

    /// The remembered answer for `path`, or nil if it has not been statted since the last republish.
    func cached(_ path: String) -> Bool? { known[path] }

    /// Writes one answer, dropping the whole table first if it is full.
    ///
    /// **The wipe bumps the generation, because it is a bulk invalidation.** It reads as an eviction
    /// policy, but what it does is throw away every answer the memo holds — including one written a
    /// moment ago by a download's watch, which is the freshest fact in the table. Without the bump,
    /// a stat that was out across the whole sequence passed both halves of `isCloudOnly`'s guard —
    /// the generation had not moved, and the entry the wipe had just taken was nil again — and wrote
    /// its pre-download answer in. That is verbatim the defect the per-entry check exists to close,
    /// arriving through a door the counter could not see. An ordinary `record` still does not bump:
    /// it only ADDS an answer, and see `isCloudOnly` for why bumping there would stop the memo
    /// memoizing at all.
    func record(_ path: String, isCloudOnly: Bool) {
        if known.count >= capacity {
            known.removeAll(keepingCapacity: true)
            generation &+= 1
        }
        known[path] = isCloudOnly
    }

    /// Drops one path's answer — used when a download the app requested has landed, so the next
    /// realization of that row asks the filesystem again instead of serving the pre-download answer.
    func forget(_ path: String) {
        known[path] = nil
        generation &+= 1
    }

    /// Drops every entry at or under `root`. Called when a pane republishes its tree: the memo is
    /// process-wide but a republish refreshes only THAT pane's rows, so the whole-table clear that
    /// used to live here wiped the answers the other pane's rows were still serving from — every
    /// republish on one side re-statted the other side's visible rows for nothing. This is now the
    /// ONLY way to drop entries in bulk; the parameterless `clear()` it replaced had no production
    /// callers left and no root to be honest about.
    ///
    /// Prefix match is per path COMPONENT, not per character: the entry for `/a/bc` must survive a
    /// clear under `/a/b`, so the comparison appends the separator before matching (and keeps the
    /// exact-root case, for completeness — only files are recorded, but the memo should not know
    /// that).
    ///
    /// **A root that is not an absolute path is a no-op, and that is the whole point.**
    /// `SettingsManager.path(for:)` answers `""` for a provider id it cannot resolve — a removed
    /// provider, or a pane rendering before the providers are loaded — and `PaneLogic.fullPath`
    /// maps `""` through to `""`. Without this guard that empty root normalized to a prefix of
    /// `"/"`, which every absolute key matches: the pane whose provider FAILED to resolve then
    /// republished its empty tree and wiped the OTHER pane's answers too. That is precisely the
    /// global wipe this method was added to remove, arriving through a side door. Nothing was
    /// invalidated on that path, so the generation does not bump either.
    ///
    /// `"/"` is exempt from the guard rather than special-cased by it: it passes the absolute test,
    /// and normalization strips it to the empty string, whose prefix is `"/"` — so a pane genuinely
    /// rooted at the filesystem root clears every absolute entry, which is the truthful answer for
    /// that root rather than an accident.
    ///
    /// **Matching is case-SENSITIVE, deliberately.** The memo is a `[String: Bool]`, so a lookup
    /// already is; a case-insensitive clear would drop entries `cached(_:)` can still be asked for
    /// under a different spelling, and a case-insensitive *miss* would leave entries this clear was
    /// supposed to take. Today the two spellings always agree by lineage — keys come from the tree
    /// walk, which descends from the very root string `PaneLogic.fullPath` built — so this costs
    /// nothing; it is written down because that agreement is an accident of plumbing rather than
    /// something either side promises.
    ///
    /// The generation still bumps, exactly as a whole-table clear's would: a stat in flight for a
    /// path under this root must not re-adopt the answer this clear just threw away. That the bump
    /// also stops an in-flight stat under the OTHER root from memoizing is deliberate
    /// over-invalidation — one counter, one rare repeated `lstat`, no per-root bookkeeping to get
    /// wrong (the same trade `forget(_:)` already makes for other paths).
    func clear(underRoot root: String) {
        guard let scope = ClearScope(root: root) else { return }
        known = known.filter { !scope.contains($0.key) }
        generation &+= 1
    }

    /// The stat itself, memoized. Runs off the main actor: `lstat` is cheap but it is still I/O, and
    /// against an unmounted or slow provider "cheap" is not a promise the main thread can rely on.
    ///
    /// **`stat` answers three ways, and only two of them are memoizable.** It is
    /// `MaterializationStatus.isCloudOnlyIfKnown`, which says nil when the path cannot be statted at
    /// all — because "not dataless" and "not there" are opposite facts `lstat` reports through the
    /// same failure. Folding nil into `false` here (which the two-way `isCloudOnly` did) wrote an
    /// entry asserting local content for a path with no file behind it, and every later realization
    /// of that row was served it without a syscall. That is verbatim the harm the download poll's
    /// three-way probe closed, arriving by this table's OTHER door: the poll and this stat are the
    /// two writers into one memo, and only the poll's door was shut.
    ///
    /// The caller still gets `false`, so nothing about rendering changes — a row for a path that is
    /// not there carries no badge either way. Only the caching does: a non-answer is not a fact, so
    /// the next realization asks the filesystem again rather than being told what this one failed to
    /// find out.
    ///
    /// `stat` is injectable so the invalidation race has a seam to be tested through — the real one
    /// is a detached `lstat`, and a test cannot otherwise land a `clear()` inside that window.
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
        // truth) but leave the memo alone — see `generation`.
        //
        // Two ways to be superseded, and the counter only sees one. An invalidation bumps it. A
        // `record` does not, deliberately — bumping there would mean one row's answer landing
        // invalidated every other row's in-flight stat, and a list realizes rows by the dozen, so
        // the memo would stop memoizing under exactly the scrolling it exists for. But a `record`
        // that landed while this stat was out is still newer than this stat: the sharp case is a
        // download's watch recording `false` the moment the content arrives, racing the arming
        // re-stat that is still carrying the pre-download `true`. This entry was nil on the way in
        // (a hit returns above), so anything here now was written while we were out — and whoever
        // wrote it saw more than we did.
        guard generation == started, cached(path) == nil else { return answer ?? false }
        // A stat that could not answer memoizes nothing — see above.
        if let answer { record(path, isCloudOnly: answer) }
        return answer ?? false
    }
}

/// The normalized scope of a `clear(underRoot:)` — which keys it covers, decided once for the
/// whole table rather than re-derived per entry.
///
/// A value, and not private, so the rule can be pinned without touching the process-wide table:
/// the one case that cannot be tested through the table is `/`, because a test that cleared it to
/// prove it covers everything would wipe the memo out from under whatever suite is running in
/// PARALLEL. Failable IS the guard — see `Table.clear(underRoot:)` for why an unresolvable root
/// must scope nothing at all.
///
/// Nested directly on `CloudOnlyBadgeCache` rather than inside `Table`, so it keeps the name it is
/// already addressed by.
struct ClearScope: Equatable {
    /// The root itself, with every trailing separator removed. `/` normalizes to `""`, whose
    /// separator-suffixed form is `/` — the prefix every absolute key matches.
    let exact: String
    /// `exact` plus the separator: the prefix a DESCENDANT must carry. Matching on this rather
    /// than on `exact` is what keeps `/a/bc` out of a clear under `/a/b`.
    let descendantPrefix: String

    init?(root: String) {
        guard root.hasPrefix("/") else { return nil }
        var exact = root
        while exact.hasSuffix("/") { exact.removeLast() }
        self.exact = exact
        self.descendantPrefix = exact + "/"
    }

    /// Whether `key` names an entry at or under this root. Case-SENSITIVE — see
    /// `Table.clear(underRoot:)`.
    func contains(_ key: String) -> Bool {
        key == exact || key.hasPrefix(descendantPrefix)
    }
}
}
