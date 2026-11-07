import Testing
import Foundation
@testable import Sync

/// `ContentHashCache` and its wiring into `FileContentVerifier.sha256Hex`. The cache lets Verify
/// skip re-hashing a file whose key (path, mtime, size, file number, status-change time) is
/// unchanged within a session. Tests the actor directly, and on real temp files that a hit returns
/// the stored digest without re-reading the bytes.
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
        // Re-storing a live key must not grow the FIFO order, or it evicts a live entry early.
        // Cap 2, store k1 twice then k2: both survive.
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

    /// Eviction advances an index instead of shifting the array, so FIFO order must survive the
    /// compaction of the dead prefix, when every index moves, and the dead prefix must be
    /// reclaimed or `insertionOrder` grows forever, a leak survivors can't show. Over several
    /// compactions (4 of 200), 100x the cap (50 of 5000), and a cap of 1, where the index
    /// arithmetic is likeliest to go wrong (every store evicts, so `evictedPrefix` reaches the
    /// compaction threshold almost every call): the survivors are exactly the newest `cap` keys,
    /// and order storage stays within the 2x-cap ceiling.
    @Test(arguments: [(4, 200), (50, 5000), (1, 20)])
    func testFifoOrderSurvivesRepeatedCompaction(cap: Int, stores: Int) async {
        let cache = ContentHashCache(maxEntries: cap)
        let keys = (0..<stores).map { ContentHashKey(path: "/f\($0)", mtime: 1, size: 1) }

        for (i, key) in keys.enumerated() {
            await cache.store("h\(i)", for: key)
        }

        // The last `cap` are live, with their own values...
        for i in (keys.count - cap)..<keys.count {
            #expect(await cache.hash(for: keys[i]) == "h\(i)")
        }
        // ...and everything older is gone, checked across the whole history so a compaction that
        // resurrects or mis-indexes an old key is caught.
        for i in 0..<(keys.count - cap) {
            #expect(await cache.hash(for: keys[i]) == nil, "key \(i) should have been evicted")
        }
        let slots = await cache.orderSlotsInUse
        #expect(slots <= cap * 2, "order storage grew to \(slots) for a \(cap)-entry cache")
    }

    /// A key evicted and stored again comes back cleanly. It still sits in the dead prefix, so
    /// re-appending gives one key two slots, only one of which may be live.
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

        // The revived key is now the newest, so the next store evicts c, not a.
        let d = ContentHashKey(path: "/d", mtime: 1, size: 1)
        await cache.store("d1", for: d)
        #expect(await cache.hash(for: c) == nil)
        #expect(await cache.hash(for: a) == "a2")
        #expect(await cache.hash(for: d) == "d1")
    }

    /// The eviction loop relies on a key never holding two live slots, so
    /// `entries.count == insertionOrder.count - evictedPrefix`. This interleaves new keys with
    /// re-stores of keys that are live, evicted or unseen, all at the cap. A double-counted key
    /// would exceed the cap or evict a live entry early, so it checks both from outside.
    @Test func testMixedNewAndRepeatStoresKeepEvictionExact() async {
        let cap = 8
        let cache = ContentHashCache(maxEntries: cap)
        func k(_ i: Int) -> ContentHashKey { ContentHashKey(path: "/f\(i)", mtime: 1, size: 1) }

        // A reference model of the policy: FIFO by first insertion. Re-storing a live key updates
        // its value in place (`testRestoringSameKeyDoesNotDoubleCountForEviction`); re-storing an
        // evicted one appends it at the back. Not LRU: a re-store doesn't move a live key.
        var modelOrder: [Int] = []
        var modelLive: Set<Int> = []
        func modelStore(_ i: Int) {
            if !modelLive.contains(i) { modelOrder.append(i); modelLive.insert(i) }
            while modelLive.count > cap { modelLive.remove(modelOrder.removeFirst()) }
        }

        // Deterministic but adversarial ordering: after each new key, re-store one from well
        // behind it (often already evicted) and one from just behind it (usually still live).
        for i in 0..<60 {
            await cache.store("h\(i)", for: k(i)); modelStore(i)
            let farBack = i - 7
            if farBack >= 0 { await cache.store("r\(farBack)", for: k(farBack)); modelStore(farBack) }
            let justBack = i - 2
            if justBack >= 0 { await cache.store("s\(justBack)", for: k(justBack)); modelStore(justBack) }
        }

        var actual = Set<Int>()
        for i in 0..<60 where await cache.hash(for: k(i)) != nil { actual.insert(i) }

        // Never over cap: a key counted twice would have inflated the live set.
        #expect(actual.count == cap, "live entries \(actual.count) should equal the cap \(cap)")
        // Exactly the policy's set: evicting a live entry early, or keeping a dead one, shows here.
        #expect(actual == modelLive)

        // The order array is still bounded despite all the re-stores appending after eviction.
        let slots = await cache.orderSlotsInUse
        #expect(slots <= cap * 2, "order storage \(slots) exceeded the 2x ceiling")
    }

    /// The cap is a cliff, not a dial: check this before shrinking it. Eviction is FIFO and both
    /// workloads re-read files in the order they wrote them, so a working set one entry past the
    /// cap evicts each key just before the next pass asks for it, and the hit rate collapses to
    /// zero. The default must exceed a duplicates scan's size-colliding files on both providers
    /// together (Verify shares the cache): about 48k on the trees measured.
    @Test func testHitRateCollapsesOnceTheWorkingSetPassesTheCap() async {
        // Pass 2 stores on a miss, as real callers do (a miss is hashed and written back). That
        // write evicts the entry the next read wants; a read-only pass would hide the effect.
        func rescanHits(workingSet: Int, cap: Int) async -> Int {
            let cache = ContentHashCache(maxEntries: cap)
            let keys = (0..<workingSet).map { ContentHashKey(path: "/f\($0)", mtime: 1, size: 1) }
            for k in keys { await cache.store("h", for: k) }      // pass 1
            var hits = 0
            for k in keys {
                if await cache.hash(for: k) != nil { hits += 1 } else { await cache.store("h", for: k) }
            }
            return hits
        }
        // Comfortably inside the cap: every entry survives to be re-read.
        #expect(await rescanHits(workingSet: 900, cap: 1000) == 900)
        // Exactly at it: still whole.
        #expect(await rescanHits(workingSet: 1000, cap: 1000) == 1000)
        // One entry past it loses everything, not one entry.
        #expect(await rescanHits(workingSet: 1001, cap: 1000) == 0)
        // Well past it stays zero: the cache is pure overhead here.
        #expect(await rescanHits(workingSet: 2500, cap: 1000) == 0)
        // Raising the cap over the working set restores it completely.
        #expect(await rescanHits(workingSet: 2500, cap: 3000) == 2500)
    }

    // MARK: - Behavioral proof: a hit serves the stored hash without re-reading bytes

    @Test func testAHitIsServedUnreadAndASameSizeEditUnderARestoredMtimeIsAMiss() async throws {
        let dir = try makeCanonicalTempRoot(prefix: "ContentHashCacheTest")
        defer { try? FileManager.default.removeItem(at: dir) }

        // An integer-second mtime round-trips exactly through the filesystem.
        let fixedDate = Date(timeIntervalSince1970: 1_600_000_000)
        let file = dir.appendingPathComponent("cached.bin")
        try Data("AAAAAA".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)

        let cache = ContentHashCache()
        let first = await FileContentVerifier.sha256Hex(filePath: file.path, cache: cache)
        #expect(first != nil)

        // A hit is served without reading the file: a digest planted under the file's own key
        // (from the verifier's `cacheKey`) comes back instead of the real one.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let key = try #require(FileContentVerifier.cacheKey(statPath: file.path, attributes: attributes, size: 6))
        await cache.store("planted", for: key)
        let served = await FileContentVerifier.sha256Hex(filePath: file.path, cache: cache)
        #expect(served == "planted")  // served from cache, NOT re-read
        await cache.store(try #require(first), for: key)

        // Overwrite with different bytes of the same length and restore the mtime, as
        // `exiftool -P` or `touch -r` do. Path, mtime and size match, but the write moved the
        // status-change time, so this is a miss and a real re-hash.
        try Data("BBBBBB".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)

        let second = await FileContentVerifier.sha256Hex(filePath: file.path, cache: cache)
        let uncached = await FileContentVerifier.sha256Hex(filePath: file.path)
        #expect(uncached != nil)
        #expect(uncached != first)  // the bytes genuinely changed on disk
        #expect(second == uncached, "a same-size edit under a restored mtime was served the old digest")

        // Grow the file by one byte: size changes -> new key -> a real re-hash of new content.
        try Data("BBBBBBB".utf8).write(to: file)  // 7 bytes now
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)

        let grown = await FileContentVerifier.sha256Hex(filePath: file.path, cache: cache)
        #expect(grown != nil)
        #expect(grown != first)  // did not serve the stale cached value
        // It equals a fresh uncached hash of the 7-byte content: a genuine re-hash.
        let grownTruth = await FileContentVerifier.sha256Hex(filePath: file.path)
        #expect(grown == grownTruth)
    }
}
