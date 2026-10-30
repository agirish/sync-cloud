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

    // MARK: Forgetting

    @Test func forgettingDropsTheFileAndTheSessionsOwnDigests() async throws {
        // **Both halves, and the second is the one that makes it stick.** Deleting the file alone
        // looks like it worked and then quietly undoes itself: the actor still holds this session's
        // digests, and its next `save()` — which the duplicate scan and Verify each call
        // unconditionally — writes every one of them straight back out. That is why the erase lives
        // on the cache rather than on the store, and why this test saves AFTER forgetting.
        let url = try indexURL("forget")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let cache = ContentHashCache()
        await cache.enablePersistence(at: url)
        await cache.store("abc123", for: key("/root/a.bin"))
        await cache.store("def456", for: key("/root/b.bin"))
        await cache.save()
        ContentHashIndexStore.waitForPendingWrites()
        #expect(await cache.persistedSizeOnDisk() != nil)

        await cache.forgetPersistedIndex()
        ContentHashIndexStore.waitForPendingWrites()
        #expect(await cache.persistedSizeOnDisk() == nil, "the file must be gone")
        #expect(await cache.hash(for: key("/root/a.bin")) == nil, "and so must the in-memory digest")

        // The resurrection path: a scan finishing right after the Clear.
        await cache.save()
        ContentHashIndexStore.waitForPendingWrites()
        #expect(await cache.persistedSizeOnDisk() == nil,
                "a save after forgetting must not write the forgotten digests back")

        // A fresh instance, standing in for the next launch, adopts nothing.
        let reader = ContentHashCache()
        #expect(await reader.enablePersistence(at: url) == 0)
    }

    @MainActor
    @Test func planMergePersistsTheDigestsItComputes() async throws {
        // The third hashing site. The "keep the digests" pass covered the duplicate scan and
        // Verify; `planMerge` reads BOTH trees in full through the same cache and saved nothing —
        // quit after a merge and those reads were re-paid. The fixture is two real trees on disk
        // because planMerge walks them itself.
        let root = try makeCanonicalTempRoot(prefix: "HashIndexMerge")
        defer { try? FileManager.default.removeItem(at: root) }
        let keeper = root.appendingPathComponent("keeper")
        let redundant = root.appendingPathComponent("redundant")
        for dir in [keeper, redundant] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 4096).write(to: dir.appendingPathComponent("a.bin"))
        }
        let url = try indexURL("merge")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let cache = ContentHashCache()
        await cache.enablePersistence(at: url)
        _ = await FileSyncManager.planMerge(from: redundant, into: keeper,
                                            fileManager: FileManager.default, cache: cache)
        ContentHashIndexStore.waitForPendingWrites()

        // A fresh instance, standing in for the next launch: the merge's digests must be there.
        let reader = ContentHashCache()
        #expect(await reader.enablePersistence(at: url) >= 2,
                "both trees' digests must survive to disk without waiting for a later scan to save them")
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

    // MARK: Kept while used

    private static let day: TimeInterval = 24 * 60 * 60

    /// One launch: load the file at `now`, look `keys` up at `now`, save, wait for the write.
    private func launch(_ url: URL, at now: Date, using keys: [ContentHashKey]) async -> ContentHashCache {
        let cache = ContentHashCache()
        await cache.enablePersistence(at: url, now: now)
        for key in keys { _ = await cache.hash(for: key, at: now) }
        await cache.save()
        ContentHashIndexStore.waitForPendingWrites()
        return cache
    }

    @Test func aUsedEntrySurvivesPastThirtyDaysFromHashing() async throws {
        // The batch expiry this exists to end: an entry hashed once and looked up every week was
        // dropped thirty days after the hashing, however often it had been used since.
        let url = try indexURL("kept-alive")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hashed = Date(timeIntervalSince1970: 1_800_000_000)
        let used = key("/root/used.bin", mtime: 1000)
        let unused = key("/root/unused.bin", mtime: 1000)

        let first = ContentHashCache()
        await first.enablePersistence(at: url, now: hashed)
        await first.store("u", for: used, at: hashed)
        await first.store("n", for: unused, at: hashed)
        await first.save()
        ContentHashIndexStore.waitForPendingWrites()

        // Used on day 20 by a later launch, and on day 45 by another.
        _ = await launch(url, at: hashed.addingTimeInterval(20 * Self.day), using: [used])
        _ = await launch(url, at: hashed.addingTimeInterval(45 * Self.day), using: [used])

        // Day 70: seventy days from hashing, twenty-five from the last use.
        let reader = ContentHashCache()
        let adopted = await reader.enablePersistence(at: url, now: hashed.addingTimeInterval(70 * Self.day))
        #expect(adopted == 1)
        #expect(await reader.hash(for: used) == "u")
        #expect(await reader.hash(for: unused) == nil)   // never used: gone on day 30, as before

        // The hashing stamp did not move — readers take the newest DIGEST per path by it.
        let record = try #require(ContentHashIndexStore.load(from: url).first { $0.path == used.path })
        #expect(record.storedAt == hashed)
        #expect(record.lastUsed == hashed.addingTimeInterval(45 * Self.day))
    }

    @Test func anUnusedEntryLeavesThirtyDaysAfterItsLastUse() async throws {
        let url = try indexURL("last-use")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hashed = Date(timeIntervalSince1970: 1_800_000_000)
        let a = key("/root/a.bin", mtime: 1000)

        let first = ContentHashCache()
        await first.enablePersistence(at: url, now: hashed)
        await first.store("a", for: a, at: hashed)
        await first.save()
        ContentHashIndexStore.waitForPendingWrites()
        let lastUse = hashed.addingTimeInterval(10 * Self.day)
        _ = await launch(url, at: lastUse, using: [a])

        let justInside = ContentHashCache()
        #expect(await justInside.enablePersistence(at: url, now: lastUse.addingTimeInterval(ContentHashCache.maxEntryAge - 60)) == 1)
        let justPast = ContentHashCache()
        #expect(await justPast.enablePersistence(at: url, now: lastUse.addingTimeInterval(ContentHashCache.maxEntryAge + 60)) == 0)
    }

    @Test func aScansHitsMarkTheIndexForSavingOnce() async throws {
        // A moved stamp has to reach the file or it dies with the launch — but one scan is many
        // hits, and the file must be written once for all of them, by the save the scan makes.
        let url = try indexURL("dirty-once")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hashed = Date(timeIntervalSince1970: 1_800_000_000)
        let keys = (0..<50).map { key("/root/f\($0).bin", mtime: 1000) }

        let cache = ContentHashCache()
        await cache.enablePersistence(at: url, now: hashed)
        for k in keys { await cache.store("h", for: k, at: hashed) }
        await cache.save()
        #expect(await cache.savesWritten == 1)

        // A scan two days on: fifty hits, one save, one write.
        let scan = hashed.addingTimeInterval(2 * Self.day)
        for k in keys { _ = await cache.hash(for: k, at: scan) }
        await cache.save()
        await cache.save()
        #expect(await cache.savesWritten == 2)
        ContentHashIndexStore.waitForPendingWrites()
        #expect(ContentHashIndexStore.load(from: url).allSatisfy { $0.lastUsed == scan })

        // Another scan an hour later moves nothing, so it writes nothing.
        for k in keys { _ = await cache.hash(for: k, at: scan.addingTimeInterval(3600)) }
        await cache.save()
        #expect(await cache.savesWritten == 2)
    }

    @Test func anIndexWrittenBeforeLastUsedLoadsAndCountsFromHashing() async throws {
        // Every index on disk today has `storedAt` and no `lastUsed`. It must load under the same
        // schema, and each entry's last use is taken to be its hashing.
        let url = try indexURL("old-format")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let hashed = Date(timeIntervalSince1970: 1_800_000_000)
        // `JSONEncoder`'s default date shape: seconds since 2001-01-01.
        let json = #"{"schema":1,"records":[{"path":"/root/a.bin","mtime":1000,"size":4096,"hex":"a","#
            + #""storedAt":\#(hashed.timeIntervalSinceReferenceDate),"fileNumber":7,"statusChanged":1000}]}"#
        try Data(json.utf8).write(to: url)
        let a = ContentHashKey(path: "/root/a.bin", mtime: 1000, size: 4096, fileNumber: 7, statusChanged: 1000)

        let record = try #require(ContentHashIndexStore.load(from: url).first)
        #expect(record.lastUsed == nil)
        let inside = ContentHashCache()
        #expect(await inside.enablePersistence(at: url, now: hashed.addingTimeInterval(ContentHashCache.maxEntryAge - 60)) == 1)
        #expect(await inside.hash(for: a, at: hashed) == "a")
        let past = ContentHashCache()
        #expect(await past.enablePersistence(at: url, now: hashed.addingTimeInterval(ContentHashCache.maxEntryAge + 60)) == 0)
    }

    @Test func anEntryKeptAliveStillMissesAFileRewrittenUnderItsOldDate() async throws {
        // Why keeping a used entry is safe (FR59): a write moves the status-change time the key
        // carries, so a file rewritten with its size kept and its mtime restored never matches the
        // entry — however long use has kept that entry alive.
        let dir = try makeCanonicalTempRoot(prefix: "HashIndex-rewrite")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index.json")
        let file = dir.appendingPathComponent("doc.bin")
        let fixedDate = Date(timeIntervalSince1970: 1_600_000_000)
        try Data("AAAAAA".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        func diskKey() throws -> ContentHashKey {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return try #require(FileContentVerifier.cacheKey(statPath: file.path, attributes: attributes, size: 6))
        }
        let before = try diskKey()

        let hashed = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ContentHashCache()
        await cache.enablePersistence(at: url, now: hashed)
        await cache.store("digest-of-A", for: before, at: hashed)
        await cache.save()
        ContentHashIndexStore.waitForPendingWrites()
        _ = await launch(url, at: hashed.addingTimeInterval(25 * Self.day), using: [before])

        try Data("BBBBBB".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        let after = try diskKey()
        #expect(after.path == before.path && after.mtime == before.mtime && after.size == before.size)

        let reader = ContentHashCache()
        #expect(await reader.enablePersistence(at: url, now: hashed.addingTimeInterval(50 * Self.day)) == 1)
        #expect(await reader.hash(for: before, at: hashed) == "digest-of-A")   // kept alive by use
        #expect(await reader.hash(for: after, at: hashed) == nil)             // and still not trusted
    }

    @Test func bumpingTheFingerprintSchemeMeansDeletingTheFingerprintIndex() {
        // A tripwire. An entry now lives while it is used, so after a scheme bump an unchanged
        // document keeps its old-scheme digest for good — nothing ages it out any more. If this
        // fails, ship the deletion of `content-fingerprint-index.json` with the bump.
        #expect(ContentFingerprint.scheme == "pdf-text-1")
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

    // MARK: A load landing mid-scan

    @Test func aLoadLandingMidScanDoesNotDiscardWhatWasAlreadyHashed() async throws {
        // The index load is detached at launch, so it can land while a scan is already hashing.
        // Anything measured before it arrives still has to reach the file — otherwise the scan's
        // own save finds a clean dirty flag and silently drops work it had just paid for.
        let url = try indexURL("midscan")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ContentHashIndexStore.saveInBackground(
            [ContentHashRecord(path: "/root/from-disk.bin", mtime: 1000, size: 4096,
                               hex: "disk", storedAt: now)],
            to: url)
        ContentHashIndexStore.waitForPendingWrites()

        let cache = ContentHashCache()
        await cache.store("measured", for: key("/root/mid-scan.bin", mtime: 1000), at: now)  // before the load
        await cache.enablePersistence(at: url, now: now)                                     // load lands
        await cache.save()                                                                   // scan ends
        ContentHashIndexStore.waitForPendingWrites()

        let reader = ContentHashCache()
        await reader.enablePersistence(at: url, now: now)
        #expect(await reader.hash(for: key("/root/mid-scan.bin", mtime: 1000)) == "measured")
        #expect(await reader.hash(for: key("/root/from-disk.bin", mtime: 1000)) == "disk")
    }

    @Test func adoptedEntriesAreEvictedBeforeOnesHashedThisSession() async throws {
        // Eviction drops from the front of the queue. Everything in the file was written by an
        // earlier run, so it is older than anything this session measured — putting adopted keys
        // at the back would evict fresh measurements to keep stale ones.
        let url = try indexURL("evict-order")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ContentHashIndexStore.saveInBackground([
            ContentHashRecord(path: "/root/old-a.bin", mtime: 1000, size: 4096, hex: "a",
                              storedAt: now.addingTimeInterval(-7200)),
            ContentHashRecord(path: "/root/old-b.bin", mtime: 1000, size: 4096, hex: "b",
                              storedAt: now.addingTimeInterval(-3600)),
        ], to: url)
        ContentHashIndexStore.waitForPendingWrites()

        // Cap of 2, one entry already measured this session, two adopted → one must go.
        let cache = ContentHashCache(maxEntries: 2)
        await cache.store("session", for: key("/root/session.bin", mtime: 1000), at: now)
        await cache.enablePersistence(at: url, now: now)

        #expect(await cache.count == 2)
        // The oldest adopted entry is the one dropped; this session's measurement survives.
        #expect(await cache.hash(for: key("/root/session.bin", mtime: 1000)) == "session")
        #expect(await cache.hash(for: key("/root/old-a.bin", mtime: 1000)) == nil)
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

/// The persisted-index roster. Settings sizes and clears "File digests" through it, so an index
/// missing from the list is an index the Clear button silently leaves on disk.
@Suite struct PersistedDigestIndexRosterTests {

    @Test func theRosterHoldsEveryPersistedDigestIndex() {
        // Identity, not count: this is what fails if one is dropped from the list.
        let roster = ContentHashCache.allPersisted
        #expect(roster.contains { $0 === ContentHashCache.shared })
        #expect(roster.contains { $0 === ContentHashCache.sharedFingerprints })
        #expect(roster.contains { $0 === ContentHashCache.sharedTextless })
    }

    @Test func sizingAndClearingCoverEveryCacheOnTheRoster() async throws {
        // Local instances, never the singletons: most tests in this package reach `.shared`
        // implicitly through `findDuplicates`'s default argument, and repointing it at a temp file
        // this test deletes would follow them for the rest of the process.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexRoster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let caches = [ContentHashCache(), ContentHashCache()]
        for (i, cache) in caches.enumerated() {
            await cache.enablePersistence(at: dir.appendingPathComponent("index-\(i).json"))
            await cache.store(String(repeating: "a", count: 64),
                              for: ContentHashKey(path: "/x/\(i).pdf", mtime: 1, size: 10))
            await cache.save()
        }
        ContentHashIndexStore.waitForPendingWrites()

        var individually = 0
        for cache in caches { individually += await cache.persistedSizeOnDisk() ?? 0 }
        #expect(individually > 0)
        // The sum covers EVERY cache handed to it — with only the first counted this fails.
        #expect(await ContentHashCache.totalPersistedSizeOnDisk(caches) == individually)

        await ContentHashCache.forgetAllPersistedIndexes(caches)
        ContentHashIndexStore.waitForPendingWrites()
        for (i, cache) in caches.enumerated() {
            #expect(await cache.persistedSizeOnDisk() == nil)
            #expect(await cache.hash(for: ContentHashKey(path: "/x/\(i).pdf", mtime: 1, size: 10)) == nil)
        }
    }
}
