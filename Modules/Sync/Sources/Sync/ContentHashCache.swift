import Foundation

/// Identity of a hashed file for cache lookup: path, modification time and byte count (the triple
/// the sync engine uses to call a file unchanged), plus its file number and status-change time
/// where the disk answers.
///
/// **The last two make a digest safe to keep while it is used.** The triple can't see an edit that
/// keeps the size and restores the date (`exiftool -P`, `touch -r`, `rsync -t`), so Verify could
/// offer to copy over the side that really differs. `st_ctime` moves on every write and only the
/// kernel sets it; the file number catches a file replaced at the same path by one with the old
/// dates. Both come from one path `stat`, never a descriptor, so a hit never opens the file (a
/// cloud-only placeholder would download).
///
/// nil for both where the disk can't answer (a test double's path, a failed stat, or FAT/exFAT,
/// see `diskIdentity`), which keys by the triple alone. The extra fields cost only misses: a
/// metadata-only change (a tag, a permission) re-hashes the file once.
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
    /// the read does). nil when the stat fails or the volume keeps no real status-change time.
    ///
    /// **FAT and exFAT have no real ctime:** `stat` reports the modification time in its place, and
    /// the file number can survive a rewrite, so a rewrite with its date put back looks untouched.
    /// nil keys such a file by the triple, and ``ContentHashCache`` ages it from its hashing.
    public static func diskIdentity(atPath path: String) -> (fileNumber: UInt64, statusChanged: TimeInterval)? {
        diskIdentity(atPath: path, fileSystemType: fileSystemType(atPath:))
    }

    /// ``diskIdentity(atPath:)`` with the volume type asked through `fileSystemType`, the seam tests
    /// use since they can't mount a FAT volume.
    ///
    /// Asked on every call, not cached per volume: macOS reuses device numbers, so an exFAT disk
    /// attached after an APFS one would inherit "apfs", and one failed `statfs` (a file deleted
    /// mid-scan) would mark the whole volume identity-less for the launch.
    static func diskIdentity(atPath path: String,
                             fileSystemType: (String) -> String?) -> (fileNumber: UInt64, statusChanged: TimeInterval)? {
        var info = stat()
        guard stat(path, &info) == 0, let type = fileSystemType(path),
              keepsStatusChanges(fileSystemType: type) else { return nil }
        let changed = TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000
        return (UInt64(info.st_ino), changed)
    }

    /// Whether a volume of this type keeps a real status-change time: APFS and HFS+.
    static func keepsStatusChanges(fileSystemType type: String) -> Bool {
        ["apfs", "hfs"].contains(type)
    }

    /// `statfs`'s `f_fstypename` for the volume holding `path`; nil if the call fails.
    static func fileSystemType(atPath path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Whether this key carries the identity that makes a digest safe to keep while it is used.
    var hasDiskIdentity: Bool { fileNumber != nil && statusChanged != nil }
}

/// SHA-256 cache keyed by ``ContentHashKey``, in memory and persisted to disk when the app opts in
/// (``enablePersistence(at:now:)``; the shared instances do at launch). It lets an unchanged file
/// skip the re-hash, so a repeat Verify or duplicates scan doesn't re-read gigabytes.
///
/// An `actor`, because several detached hashers run concurrently off the main actor. With
/// persistence on, entries live across launches until unused for ``maxEntryAge``; the key's
/// status-change time keeps an old entry from being believed about a file edited under a restored
/// date.
public actor ContentHashCache {

    /// The session's shared cache. A static here, not a stored property of `FileSyncManager`, so
    /// extensions, which can't add stored properties, can reach it.
    public static let shared = ContentHashCache()

    /// Every persisted digest index the app keeps, in one list, so Settings ▸ Saved scan data sizes
    /// and clears all of them; an index missing here would survive "Clear" and keep being served.
    /// Add each new index here; `theRosterHoldsEveryPersistedDigestIndex` fails until you do.
    public static var allPersisted: [ContentHashCache] { [.shared, .sharedFingerprints, .sharedTextless] }

    /// Bytes every persisted index occupies together, or nil when none of them is written.
    ///
    /// `caches` is a parameter so tests can use their own instances: pointing the shared ones at a
    /// temp file would leave other tests, which reach `.shared` through `findDuplicates`'s default,
    /// talking to a path that test deletes.
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
    /// A second instance, not a namespace in the first, so one lookup can never return the other's
    /// answer. It persists to its own file, so the fingerprint index can be dropped (or its scheme
    /// bumped) without re-hashing gigabytes.
    public static let sharedFingerprints = ContentHashCache()

    /// Documents the same-text pass found too little text in, each held as
    /// ``ContentFingerprint/tooLittleTextMarker`` under the fingerprint key, so a warm rescan doesn't
    /// re-parse every image-only scan.
    ///
    /// **Its own instance and file, never markers inside ``sharedFingerprints``.** An older build
    /// reads anything in the fingerprint index as a digest, and since every marker is the same
    /// string it would group every textless scan as "same text" (offering to trash all but one) and
    /// mark each one already filed. It also keeps markers out of what `DocumentIdentityIndex` and
    /// satellite homes read, and their saves from moving the files those rebuild on.
    public static let sharedTextless = ContentHashCache()

    /// Upper bound on retained entries; oldest are evicted first once exceeded.
    ///
    /// **A cliff, not a dial.** Eviction is FIFO and scans re-read files in the order they stored
    /// them, so a working set over the cap evicts each entry just before the next pass needs it and
    /// the hit rate drops to zero. Both providers' duplicate scans and Verify share this cache, and
    /// on the trees it was sized for they hash about 48,000 files; 100,000 leaves room to grow.
    /// Headroom is nearly free, because the cap is a ceiling, not an allocation: memory follows the
    /// working set (~440 bytes an entry). The cap becomes the memory figure only in sustained
    /// overflow, where the cache has stopped working anyway.
    private let maxEntries: Int

    /// A digest, when it was recorded, and when a lookup last used it. Both stamps survive a
    /// save/load round trip. A reloaded entry ages out by `lastUsed` (``maxEntryAge``); `storedAt`
    /// stays the hashing time, because `DocumentIdentityIndex` takes the newest digest per path by
    /// it, and a hit says nothing about which state of a file is newer.
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
    /// How much of `insertionOrder`'s front has already been evicted. Advancing an index makes
    /// eviction O(1), where `removeFirst()` would shift the whole array on every store past the cap.
    /// The dead prefix is compacted once it reaches half the array, so the array stays bounded and
    /// each store is amortized O(1).
    private var evictedPrefix = 0

    public init(maxEntries: Int = 100_000) {
        self.maxEntries = max(1, maxEntries)
    }

    /// The cached hex digest for `key`, or `nil` if this file (at this mtime and size) has not been
    /// hashed.
    ///
    /// A hit keeps the entry alive: it moves `lastUsed`, which ``maxEntryAge`` counts from, and marks
    /// the index for saving. Only once the stamp is ``lastUsedResolution`` old, because each move
    /// makes the next `save()` rewrite the file, and a rewrite sends satellite homes and To File's
    /// already-filed index back to decoding both index files. So hits are written at most once a day.
    public func hash(for key: ContentHashKey, at now: Date = Date()) -> String? {
        guard var entry = entries[key] else { lookupMisses += 1; return nil }
        lookupHits += 1
        // Only a key with a disk identity is kept alive by use; without one (FAT, exFAT, a failed
        // stat) nothing would catch a rewrite under a restored date, so it ages from its hashing.
        if key.hasDiskIdentity, now.timeIntervalSince(entry.lastUsed) >= Self.lastUsedResolution {
            entry.lastUsed = now
            entries[key] = entry
            unsavedChanges += 1
        }
        return entry.hex
    }

    /// How stale `lastUsed` may grow before a hit moves it — see ``hash(for:at:)``. An entry is
    /// therefore dropped between ``maxEntryAge`` and ``maxEntryAge`` plus a day after its last use.
    static let lastUsedResolution: TimeInterval = 24 * 60 * 60

    /// Lookups served and missed since this instance was created. Test instrumentation: an
    /// unchanged entry count can't show that a rescan skipped re-reading bytes, since re-storing
    /// under the same key leaves it unchanged. Nothing outside tests should read these.
    private(set) var lookupHits = 0
    private(set) var lookupMisses = 0

    /// How many slots `insertionOrder` occupies, live plus not yet compacted. Exists so tests can
    /// pin the compaction threshold: a wrong one leaks memory forever while every correctness test
    /// still passes. Nothing outside tests should read this.
    var orderSlotsInUse: Int { insertionOrder.count }

    /// Records `hex` as the SHA-256 of `key`, evicting the oldest entry if the cap is exceeded.
    public func store(_ hex: String, for key: ContentHashKey, at now: Date = Date()) {
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = Entry(hex: hex, storedAt: now, lastUsed: now)
        unsavedChanges += 1

        // A key is appended only when absent from `entries`, and it becomes absent only by eviction,
        // which advances `evictedPrefix` past its slot. So no key appears twice in the live region,
        // and this loop can rely on `entries.count == insertionOrder.count - evictedPrefix`.
        while entries.count > maxEntries, evictedPrefix < insertionOrder.count {
            entries[insertionOrder[evictedPrefix]] = nil
            evictedPrefix += 1
        }

        // Reclaim the dead prefix at the halfway mark: each O(n) compaction drops at least half the
        // storage, so the per-store cost stays constant.
        if evictedPrefix > 0, evictedPrefix * 2 >= insertionOrder.count {
            insertionOrder.removeFirst(evictedPrefix)
            evictedPrefix = 0
        }
    }

    // MARK: - Persistence

    /// How long a reloaded entry may go unused before it is dropped on load, counted from its last
    /// hit rather than its hashing, so a whole scan's entries don't expire on one day.
    ///
    /// The key does the invalidating: its file number and status-change time stop a rewrite under
    /// a restored date from matching, so a matching entry is as trustworthy on day 300 as on day 1.
    /// The age limit drops what no lookup can reach any more, such as a deleted or edited file's old
    /// key, or one without the two identity fields. A key without a disk identity (FAT, exFAT, a
    /// failed stat, a test double) ages from its hashing instead, since nothing would catch a
    /// rewrite under a restored date.
    public static let maxEntryAge: TimeInterval = 30 * 24 * 60 * 60

    /// Where this cache persists, or nil for a purely in-memory session cache.
    ///
    /// **nil stays the default, for `shared` too.** `findDuplicates` and Verify default to
    /// `.shared`, so many tests use it without naming it; a default on-disk location would have them
    /// all reading and writing the user's real index. The app opts in at startup.
    private var persistenceURL: URL?

    /// Insertions and moved `lastUsed` stamps since the last save. `save()` is a no-op at zero, so a
    /// lens served entirely from recent hits doesn't rewrite an unchanged multi-megabyte file.
    private var unsavedChanges = 0

    /// Saves that found something to write, since this instance was created. Test instrumentation
    /// showing a scan's hits are written once, not per hit. Nothing outside tests should read it.
    private(set) var savesWritten = 0

    /// Points this cache at `url` and loads whatever is already there.
    ///
    /// Loading is additive: entries already in memory win, because they were observed this session
    /// and the file is older. Returns how many entries were adopted, for the launch breadcrumb.
    @discardableResult
    /// `nonisolated` so the decode and the sort run off the actor and only the adoption runs on it.
    /// At the entry cap each is a pass over a hundred thousand records, and on the actor it would
    /// stall every concurrent `hash(for:)`; the load starts at launch, just when a scan may be
    /// hashing. Keep any new per-record work out of `adopt` for the same reason.
    public nonisolated func enablePersistence(at url: URL, now: Date = Date()) async -> Int {
        let records = ContentHashIndexStore.load(from: url).sorted {
            ($0.lastUsed ?? $0.storedAt, $0.storedAt) < ($1.lastUsed ?? $1.storedAt, $1.storedAt)
        }
        return await adopt(records, from: url, now: now)
    }

    /// Points the cache at `url` and merges `records` into it. Split out of `enablePersistence` only
    /// so the decode can happen off the actor; nothing else should call this.
    ///
    /// - Precondition: `records` arrives least recently used first (`lastUsed`, then `storedAt`,
    ///   ascending), so the adopted run is a FIFO queue with the stalest in front. The caller sorts,
    ///   so that only dictionary inserts run here.
    private func adopt(_ records: [ContentHashRecord], from url: URL, now: Date) -> Int {
        persistenceURL = url
        var adoptedKeys: [ContentHashKey] = []
        for record in records {
            // A record without `lastUsed` counts as last used when it was hashed.
            let key = ContentHashKey(path: record.path, mtime: record.mtime, size: record.size,
                                     fileNumber: record.fileNumber, statusChanged: record.statusChanged)
            // A key without a disk identity ages from its hashing whatever its last use, since
            // nothing would catch a rewrite under a restored date (`diskIdentity`).
            let lastUsed = key.hasDiskIdentity ? (record.lastUsed ?? record.storedAt) : record.storedAt
            guard now.timeIntervalSince(lastUsed) <= Self.maxEntryAge else { continue }
            guard entries[key] == nil else { continue }
            entries[key] = Entry(hex: record.hex, storedAt: record.storedAt, lastUsed: lastUsed)
            adoptedKeys.append(key)
        }

        // Adopted keys go at the front of the queue: they are older than anything hashed this
        // run, and eviction drops from the front. Appended, a mid-scan load would evict this
        // session's digests to keep ones read off disk. Compact first, so prepending starts at 0.
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
        // **Don't reset `unsavedChanges` here.** Adoption never raised it, so zeroing it would drop
        // the dirty flag for whatever was hashed before the load landed. The load can land mid-scan,
        // and the scan's `save()` would then write nothing and lose every digest it computed.
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

    /// Forgets every digest, in memory and on disk. **Both halves:** deleting only the file would
    /// undo itself, since the next `save()` (the duplicate scan and Verify each call one) would
    /// write the in-memory digests back out. Resetting `unsavedChanges` is right here, unlike in
    /// `adopt`, because nothing is left to write.
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
