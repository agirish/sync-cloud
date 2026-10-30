import Foundation

/// Identity of a hashed file for cache lookup: its absolute path, modification time and byte count
/// — the triple the sync engine uses to decide a file is unchanged — and, where the disk answers,
/// its file number and status-change time.
///
/// **The last two are what make a digest safe to keep for as long as it is used (FR59).** The cache
/// persists (`enablePersistence`, opted into at launch) and keeps an entry until it has gone unused for
/// ``ContentHashCache/maxEntryAge``, and the triple alone cannot see an edit that restores the date — `exiftool -P`, `touch -r`,
/// `rsync -t`, any tool that preserves mtime — and keeps the size. Such a file read as identical,
/// and Verify could offer to copy over the side that really differed. The status-change time
/// (`st_ctime`) moves on every write and every metadata change, and nothing but the kernel can set
/// it, so a restored mtime cannot restore it; the file number catches a file REPLACED at the same
/// path by one carrying the old dates. Both come from one path `stat`, never from the descriptor,
/// so a hit still never opens the file (a cloud-only placeholder would be downloaded).
///
/// nil for both where the disk cannot answer — a test double's paths — which keys exactly as the
/// triple always did. The cost of the extra fields is misses, never wrong answers: a metadata change
/// that leaves the bytes alone (a tag, a permission) re-hashes the file once.
public struct ContentHashKey: Hashable, Sendable {
    public let path: String
    public let mtime: TimeInterval
    public let size: Int
    /// `st_ino` — the file, not the name.
    public let fileNumber: UInt64?
    /// `st_ctime`, as seconds since 1970 from the raw `timespec`.
    public let statusChanged: TimeInterval?

    public init(path: String, mtime: TimeInterval, size: Int,
                fileNumber: UInt64? = nil, statusChanged: TimeInterval? = nil) {
        self.path = path
        self.mtime = mtime
        self.size = size
        self.fileNumber = fileNumber
        self.statusChanged = statusChanged
    }

    /// The file number and status-change time of `path`, by one `stat` (which follows a link, as
    /// the read does). nil for both when the stat fails.
    public static func diskIdentity(atPath path: String) -> (fileNumber: UInt64, statusChanged: TimeInterval)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let changed = TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000
        return (UInt64(info.st_ino), changed)
    }
}

/// SHA-256 cache keyed by ``ContentHashKey`` — in memory, and persisted to disk when the app opts in
/// (``enablePersistence(at:now:)``; the shared instances do at launch).
///
/// Verify re-reads and re-hashes both sides of every same-size pair on every run; on a re-run
/// within a session nothing has changed, yet the engine still hashed gigabytes. This cache lets an
/// unchanged file skip the re-hash entirely, making "Verify All" near-instant on repeat runs.
///
/// Hashing runs off the main actor in `Task.detached(priority: .utility)` with several concurrent
/// hashers, so the cache must serialize its own mutable state: it is an `actor`, matching the house
/// style of `VerifyResultsCollector`. Entries live for the process, and — once persistence is on —
/// across launches until one goes unused for ``maxEntryAge``; the key's status-change time is what
/// keeps an entry that old from being believed about a file edited under a restored date (FR59).
public actor ContentHashCache {

    /// A single shared cache for the whole session. Kept here (not as a stored property on the
    /// `@MainActor FileSyncManager`) so `FileSyncManager` stays untouched and extensions — which
    /// cannot add stored properties — can reach it.
    public static let shared = ContentHashCache()

    /// Every persisted digest index the app keeps, as one list.
    ///
    /// **A list in one place, because a list spread across call sites is what breaks** — the same
    /// argument `clearLensResultsForProviderSwitch` makes for lens results, and it broke here
    /// exactly as predicted: Settings ▸ Saved scan data sized and cleared
    /// ``shared`` alone, so the day ``sharedFingerprints`` arrived, "Clear" stopped meaning what
    /// its caption says ("clearing costs time on the next scan and nothing else") — the document
    /// fingerprints survived it and kept being served. Adding an index means adding it here, and
    /// `theRosterHoldsEveryPersistedDigestIndex` fails until it is.
    public static var allPersisted: [ContentHashCache] { [.shared, .sharedFingerprints, .sharedTextless] }

    /// Bytes every persisted index occupies together, or nil when none of them is written.
    ///
    /// `caches` is a parameter purely so tests can exercise the summing on their OWN instances:
    /// pointing the shared ones at a temp file would leave every other test in the process — most
    /// of which reach `.shared` implicitly through `findDuplicates`'s default — talking to a path
    /// this test then deletes.
    public static func totalPersistedSizeOnDisk(
        _ caches: [ContentHashCache] = allPersisted
    ) async -> Int? {
        var total: Int?
        for cache in caches {
            guard let bytes = await cache.persistedSizeOnDisk() else { continue }
            total = (total ?? 0) + bytes
        }
        return total
    }

    /// Forgets every persisted index — memory and disk, for each. `caches` is injectable for the
    /// same reason as above.
    public static func forgetAllPersistedIndexes(
        _ caches: [ContentHashCache] = allPersisted
    ) async {
        for cache in caches { await cache.forgetPersistedIndex() }
    }

    /// The same store, holding ``ContentFingerprint`` digests instead of SHA-256 content hashes.
    ///
    /// **A second instance, not a second namespace inside the first.** The key shape is identical —
    /// (path, mtime, size, file number, ctime), with identical invalidation semantics — but the
    /// values answer different questions, and mixing them would make one lookup able to return the
    /// other's answer if a prefix were ever dropped or mistyped. Two instances make that
    /// unwriteable, and they cost only a second dictionary; they also persist to separate files, so
    /// the fingerprint index can be thrown away (or its scheme bumped) without re-hashing
    /// gigabytes.
    public static let sharedFingerprints = ContentHashCache()

    /// The documents the same-text pass read and found too little text in, each held as
    /// ``ContentFingerprint/tooLittleTextMarker`` under the fingerprint key — so a warm rescan does
    /// not re-parse every image-only scan.
    ///
    /// **A third instance and a third file, not markers inside ``sharedFingerprints``, because of
    /// the builds that came before.** Every negative is the same string, and a build from before
    /// it existed reads anything in the fingerprint index as a digest: it would serve the marker as
    /// one, group every textless scan as "same text" — offering to trash all but one — and mark
    /// each loose scan already filed beside all the others. Installing an older build is routine on
    /// this machine, so the negatives live where no older build looks. It also keeps them out of
    /// what `DocumentIdentityIndex` and satellite homes read, and their saves from moving the files
    /// those rebuild on.
    public static let sharedTextless = ContentHashCache()

    /// Upper bound on retained entries; oldest are evicted first once exceeded.
    ///
    /// **This number is a cliff, not a dial.** Eviction is FIFO and the workloads re-read their
    /// files in the same order they wrote them, so a working set that exceeds the cap evicts every
    /// entry just before the next pass reaches it: the hit rate does not degrade, it goes to
    /// ZERO. Measured, replaying a scan twice — 18 000 files against a 20 000 cap gives 100 %
    /// hits; 23 122 files against the same cap gives 0.0 %.
    ///
    /// That is not hypothetical. A duplicates scan hashes every file whose size collides with another,
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

    /// A digest, when it was recorded, and when a lookup last used it. Both stamps exist only for
    /// persistence and both survive a save/load round trip, so reloading resets neither.
    /// `lastUsed` is what a reloaded entry ages out by (see ``maxEntryAge``); `storedAt` stays the
    /// hashing time, because readers of the index file take the newest DIGEST per path by it
    /// (`DocumentIdentityIndex`), and a hit says nothing about which state of a file is newer.
    struct Entry: Sendable {
        let hex: String
        let storedAt: Date
        var lastUsed: Date
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
    ///
    /// **A hit keeps the entry alive** — it moves `lastUsed`, which is what ``maxEntryAge`` counts
    /// from — and marks the index for saving, so the move outlives the launch. Only when the stamp
    /// is at least ``lastUsedResolution`` old, though: every move makes the next `save()` rewrite
    /// the whole file, and a rewrite moves the file's date, which is what sends satellite homes and
    /// To File's already-filed index back to decoding both index files. Stamping every hit would
    /// buy that on every scan of the day, for an expiry counted in days anyway. A scan's hits are
    /// therefore written at most once a day, by the save the scan already makes.
    public func hash(for key: ContentHashKey, at now: Date = Date()) -> String? {
        guard var entry = entries[key] else { lookupMisses += 1; return nil }
        lookupHits += 1
        if now.timeIntervalSince(entry.lastUsed) >= Self.lastUsedResolution {
            entry.lastUsed = now
            entries[key] = entry
            unsavedChanges += 1
        }
        return entry.hex
    }

    /// How stale `lastUsed` may grow before a hit moves it — see ``hash(for:at:)``. An entry is
    /// therefore dropped between ``maxEntryAge`` and ``maxEntryAge`` plus a day after its last use.
    static let lastUsedResolution: TimeInterval = 24 * 60 * 60

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
        entries[key] = Entry(hex: hex, storedAt: now, lastUsed: now)
        unsavedChanges += 1

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

    /// How long a reloaded entry may go UNUSED before it is dropped on load — counted from its last
    /// hit, not from when it was hashed.
    ///
    /// **It used to count from hashing, and that made the cache expire in batches.** A hit never
    /// moved the stamp, so every entry one full scan wrote left on the same day thirty days later,
    /// and the next scan re-read everything — about five minutes for ~9,200 PDFs — however often
    /// the files had been looked up in between.
    ///
    /// The cap from hashing was a trust bound: it limited how long a digest was believed about a
    /// file rewritten with its date restored (`exiftool -P`, `touch -r`, `rsync -t`) and its size
    /// kept, which the old (path, mtime, size) key could not see. Since FR59 (1f9fdbb37) the key
    /// carries the file number and status-change time too, and a write always moves `st_ctime` —
    /// nothing but the kernel sets it — so such a rewrite no longer matches the entry at all, and a
    /// file replaced at the same path by one carrying the old dates has a new file number. The key
    /// now does the invalidating, and an entry that still matches is as trustworthy on day 300 as
    /// on day 1. So the owner chose (10-30) to keep an entry while it is used.
    ///
    /// Thirty days of DISUSE stays, because something must drop the entries no lookup can reach
    /// any more: a deleted or edited file's old key, and every entry written before FR59, whose key
    /// lacks the two fields a real file is now looked up by. Those are never hit, so they leave
    /// thirty days after their last use, as before. What the key still cannot see — a disk whose
    /// stat answers no status-change time keys as the old triple — has no bound but disuse now;
    /// such a disk is a test double's path in practice, since every local and File Provider
    /// volume answers `stat`. `DEFERRED_ENHANCEMENTS.md` #9 asked for this age cap alongside the
    /// schema version.
    public static let maxEntryAge: TimeInterval = 30 * 24 * 60 * 60

    /// Where this cache persists, or nil for a purely in-memory session cache.
    ///
    /// **nil is the default and stays the default for `shared`.** `findDuplicates` and Verify both
    /// take `cache: ContentHashCache? = .shared`, so a great many tests exercise the shared
    /// instance without asking for it by name; an ambient on-disk location would have every one of
    /// them reading and writing the user's real index. The app opts in at startup.
    private var persistenceURL: URL?

    /// Insertions and moved `lastUsed` stamps since the last successful save. `save()` is a no-op
    /// at zero, so a lens that runs entirely off cache hits within a day of their last use does
    /// not rewrite an unchanged multi-megabyte file.
    private var unsavedChanges = 0

    /// Saves that found something to write, since this instance was created. Test
    /// instrumentation, like ``lookupHits``: it is what shows a scan's hits are written once, not
    /// once per hit. Nothing outside tests should read it.
    private(set) var savesWritten = 0

    /// Points this cache at `url` and loads whatever is already there.
    ///
    /// Loading is additive: entries already in memory win over the file, because they were
    /// observed this session and the file is by definition older. Returns how many entries were
    /// adopted, for the launch breadcrumb.
    @discardableResult
    /// `nonisolated` so the DECODE happens off the actor, and only the adoption below runs on it.
    ///
    /// This is the same argument ``ContentHashIndexStore/saveInBackground(_:to:)`` makes for the
    /// write, and it applies harder here: reading is the more expensive direction, because at the
    /// entry cap it is a JSON decode of a hundred thousand records. Run on the actor it would
    /// serialize every concurrent `hash(for:)` behind it — and the load is kicked off at launch,
    /// exactly when a scan is most likely to already be hashing. The adoption itself is a run of
    /// dictionary inserts and belongs on the actor, which is where it stays.
    ///
    /// **The ordering sort is off the actor for the same reason, and used not to be.** `adopt`
    /// opened by sorting the records it had just been handed — at the entry cap, a sort of a
    /// hundred thousand, on the actor, serializing exactly the concurrent `hash(for:)` calls the
    /// paragraph above moved the decode to protect. The decode crossed the boundary and the sort
    /// stayed behind it; nothing failed, because the cost is invisible unless a scan happens to be
    /// hashing while the launch load runs, which is precisely when it is paid.
    public nonisolated func enablePersistence(at url: URL, now: Date = Date()) async -> Int {
        let records = ContentHashIndexStore.load(from: url).sorted {
            ($0.lastUsed ?? $0.storedAt, $0.storedAt) < ($1.lastUsed ?? $1.storedAt, $1.storedAt)
        }
        return await adopt(records, from: url, now: now)
    }

    /// Points the cache at `url` and merges `records` into it. Split out of `enablePersistence`
    /// only so the decode can happen off the actor; nothing else should call this.
    ///
    /// - Precondition: `records` arrives least recently used first (`lastUsed`, then `storedAt`,
    ///   ascending), so the adopted run is itself a FIFO queue with the stalest entries in front. The CALLER sorts — a sort is not a dictionary insert, and this
    ///   function's whole reason to exist is that only dictionary inserts run here.
    private func adopt(_ records: [ContentHashRecord], from url: URL, now: Date) -> Int {
        persistenceURL = url
        var adoptedKeys: [ContentHashKey] = []
        for record in records {
            // A record written before `lastUsed` existed was last used, as far as anyone knows, when
            // it was hashed — the one stamp it has.
            let lastUsed = record.lastUsed ?? record.storedAt
            guard now.timeIntervalSince(lastUsed) <= Self.maxEntryAge else { continue }
            let key = ContentHashKey(path: record.path, mtime: record.mtime, size: record.size,
                                     fileNumber: record.fileNumber, statusChanged: record.statusChanged)
            guard entries[key] == nil else { continue }
            entries[key] = Entry(hex: record.hex, storedAt: record.storedAt, lastUsed: lastUsed)
            adoptedKeys.append(key)
        }

        // Adopted keys go at the FRONT of the queue, not the back. Everything in the file was
        // written by an earlier run, so it is older than anything hashed in this one — and
        // eviction drops from the front. Appending instead would make a mid-scan load quietly
        // reverse the priority, evicting the digests this session just measured in order to keep
        // ones read off disk. Compact first, because prepending has to start from index 0.
        if evictedPrefix > 0 {
            insertionOrder.removeFirst(evictedPrefix)
            evictedPrefix = 0
        }
        insertionOrder = adoptedKeys + insertionOrder

        // The file can exceed the cap if the cap shrank between launches; trim as `store` would.
        while entries.count > maxEntries, evictedPrefix < insertionOrder.count {
            entries[insertionOrder[evictedPrefix]] = nil
            evictedPrefix += 1
        }
        // `unsavedChanges` is deliberately NOT reset here. Adoption never incremented it —
        // these entries are assigned directly rather than through `store` — so zeroing it would
        // not be "adopting isn't new information", it would be discarding the dirty flag for
        // whatever was hashed BEFORE the load landed. The load is detached at launch and can land
        // mid-scan, so that is a live path: the scan's own `save()` would then find nothing to do
        // and every digest it had just paid to compute would be dropped.
        return adoptedKeys.count
    }

    /// Writes the index if anything new has been hashed, or a hit has moved an entry's `lastUsed`,
    /// since the last save. Off the caller's thread and serialized — see
    /// ``ContentHashIndexStore/saveInBackground(_:to:)``.
    public func save() {
        guard let persistenceURL, unsavedChanges > 0 else { return }
        let records = entries.map { key, entry in
            ContentHashRecord(path: key.path, mtime: key.mtime, size: key.size,
                              hex: entry.hex, storedAt: entry.storedAt,
                              fileNumber: key.fileNumber, statusChanged: key.statusChanged,
                              lastUsed: entry.lastUsed)
        }
        unsavedChanges = 0
        savesWritten += 1
        ContentHashIndexStore.saveInBackground(records, to: persistenceURL)
    }

    /// Bytes the persisted index occupies, or nil when persistence is off or nothing is written.
    public func persistedSizeOnDisk() -> Int? {
        persistenceURL.flatMap { ContentHashIndexStore.sizeOnDisk(at: $0) }
    }

    /// Forgets every digest — the in-memory ones AND the file.
    ///
    /// **Both halves, and that is the whole point of it living here rather than on the store.**
    /// Deleting the file alone would look like it worked and then quietly undo itself: this actor
    /// still holds the session's digests, and its next `save()` — which the duplicate scan and
    /// Verify each call unconditionally — would write them all back out. Clearing the memory too
    /// costs the current session some re-hashing, which is exactly what the user asked for.
    ///
    /// `unsavedChanges` is reset because there is genuinely nothing left to write; that is the
    /// one case where zeroing it is not discarding a dirty flag (compare `adopt`, which must not).
    public func forgetPersistedIndex() {
        entries.removeAll()
        insertionOrder.removeAll()
        evictedPrefix = 0
        unsavedChanges = 0
        if let persistenceURL { ContentHashIndexStore.deleteInBackground(at: persistenceURL) }
    }

    /// Test seam: how many entries are held right now.
    var count: Int { entries.count }
}
