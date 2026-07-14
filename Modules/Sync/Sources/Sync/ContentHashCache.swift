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
    /// Insertion order for FIFO eviction; front is the oldest surviving entry.
    private var insertionOrder: [ContentHashKey] = []

    public init(maxEntries: Int = 20_000) {
        self.maxEntries = max(1, maxEntries)
    }

    /// The cached hex digest for `key`, or `nil` if this file (at this mtime and size) has not been
    /// hashed this session.
    public func hash(for key: ContentHashKey) -> String? {
        entries[key]
    }

    /// Records `hex` as the SHA-256 of `key`, evicting the oldest entry if the cap is exceeded.
    public func store(_ hex: String, for key: ContentHashKey) {
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = hex

        while entries.count > maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entries[oldest] = nil
        }
    }
}
