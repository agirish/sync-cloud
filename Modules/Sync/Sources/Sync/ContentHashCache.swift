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

    /// Upper bound on retained entries; oldest are evicted first once exceeded. 20k hashes is a
    /// few MB of strings — enough to cover a very large tree while keeping memory bounded.
    private let maxEntries: Int

    private var entries: [ContentHashKey: String] = [:]
    /// Insertion order for FIFO eviction. `insertionOrder[evictedPrefix...]` are the live keys,
    /// oldest first; everything before `evictedPrefix` is already gone from `entries` and is
    /// waiting to be compacted away.
    private var insertionOrder: [ContentHashKey] = []
    /// How much of `insertionOrder`'s front has already been evicted.
    ///
    /// Eviction used to be `insertionOrder.removeFirst()`, which shifts the whole array — O(n) per
    /// eviction on a 20 000-element array of 32-byte keys. That costs nothing until the cap is
    /// reached and then costs it on EVERY subsequent store, which is exactly the sustained-load
    /// case the cap exists for: hashing a large tree past 20 000 files turned each store into a
    /// ~640 KB memmove. Advancing an index instead makes eviction O(1); the dead prefix is
    /// compacted away in one shot once it reaches half the array, so the array cannot grow without
    /// bound and each compaction drops at least half of it — amortized O(1) per store.
    private var evictedPrefix = 0

    public init(maxEntries: Int = 20_000) {
        self.maxEntries = max(1, maxEntries)
    }

    /// The cached hex digest for `key`, or `nil` if this file (at this mtime and size) has not been
    /// hashed this session.
    public func hash(for key: ContentHashKey) -> String? {
        entries[key]
    }

    /// How many slots `insertionOrder` currently occupies, live plus not-yet-compacted.
    ///
    /// Exists only so the compaction threshold can be pinned. Deferring compaction is what makes
    /// eviction amortized O(1), and the cost of getting the threshold wrong is an array that grows
    /// forever — a memory leak that every correctness test would still pass straight through,
    /// because the SURVIVORS stay right either way. Nothing outside tests should read this.
    var orderSlotsInUse: Int { insertionOrder.count }

    /// Records `hex` as the SHA-256 of `key`, evicting the oldest entry if the cap is exceeded.
    public func store(_ hex: String, for key: ContentHashKey) {
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = hex

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
}
