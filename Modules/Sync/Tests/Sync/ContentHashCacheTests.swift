import Testing
import Foundation
@testable import Sync

/// Coverage for ContentHashCache and its wiring into FileContentVerifier.sha256Hex. The cache lets
/// Verify skip re-hashing a file whose (path, mtime, size) is unchanged within a session. These
/// tests exercise both the actor directly and the behavioral contract "a cache hit returns the
/// stored digest without re-reading the bytes" against real temp files.
@Suite struct ContentHashCacheTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContentHashCacheTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    // MARK: - Behavioral proof: a hit serves the stored hash without re-reading bytes

    @Test func testCachedHashServedEvenAfterBytesChangeUnderUnchangedKey() async throws {
        let dir = try makeTempDir()
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
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        let cached = await FileContentVerifier.sha256Hex(filePath: file.path, cache: ContentHashCache())
        #expect(cached == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
