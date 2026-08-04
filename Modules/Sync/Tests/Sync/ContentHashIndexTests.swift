import Foundation
import Testing
@testable import Sync

@Suite struct ContentHashIndexTests {

    private func indexURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "HashIndex-\(name)")
        return dir.appendingPathComponent("index.json")
    }

    private func key(_ path: String, mtime: TimeInterval = 1_700_000_000.123_456_7,
                     size: Int = 4096) -> ContentHashKey {
        ContentHashKey(path: path, mtime: mtime, size: size)
    }

    // MARK: Round trip

    @Test func anEntryReloadsAndAnswersTheSameLookup() async throws {
        let url = try indexURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = ContentHashCache()
        await writer.enablePersistence(at: url)
        await writer.store("abc123", for: key("/root/a.bin"))
        await writer.save()
        ContentHashIndexStore.waitForPendingWrites()

        // A different instance, standing in for the next launch.
        let reader = ContentHashCache()
        let adopted = await reader.enablePersistence(at: url)
        #expect(adopted == 1)
        #expect(await reader.hash(for: key("/root/a.bin")) == "abc123")
    }

    @Test func aSubMillisecondMtimeSurvivesTheRoundTrip() async throws {
        // The whole index rests on this: the reloaded key must reproduce one built at hashing time
        // from `attributesOfItem[.modificationDate]`, so any drift in the mtime makes every entry
        // miss the lookup it exists to serve. Awkward fractional values on purpose.
        let url = try indexURL("mtime")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let mtimes: [TimeInterval] = [1_700_000_000.000_000_1, 1_700_000_000.999_999_9,
                                      1_762_345_678.123_456_789, 0.1, 1_700_000_000]
        let writer = ContentHashCache()
        await writer.enablePersistence(at: url)
        for (i, m) in mtimes.enumerated() {
            await writer.store("hash-\(i)", for: key("/root/f\(i).bin", mtime: m))
        }
        await writer.save()
        ContentHashIndexStore.waitForPendingWrites()

        let reader = ContentHashCache()
        await reader.enablePersistence(at: url)
        for (i, m) in mtimes.enumerated() {
            #expect(await reader.hash(for: key("/root/f\(i).bin", mtime: m)) == "hash-\(i)")
        }
    }

    @Test func aChangedFileDoesNotHitTheReloadedEntry() async throws {
        let url = try indexURL("changed")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = ContentHashCache()
        await writer.enablePersistence(at: url)
        await writer.store("abc123", for: key("/root/a.bin", mtime: 1000, size: 4096))
        await writer.save()
        ContentHashIndexStore.waitForPendingWrites()

        let reader = ContentHashCache()
        await reader.enablePersistence(at: url)
        #expect(await reader.hash(for: key("/root/a.bin", mtime: 2000, size: 4096)) == nil)  // edited
        #expect(await reader.hash(for: key("/root/a.bin", mtime: 1000, size: 8192)) == nil)  // resized
    }

    // MARK: Age cap

    @Test func entriesOlderThanTheAgeCapAreDropped() async throws {
        let url = try indexURL("age")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = now.addingTimeInterval(-ContentHashCache.maxEntryAge + 60)
        let stale = now.addingTimeInterval(-ContentHashCache.maxEntryAge - 60)
        ContentHashIndexStore.saveInBackground([
            ContentHashRecord(path: "/root/fresh.bin", mtime: 1000, size: 4096, hex: "f", storedAt: fresh),
            ContentHashRecord(path: "/root/stale.bin", mtime: 1000, size: 4096, hex: "s", storedAt: stale),
        ], to: url)
        ContentHashIndexStore.waitForPendingWrites()

        let cache = ContentHashCache()
        let adopted = await cache.enablePersistence(at: url, now: now)
        #expect(adopted == 1)
        #expect(await cache.hash(for: key("/root/fresh.bin", mtime: 1000)) == "f")
        #expect(await cache.hash(for: key("/root/stale.bin", mtime: 1000)) == nil)
    }

    @Test func reloadingDoesNotResetAnEntrysAge() async throws {
        // If a save stamped everything with "now", nothing would ever age out — the cap would be
        // dead code that looked alive. The original timestamp has to survive each round trip.
        let url = try indexURL("age-preserved")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-ContentHashCache.maxEntryAge + 3600)   // an hour to spare
        ContentHashIndexStore.saveInBackground(
            [ContentHashRecord(path: "/root/a.bin", mtime: 1000, size: 4096, hex: "a", storedAt: old)],
            to: url)
        ContentHashIndexStore.waitForPendingWrites()

        // Load it, add something new, save it back.
        let first = ContentHashCache()
        await first.enablePersistence(at: url, now: now)
        await first.store("b", for: key("/root/b.bin", mtime: 1000), at: now)
        await first.save()
        ContentHashIndexStore.waitForPendingWrites()

        // Two hours later the old entry is past the cap even though it was just rewritten.
        let later = now.addingTimeInterval(7200)
        let second = ContentHashCache()
        let adopted = await second.enablePersistence(at: url, now: later)
        #expect(adopted == 1)
        #expect(await second.hash(for: key("/root/a.bin", mtime: 1000)) == nil)   // aged out
        #expect(await second.hash(for: key("/root/b.bin", mtime: 1000)) == "b")   // still fresh
    }

    // MARK: Failure modes

    @Test func aCorruptOrForeignSchemaFileLoadsAsEmpty() async throws {
        let url = try indexURL("corrupt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        #expect(ContentHashIndexStore.load(from: url).isEmpty)              // absent
        try Data("{not json".utf8).write(to: url)
        #expect(ContentHashIndexStore.load(from: url).isEmpty)              // unreadable
        try Data(#"{"schema":999,"records":[]}"#.utf8).write(to: url)
        #expect(ContentHashIndexStore.load(from: url).isEmpty)              // wrong schema
    }

    @Test func withoutPersistenceNothingIsWritten() async throws {
        // The default, and what every existing test that touches `.shared` relies on: no location
        // configured means no file, and above all no reaching into the real index.
        let url = try indexURL("nopersist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let cache = ContentHashCache()
        await cache.store("abc", for: key("/root/a.bin"))
        await cache.save()
        ContentHashIndexStore.waitForPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await cache.hash(for: key("/root/a.bin")) == "abc")   // still a session cache
    }

    @Test func savingIsSkippedWhenNothingNewWasHashed() async throws {
        // A lens that ran entirely off cache hits must not rewrite a multi-megabyte file for
        // nothing. Observable through the file's modification date.
        let url = try indexURL("nodirty")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let cache = ContentHashCache()
        await cache.enablePersistence(at: url)
        await cache.store("abc", for: key("/root/a.bin"))
        await cache.save()
        ContentHashIndexStore.waitForPendingWrites()
        let firstWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // Only reads this time.
        _ = await cache.hash(for: key("/root/a.bin"))
        await cache.save()
        ContentHashIndexStore.waitForPendingWrites()
        let secondWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        #expect(firstWrite == secondWrite)
    }

    @Test func liveEntriesWinOverTheFileAndTheCapIsRespected() async throws {
        let url = try indexURL("merge")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ContentHashIndexStore.saveInBackground(
            [ContentHashRecord(path: "/root/a.bin", mtime: 1000, size: 4096,
                               hex: "from-disk", storedAt: now)],
            to: url)
        ContentHashIndexStore.waitForPendingWrites()

        // Something hashed THIS session is newer evidence than the file, so it must not be
        // overwritten by the load.
        let cache = ContentHashCache(maxEntries: 2)
        await cache.store("from-memory", for: key("/root/a.bin", mtime: 1000), at: now)
        await cache.enablePersistence(at: url, now: now)
        #expect(await cache.hash(for: key("/root/a.bin", mtime: 1000)) == "from-memory")
        #expect(await cache.count <= 2)
    }

    // MARK: End to end, through a real duplicate scan

    @MainActor
    @Test func aSecondLaunchDoesNotRehashAnUnchangedTree() async throws {
        // The point of the whole phase: the same tree scanned by a fresh process reads no file
        // bytes, because every digest it needs is already on disk.
        //
        // Asserted on the cache's hit/miss counters, NOT on its entry count. Entry count is the
        // obvious thing to check and it is vacuous here: re-hashing a file stores it under a key
        // the cache already holds, so a scan that ignored the index entirely would leave the count
        // exactly as this test found it and pass anyway.
        let root = try makeCanonicalTempRoot(prefix: "HashIndexScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try indexURL("scan")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Two identical files (so they collide on size and get hashed) plus a distinct one.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: root.appendingPathComponent("a/one.bin"))
        try Data(repeating: 0x41, count: 4096).write(to: root.appendingPathComponent("a/two.bin"))
        try Data(repeating: 0x42, count: 9000).write(to: root.appendingPathComponent("a/three.bin"))

        let cold = ContentHashCache()
        await cold.enablePersistence(at: url)
        let first = FileSyncManager()
        await first.findDuplicates(root: root, cache: cold)
        ContentHashIndexStore.waitForPendingWrites()
        #expect(first.duplicateGroups.count == 1)
        let coldCount = await cold.count
        #expect(coldCount > 0)

        // A brand-new cache, as a relaunch would have — loaded from the file the first scan wrote.
        let warm = ContentHashCache()
        let adopted = await warm.enablePersistence(at: url)
        #expect(adopted == coldCount)

        let second = FileSyncManager()
        await second.findDuplicates(root: root, cache: warm)
        #expect(second.duplicateGroups.count == 1)
        // Every lookup the second scan made was served from the reloaded index — nothing was read
        // off disk and re-hashed.
        #expect(await warm.lookupMisses == 0)
        #expect(await warm.lookupHits > 0)
        // …and it reached the same answer.
        #expect(second.duplicateGroups.first?.copies.count
                == first.duplicateGroups.first?.copies.count)
    }
}
