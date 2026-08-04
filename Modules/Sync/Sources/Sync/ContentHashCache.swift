import Foundation

/// Identity of a hashed file for cache lookup. Two files with the same absolute path, the same
/// modification time, and the same byte count are treated as identical content — the same
/// (path, mtime, size) triple that the sync engine already uses to decide a file is unchanged.
/// A byte-level edit that keeps the size but touches the file bumps the mtime, so a stale entry
/// is bypassed rather than served; the pathological "same size, same mtime, different bytes" case
/// (deliberate mtime reset) is out of scope for a session cache, exactly as it is for the scan.
public struct ContentHashKey: Hashable, Sendable {
    public let path: String
    public let mtime: TimeInterval
    public let size: Int

    public init(path: String, mtime: TimeInterval, size: Int) {
        self.path = path
        self.mtime = mtime
        self.size = size
    }
}

/// Session-scoped, in-memory SHA-256 cache keyed by ``ContentHashKey``.
///
/// Verify re-reads and re-hashes both sides of every same-size pair on every run; on a re-run
/// within a session nothing has changed, yet the engine still hashed gigabytes. This cache lets an
/// unchanged file skip the re-hash entirely, making "Verify All" near-instant on repeat runs.
///
/// Hashing runs off the main actor in `Task.detached(priority: .utility)` with several concurrent
/// hashers, so the cache must serialize its own mutable state: it is an `actor`, matching the house
/// style of `VerifyResultsCollector`. Entries live only for the process — mtime+size keying means a
/// changed file is naturally bypassed, so there is nothing worth persisting to disk.
public actor ContentHashCache {

    /// A single shared cache for the whole session. Kept here (not as a stored property on the
    /// `@MainActor FileSyncManager`) so `FileSyncManager` stays untouched and extensions — which
    /// cannot add stored properties — can reach it.
    public static let shared = ContentHashCache()

    /// Upper bound on retained entries; oldest are evicted first once exceeded.
    ///
    /// **This number is a cliff, not a dial.** Eviction is FIFO and the workloads re-read their
    /// files in the same order they wrote them, so a working set that exceeds the cap evicts every
    /// entry just before the next pass reaches it: the hit rate does not degrade, it goes to
    /// ZERO. Measured, replaying a scan twice — 18 000 files against a 20 000 cap gives 100 %
    /// hits; 23 122 files against the same cap gives 0.0 %.
    ///
    /// That is not hypothetical. A Tidy scan hashes every file whose size collides with another,
    /// and on the trees this was sized against that is 23 122 of 33 580 files in one provider and
    /// 25 148 of 35 100 in the other — 48 270 together, since Verify and both scans share this
    /// cache. At the old 20 000 the cache returned nothing at all for those trees while still
    /// paying to maintain itself.
    ///
    /// 100 000 is that measured need with room to grow into. Headroom is close to free here,
    /// because **this is a ceiling, not an allocation**: the cache holds the WORKING SET, and the
    /// cap only decides when it starts throwing entries away. Measured with realistic paths and
    /// distinct digests — a 48 270-entry working set costs 20.9 MB under a 60 000 cap and 21.4 MB
    /// under a 100 000 one. Half a megabyte buys twice the room before the cliff.
    ///
    /// The cap only *becomes* the memory figure in sustained overflow (~83 MB at 100 000), and
    /// that is precisely the regime it exists to prevent — a cache that big is one that has
    /// already stopped working. Budget against the working set: ~440 bytes an entry, so ~21 MB
    /// for these trees, against the 525 MB the app was measured at with both trees loaded.
    ///
    /// Sizing to just clear today's number (50 000 fits 48 270) would sit 3 % from the cliff and
    /// fall off it the first time the user adds files — and, per the figures above, would save
    /// essentially nothing.
    private let maxEntries: Int

    /// A digest plus when it was recorded. The timestamp exists only for persistence — it is what
    /// lets a reloaded entry age out (see ``maxEntryAge``) instead of living forever, and it is
    /// preserved across a save/load round trip so reloading does not reset an entry's age.
    struct Entry: Sendable {
        let hex: String
        let storedAt: Date
    }

    private var entries: [ContentHashKey: Entry] = [:]
    /// Insertion order for FIFO eviction. `insertionOrder[evictedPrefix...]` are the live keys,
    /// oldest first; everything before `evictedPrefix` is already gone from `entries` and is
    /// waiting to be compacted away.
    private var insertionOrder: [ContentHashKey] = []
    /// How much of `insertionOrder`'s front has already been evicted.
    ///
    /// Eviction used to be `insertionOrder.removeFirst()`, which shifts the whole array — O(n) per
    /// eviction, where n is the cap. That costs nothing until the cap is reached and then costs it
    /// on EVERY subsequent store, which is exactly the sustained-load case the cap exists for:
    /// measured at the then-current 20 000 cap, each store past it became a ~640 KB memmove, and
    /// 200 000 stores took 5.08 s against 0.29 s for the version below. The cap has since grown,
    /// which would have made that worse in direct proportion. Advancing an index instead makes
    /// eviction O(1); the dead prefix is
    /// compacted away in one shot once it reaches half the array, so the array cannot grow without
    /// bound and each compaction drops at least half of it — amortized O(1) per store.
    private var evictedPrefix = 0

    public init(maxEntries: Int = 100_000) {
        self.maxEntries = max(1, maxEntries)
    }

    /// The cached hex digest for `key`, or `nil` if this file (at this mtime and size) has not been
    /// hashed this session.
    public func hash(for key: ContentHashKey) -> String? {
        guard let entry = entries[key] else { lookupMisses += 1; return nil }
        lookupHits += 1
        return entry.hex
    }

    /// Lookups served and lookups missed, since this instance was created.
    ///
    /// Test instrumentation, in the spirit of ``orderSlotsInUse``: a persisted index is supposed to
    /// stop a rescan re-reading bytes, and *entry count did not change* cannot show that — an
    /// entry re-hashed and re-stored under a key it already has leaves the count identical. Only
    /// counting the lookups distinguishes "every digest came from the file" from "the cache was
    /// consulted and quietly rebuilt". Nothing outside tests should read these.
    private(set) var lookupHits = 0
    private(set) var lookupMisses = 0

    /// How many slots `insertionOrder` currently occupies, live plus not-yet-compacted.
    ///
    /// Exists only so the compaction threshold can be pinned. Deferring compaction is what makes
    /// eviction amortized O(1), and the cost of getting the threshold wrong is an array that grows
    /// forever — a memory leak that every correctness test would still pass straight through,
    /// because the SURVIVORS stay right either way. Nothing outside tests should read this.
    var orderSlotsInUse: Int { insertionOrder.count }

    /// Records `hex` as the SHA-256 of `key`, evicting the oldest entry if the cap is exceeded.
    public func store(_ hex: String, for key: ContentHashKey, at now: Date = Date()) {
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = Entry(hex: hex, storedAt: now)
        unsavedInsertions += 1

        // A key is appended only when it is ABSENT from `entries`, and it can only become absent by
        // being evicted — which advances `evictedPrefix` past its slot. So a key never appears twice
        // in the live region, and `entries.count == insertionOrder.count - evictedPrefix` always
        // holds; that invariant is what lets this loop trust the index it is walking.
        while entries.count > maxEntries, evictedPrefix < insertionOrder.count {
            entries[insertionOrder[evictedPrefix]] = nil
            evictedPrefix += 1
        }

        // Reclaim the dead prefix once it dominates the array. Deferring to the halfway mark is
        // what makes the amortization work: each compaction is O(n) but drops at least half the
        // storage, so the per-store cost stays constant.
        if evictedPrefix > 0, evictedPrefix * 2 >= insertionOrder.count {
            insertionOrder.removeFirst(evictedPrefix)
            evictedPrefix = 0
        }
    }

    // MARK: - Persistence

    /// How stale a reloaded entry may be before it is dropped on load.
    ///
    /// The key — (path, mtime, size) — handles invalidation correctly for every ordinary edit,
    /// because writing a file moves its mtime. The one case it cannot see is a *deliberate* mtime
    /// reset that also preserves the byte count, and persistence is what turns that from a
    /// session-lived confusion into a durable one. Thirty days bounds how long a resurrected entry
    /// can be believed. It is not a correctness argument — nothing here can distinguish that case —
    /// it is a blast-radius one, and it is the reason `DEFERRED_ENHANCEMENTS.md` #9 asked for an
    /// age cap alongside the schema version.
    public static let maxEntryAge: TimeInterval = 30 * 24 * 60 * 60

    /// Where this cache persists, or nil for a purely in-memory session cache.
    ///
    /// **nil is the default and stays the default for `shared`.** `findDuplicates` and Verify both
    /// take `cache: ContentHashCache? = .shared`, so a great many tests exercise the shared
    /// instance without asking for it by name; an ambient on-disk location would have every one of
    /// them reading and writing the user's real index. The app opts in at startup.
    private var persistenceURL: URL?

    /// Insertions since the last successful save. `save()` is a no-op at zero, so a lens that runs
    /// entirely off cache hits does not rewrite an unchanged multi-megabyte file.
    private var unsavedInsertions = 0

    /// Points this cache at `url` and loads whatever is already there.
    ///
    /// Loading is additive: entries already in memory win over the file, because they were
    /// observed this session and the file is by definition older. Returns how many entries were
    /// adopted, for the launch breadcrumb.
    @discardableResult
    public func enablePersistence(at url: URL, now: Date = Date()) -> Int {
        persistenceURL = url
        let records = ContentHashIndexStore.load(from: url)
        var adopted = 0
        // Oldest first, so `insertionOrder` stays a genuine FIFO queue and eviction keeps dropping
        // the least recently recorded — the same discipline `store` maintains for live insertions.
        for record in records.sorted(by: { $0.storedAt < $1.storedAt }) {
            guard now.timeIntervalSince(record.storedAt) <= Self.maxEntryAge else { continue }
            let key = ContentHashKey(path: record.path, mtime: record.mtime, size: record.size)
            guard entries[key] == nil else { continue }
            insertionOrder.append(key)
            entries[key] = Entry(hex: record.hex, storedAt: record.storedAt)
            adopted += 1
        }
        // A file larger than the cap is possible if the cap shrank between launches; trim to it
        // the same way `store` would have.
        while entries.count > maxEntries, evictedPrefix < insertionOrder.count {
            entries[insertionOrder[evictedPrefix]] = nil
            evictedPrefix += 1
        }
        // Adopting from disk is not new information to write back.
        unsavedInsertions = 0
        return adopted
    }

    /// Writes the index if anything new has been hashed since the last save. Off the caller's
    /// thread and serialized — see ``ContentHashIndexStore/saveInBackground(_:to:)``.
    public func save() {
        guard let persistenceURL, unsavedInsertions > 0 else { return }
        let records = entries.map { key, entry in
            ContentHashRecord(path: key.path, mtime: key.mtime, size: key.size,
                              hex: entry.hex, storedAt: entry.storedAt)
        }
        unsavedInsertions = 0
        ContentHashIndexStore.saveInBackground(records, to: persistenceURL)
    }

    /// Test seam: how many entries are held right now.
    var count: Int { entries.count }
}
