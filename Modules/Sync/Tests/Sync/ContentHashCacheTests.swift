import Testing
import Foundation
@testable import Sync

/// Coverage for ContentHashCache and its wiring into FileContentVerifier.sha256Hex. The cache lets
/// Verify skip re-hashing a file whose (path, mtime, size) is unchanged within a session. These
/// tests exercise both the actor directly and the behavioral contract "a cache hit returns the
/// stored digest without re-reading the bytes" against real temp files.
@Suite struct ContentHashCacheTests {


    // MARK: - Direct cache behavior

    @Test func testStoreThenHashReturnsValueAndMissesOnDifferentKey() async {
        let cache = ContentHashCache()
        let key = ContentHashKey(path: "/tmp/file.bin", mtime: 1_000, size: 42)
        let other = ContentHashKey(path: "/tmp/file.bin", mtime: 1_000, size: 43)  // size differs

        #expect(await cache.hash(for: key) == nil)
        await cache.store("deadbeef", for: key)
        #expect(await cache.hash(for: key) == "deadbeef")
        // A key differing in any component (here size) is a distinct entry -> miss.
        #expect(await cache.hash(for: other) == nil)
    }

    @Test func testEvictsOldestBeyondCap() async {
        let cache = ContentHashCache(maxEntries: 2)
        let k1 = ContentHashKey(path: "/a", mtime: 1, size: 1)
        let k2 = ContentHashKey(path: "/b", mtime: 1, size: 1)
        let k3 = ContentHashKey(path: "/c", mtime: 1, size: 1)

        await cache.store("h1", for: k1)
        await cache.store("h2", for: k2)
        await cache.store("h3", for: k3)  // pushes count past 2 -> evicts oldest (k1)

        #expect(await cache.hash(for: k1) == nil)
        #expect(await cache.hash(for: k2) == "h2")
        #expect(await cache.hash(for: k3) == "h3")
    }

    @Test func testRestoringSameKeyDoesNotDoubleCountForEviction() async {
        // Re-storing an existing key must not grow the FIFO order (it would evict a live entry
        // prematurely). maxEntries = 2, store k1 twice then k2: both must survive.
        let cache = ContentHashCache(maxEntries: 2)
        let k1 = ContentHashKey(path: "/a", mtime: 1, size: 1)
        let k2 = ContentHashKey(path: "/b", mtime: 1, size: 1)

        await cache.store("h1", for: k1)
        await cache.store("h1-again", for: k1)  // update in place, no new slot
        await cache.store("h2", for: k2)

        #expect(await cache.hash(for: k1) == "h1-again")
        #expect(await cache.hash(for: k2) == "h2")
    }

    // MARK: - Eviction under sustained overflow

    /// Eviction advances an index instead of shifting the array, so the FIFO order has to keep
    /// holding after the dead prefix is compacted away — the one moment the indices all move.
    /// Drives the cache well past its cap so several compactions happen, then checks the exact
    /// survivor set: the newest `cap` keys, and nothing older.
    @Test func testFifoOrderSurvivesRepeatedCompaction() async {
        let cap = 4
        let cache = ContentHashCache(maxEntries: cap)
        let keys = (0..<200).map { ContentHashKey(path: "/f\($0)", mtime: 1, size: 1) }

        for (i, key) in keys.enumerated() {
            await cache.store("h\(i)", for: key)
        }

        // The last `cap` are live, with their own values...
        for i in (keys.count - cap)..<keys.count {
            #expect(await cache.hash(for: keys[i]) == "h\(i)")
        }
        // ...and everything older is gone. (Checked across the whole history, not just the
        // boundary, so a compaction that resurrected or mis-indexed an old key is caught.)
        for i in 0..<(keys.count - cap) {
            #expect(await cache.hash(for: keys[i]) == nil, "key \(i) should have been evicted")
        }
    }

    /// A key evicted and then stored AGAIN must come back cleanly. This is the case the index
    /// bookkeeping can get wrong: the key still sits in the dead prefix of the order array, and
    /// re-appending it means one key occupies two slots — only one of which may be live.
    @Test func testReStoringAnEvictedKeyRevivesItWithoutDisturbingTheOrder() async {
        let cache = ContentHashCache(maxEntries: 2)
        let a = ContentHashKey(path: "/a", mtime: 1, size: 1)
        let b = ContentHashKey(path: "/b", mtime: 1, size: 1)
        let c = ContentHashKey(path: "/c", mtime: 1, size: 1)

        await cache.store("a1", for: a)
        await cache.store("b1", for: b)
        await cache.store("c1", for: c)          // evicts a
        #expect(await cache.hash(for: a) == nil)

        await cache.store("a2", for: a)          // a returns, evicting b
        #expect(await cache.hash(for: a) == "a2")
        #expect(await cache.hash(for: b) == nil)
        #expect(await cache.hash(for: c) == "c1")

        // And the revived key is now the NEWEST, so the next store evicts c, not a.
        let d = ContentHashKey(path: "/d", mtime: 1, size: 1)
        await cache.store("d1", for: d)
        #expect(await cache.hash(for: c) == nil)
        #expect(await cache.hash(for: a) == "a2")
        #expect(await cache.hash(for: d) == "d1")
    }

    /// A cap of 1 is the degenerate case the index arithmetic is most likely to get wrong: every
    /// store evicts, so `evictedPrefix` reaches the compaction threshold on essentially every call.
    @Test func testCapOfOneKeepsOnlyTheNewest() async {
        let cache = ContentHashCache(maxEntries: 1)
        let keys = (0..<20).map { ContentHashKey(path: "/k\($0)", mtime: 1, size: 1) }
        for (i, key) in keys.enumerated() { await cache.store("h\(i)", for: key) }

        #expect(await cache.hash(for: keys[19]) == "h19")
        for i in 0..<19 { #expect(await cache.hash(for: keys[i]) == nil) }
    }

    // MARK: - Behavioral proof: a hit serves the stored hash without re-reading bytes

    @Test func testCachedHashServedEvenAfterBytesChangeUnderUnchangedKey() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "ContentHashCacheTest")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Integer-second mtime round-trips exactly through the filesystem, so the two hash calls
        // build an identical ContentHashKey.
        let fixedDate = Date(timeIntervalSince1970: 1_600_000_000)
        let file = dir.appendingPathComponent("cached.bin")
        try Data("AAAAAA".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)

        let cache = ContentHashCache()
        let first = await FileContentVerifier.sha256Hex(filePath: file.path, cache: cache)
        #expect(first != nil)

        // Overwrite the bytes with a different payload of the SAME length, then restore the same
        // mtime so (path, mtime, size) is unchanged. A cache hit must ignore the new bytes.
        try Data("BBBBBB".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)

        let second = await FileContentVerifier.sha256Hex(filePath: file.path, cache: cache)
        #expect(second == first)  // served from cache, NOT re-read

        // Prove the bytes genuinely changed on disk: an uncached hash sees the new content.
        let uncached = await FileContentVerifier.sha256Hex(filePath: file.path)
        #expect(uncached != nil)
        #expect(uncached != first)

        // Grow the file by one byte: size changes -> new key -> a real re-hash of new content.
        try Data("BBBBBBB".utf8).write(to: file)  // 7 bytes now
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)

        let grown = await FileContentVerifier.sha256Hex(filePath: file.path, cache: cache)
        #expect(grown != nil)
        #expect(grown != first)  // did not serve the stale cached value
        // And it equals a fresh uncached hash of the current 7-byte content -> a genuine re-hash.
        let grownTruth = await FileContentVerifier.sha256Hex(filePath: file.path)
        #expect(grown == grownTruth)
    }

    @Test func testNilCacheMatchesUncachedHashExactly() async throws {
        // The no-cache path must be byte-identical to passing no cache at all.
        let dir = try makeCanonicalTempRoot(prefix: "ContentHashCacheTest")
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        let cached = await FileContentVerifier.sha256Hex(filePath: file.path, cache: ContentHashCache())
        #expect(cached == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
