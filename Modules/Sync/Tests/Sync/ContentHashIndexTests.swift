import Foundation
import Testing
@testable import Sync

@Suite struct ContentHashIndexTests {

    private func indexURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "HashIndex-\(name)")
        return dir.appendingPathComponent("index.json")
    }

    /// A key as a real APFS file gives it — with a file number and a status-change time — unless
    /// `identity` is false, as a FAT or exFAT file's is.
    private func key(_ path: String, mtime: TimeInterval = 1_700_000_000.123_456_7,
                     size: Int = 4096, identity: Bool = true) -> ContentHashKey {
        identity
            ? ContentHashKey(path: path, mtime: mtime, size: size,
                             fileNumber: UInt64(truncatingIfNeeded: path.utf8.reduce(5381) { $0 &* 33 &+ Int($1) }),
                             statusChanged: mtime + 1)
            : ContentHashKey(path: path, mtime: mtime, size: size)
    }

    // MARK: Forgetting

    @Test func forgettingDropsTheFileAndTheSessionsOwnDigests() async throws {
        // Both the file and the in-memory digests must go. Deleting only the file undoes itself:
        // the next `save()`, which the duplicate scan and Verify always call, writes the session's
        // digests back. So the erase lives on the cache, not the store, and this saves after it.
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
        // The third hashing site, after the duplicate scan and Verify: `planMerge` reads both trees
        // in full through the cache and must save, or a quit after a merge re-pays those reads.
        // Two real trees, because planMerge walks them itself.
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
        // A different instance, standing in for the next launch, answers the same lookups: the
        // reloaded key must equal one built from `attributesOfItem[.modificationDate]` at hashing
        // time; any mtime drift makes every entry miss. Awkward fractions on purpose.
        let url = try indexURL("mtime")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let mtimes: [TimeInterval] = [1_700_000_000.000_000_1, 1_700_000_000.999_999_9,
                                      1_762_345_678.123_456_789, 0.1, 1_700_000_000,
                                      1_700_000_000.123_456_7]
        let writer = ContentHashCache()
        await writer.enablePersistence(at: url)
        for (i, m) in mtimes.enumerated() {
            await writer.store("hash-\(i)", for: key("/root/f\(i).bin", mtime: m))
        }
        await writer.save()
        ContentHashIndexStore.waitForPendingWrites()

        let reader = ContentHashCache()
        let adopted = await reader.enablePersistence(at: url)
        #expect(adopted == mtimes.count)
        for (i, m) in mtimes.enumerated() {
            #expect(await reader.hash(for: key("/root/f\(i).bin", mtime: m)) == "hash-\(i)")
        }
        // A changed file does not hit the reloaded entry.
        #expect(await reader.hash(for: key("/root/f0.bin", mtime: mtimes[0] + 1000)) == nil)  // edited
        #expect(await reader.hash(for: key("/root/f0.bin", mtime: mtimes[0], size: 8192)) == nil)  // resized
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
        #expect(await cache.hash(for: key("/root/fresh.bin", mtime: 1000, identity: false)) == "f")
        #expect(await cache.hash(for: key("/root/stale.bin", mtime: 1000, identity: false)) == nil)
    }

    @Test func reloadingDoesNotResetAnEntrysAge() async throws {
        // A save that stamped everything "now" would mean nothing ever ages out, so the original
        // timestamp must survive each round trip.
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
        // An entry ages from its last use, not its hashing: one looked up every week is not dropped
        // thirty days after it was hashed.
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
        #expect(await reader.hash(for: unused) == nil)   // never used: gone on day 30

        // The hashing stamp did not move: readers take the newest digest per path by it.
        let record = try #require(ContentHashIndexStore.load(from: url).first { $0.path == used.path })
        #expect(record.storedAt == hashed)
        #expect(record.lastUsed == hashed.addingTimeInterval(45 * Self.day))
    }

    /// A key with no disk identity (a FAT or exFAT file, whose "ctime" is its mtime) is not kept
    /// alive by use: nothing would catch a rewrite under a restored date, so it ages from hashing.
    @Test func aKeyWithoutDiskIdentityAgesFromItsHashing() async throws {
        let url = try indexURL("weak-identity")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let hashed = Date(timeIntervalSince1970: 1_800_000_000)
        let weak = key("/Volumes/USB/used.bin", mtime: 1000, identity: false)
        let strong = key("/root/used.bin", mtime: 1000)

        let first = ContentHashCache()
        await first.enablePersistence(at: url, now: hashed)
        await first.store("w", for: weak, at: hashed)
        await first.store("s", for: strong, at: hashed)
        await first.save()
        ContentHashIndexStore.waitForPendingWrites()

        // Both used on day 20 and day 25.
        _ = await launch(url, at: hashed.addingTimeInterval(20 * Self.day), using: [weak, strong])
        _ = await launch(url, at: hashed.addingTimeInterval(25 * Self.day), using: [weak, strong])

        // Day 40: forty from hashing, fifteen from the last use.
        let reader = ContentHashCache()
        await reader.enablePersistence(at: url, now: hashed.addingTimeInterval(40 * Self.day))
        #expect(await reader.hash(for: strong) == "s", "a used entry with an identity is kept")
        #expect(await reader.hash(for: weak) == nil, "a used entry without one outlived thirty days from hashing")
    }

    /// A FAT or exFAT volume yields no identity, so its files key by path, mtime and size alone.
    @Test func aVolumeWithoutRealStatusChangesYieldsNoIdentity() throws {
        // The temporary directory is APFS on every Mac this runs on: the control.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin")
        try Data([1, 2, 3]).write(to: file)
        #expect(ContentHashKey.diskIdentity(atPath: file.path) != nil, "APFS answered no identity")
        #expect(ContentHashKey.diskIdentity(atPath: dir.appendingPathComponent("missing").path) == nil)
        // The same real file, its volume reported as FAT, exFAT, or not at all: no identity.
        for type in ["msdos", "exfat", "smbfs", "nfs"] {
            #expect(ContentHashKey.diskIdentity(atPath: file.path, fileSystemType: { _ in type }) == nil, "\(type)")
        }
        #expect(ContentHashKey.diskIdentity(atPath: file.path, fileSystemType: { _ in nil }) == nil)
        #expect(ContentHashKey.diskIdentity(atPath: file.path, fileSystemType: { _ in "apfs" }) != nil)
        #expect(ContentHashKey.diskIdentity(atPath: file.path, fileSystemType: { _ in "hfs" }) != nil)
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
        // A moved stamp must reach the file or it dies with the launch, but one scan's many hits
        // are written once, by the scan's own save.
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
        // An index with `storedAt` and no `lastUsed` loads under the same schema, each entry's last
        // use taken to be its hashing.
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
        // Why keeping a used entry is safe: a write moves the status-change time in the key, so a
        // file rewritten at the same size with its mtime restored never matches the old entry.
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
        // The default, which every test touching `.shared` relies on: no location means no file,
        // and never the real index.
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
        // Three keys on disk and a cap of two, so the cap has something to refuse.
        ContentHashIndexStore.saveInBackground(
            [ContentHashRecord(path: "/root/a.bin", mtime: 1000, size: 4096,
                               hex: "from-disk", storedAt: now),
             ContentHashRecord(path: "/root/b.bin", mtime: 1000, size: 4096,
                               hex: "older", storedAt: now.addingTimeInterval(-120)),
             ContentHashRecord(path: "/root/c.bin", mtime: 1000, size: 4096,
                               hex: "newer", storedAt: now.addingTimeInterval(-60))],
            to: url)
        ContentHashIndexStore.waitForPendingWrites()

        // A digest from this session is newer than the file's, so the load must not overwrite it.
        // Keys without a disk identity, as the records carry none: with one, the memory key and
        // the file's would be two keys and nothing would be overwritten either way.
        let cache = ContentHashCache(maxEntries: 2)
        await cache.store("from-memory", for: key("/root/a.bin", mtime: 1000, identity: false), at: now)
        await cache.enablePersistence(at: url, now: now)
        #expect(await cache.hash(for: key("/root/a.bin", mtime: 1000, identity: false)) == "from-memory")
        #expect(await cache.count == 2, "the load kept more than the cap")
        // The trim drops the stalest adopted key, never this session's.
        #expect(await cache.hash(for: key("/root/b.bin", mtime: 1000, identity: false)) == nil)
        #expect(await cache.hash(for: key("/root/c.bin", mtime: 1000, identity: false)) == "newer")
    }

    // MARK: A load landing mid-scan

    @Test func aLoadLandingMidScanDoesNotDiscardWhatWasAlreadyHashed() async throws {
        // The index load is detached at launch, so it can land mid-scan. What was hashed before it
        // must still reach the file, or the scan's save finds a clean dirty flag and drops it.
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
        #expect(await reader.hash(for: key("/root/from-disk.bin", mtime: 1000, identity: false)) == "disk")
    }

    @Test func adoptedEntriesAreEvictedBeforeOnesHashedThisSession() async throws {
        // Eviction drops from the front. Adopted entries are older than anything this session
        // hashed, so adopting them at the back would evict fresh digests to keep stale ones.
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
        // The same tree scanned by a fresh process reads no file bytes: every digest is on disk.
        // Asserted on hit/miss counters, not entry count, which is vacuous here: re-hashing stores
        // under a key the cache already holds, so ignoring the index leaves the count unchanged.
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

        // A new cache, as a relaunch has, loaded from the file the first scan wrote.
        let warm = ContentHashCache()
        let adopted = await warm.enablePersistence(at: url)
        #expect(adopted == coldCount)

        let second = FileSyncManager()
        await second.findDuplicates(root: root, cache: warm)
        #expect(second.duplicateGroups.count == 1)
        // Every lookup was served from the reloaded index; nothing was re-hashed.
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
        // Local instances, never the singletons: most tests reach `.shared` through
        // `findDuplicates`'s default argument, and repointing it at a temp file would follow them
        // for the rest of the process.
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
        // The sum covers every cache handed to it; counting only the first fails this.
        #expect(await ContentHashCache.totalPersistedSizeOnDisk(caches) == individually)

        await ContentHashCache.forgetAllPersistedIndexes(caches)
        ContentHashIndexStore.waitForPendingWrites()
        for (i, cache) in caches.enumerated() {
            #expect(await cache.persistedSizeOnDisk() == nil)
            #expect(await cache.hash(for: ContentHashKey(path: "/x/\(i).pdf", mtime: 1, size: 10)) == nil)
        }
    }
}
