import Foundation
import Testing
@testable import Sync

/// One observation made from inside the injected classifier, mid-scan, where no assertion made
/// after the scan can reach. `nil` means the classifier never ran, which is its own failure.
private final class WarmProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func record(_ warm: Bool) { lock.lock(); defer { lock.unlock() }; value = warm }
    var observed: Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Records what the classifier was asked, across concurrent calls.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func record(_ names: [String]) { lock.lock(); defer { lock.unlock() }; calls.append(names) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var lastBatch: [String] { lock.lock(); defer { lock.unlock() }; return calls.last ?? [] }
    var everSaw: [String] { lock.lock(); defer { lock.unlock() }; return calls.flatMap { $0 } }
}

/// Counts spend-confirmer calls. Same shape as `LensAutoRescanTests`' probe, redeclared because
/// both are file-private.
private final class SpendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var prompts: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Records every quote the spend confirmer was shown.
private final class Quotes: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Int] = []
    func add(_ n: Int) { lock.lock(); defer { lock.unlock() }; seen.append(n) }
    var all: [Int] { lock.lock(); defer { lock.unlock() }; return seen }
}

@Suite struct FilingVerdictCacheTests {


    private func cacheURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "VerdictCache-\(name)")
        return dir.appendingPathComponent("verdicts.json")
    }

    private func key(_ path: String, model: String = "test-model", size: Int = 5000,
                     excluded: [String] = [], artifacts: String = "") -> FilingVerdictKey {
        // Force-unwrapped: failable only for an unknown mtime or size, both literal here.
        FilingVerdictKey(filePath: path, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                         size: size, model: model, promptVersion: 1, excludedRelativePaths: excluded,
                         artifacts: artifacts)!
    }

    private let verdict = FilingVerdict(relativePath: "Documents/Vehicles/Tesla",
                                        confidence: .high, reason: "Tesla paperwork", proposesNewFolder: true)

    // MARK: The key

    @Test func excludedPathOrderCannotSplitAnEntry() {
        // A rejection set is a SET; if its iteration order reached the key, the same file could
        // land under two keys and re-pay on alternate scans.
        let a = key("/root/f.pdf", excluded: ["Documents/A", "Documents/B"])
        let b = key("/root/f.pdf", excluded: ["Documents/B", "Documents/A"])
        #expect(a == b)
    }

    @Test func everyKeyComponentActuallySeparatesEntries() {
        // Each field, changed alone, must produce a different key. A field missing from the key
        // would serve one backend's answer for another's.
        let base = key("/root/f.pdf")
        #expect(base != key("/root/other.pdf"))
        #expect(base != key("/root/f.pdf", model: "different-model"))
        #expect(base != key("/root/f.pdf", size: 5001))
        #expect(base != key("/root/f.pdf", excluded: ["Documents/A"]))
        #expect(base != FilingVerdictKey(filePath: "/root/f.pdf",
                                         modificationDate: Date(timeIntervalSince1970: 1_700_000_001),
                                         size: 5000, model: "test-model", promptVersion: 1,
                                         artifacts: ""))
        #expect(base != FilingVerdictKey(filePath: "/root/f.pdf",
                                         modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                         size: 5000, model: "test-model", promptVersion: 2,
                                         artifacts: ""))
    }

    /// The artifact fingerprint is part of the key. A re-survey changes what every file is asked
    /// about, and a key that ignored it would replay answers composed against the old tree.
    @Test func aDifferentArtifactFingerprintIsADifferentKey() {
        let base = key("/root/f.pdf", artifacts: "abc")
        #expect(base != key("/root/f.pdf", artifacts: "def"))
        #expect(base == key("/root/f.pdf", artifacts: "abc"))
        // And the empty fingerprint — "no artifacts on this machine" — is its own value, not a
        // wildcard that matches whatever was recorded.
        #expect(base != key("/root/f.pdf", artifacts: ""))
    }

    // MARK: Staleness

    @Test func aVanishedAnchorFolderIsAMiss() {
        // Cached when Documents/Vehicles existed: the verdict proposed creating ONE folder.
        var cache = FilingVerdictCache()
        cache.record(verdict, for: key("/root/f.pdf"), providerRoot: "/root",
                     existingRelative: ["Documents", "Documents/Vehicles"], now: Date())
        #expect(cache.count == 1)

        // Vehicles has since been deleted, so the same verdict now proposes creating two: a
        // different offer from the one that was cached, so re-ask.
        let hit = cache.verdict(for: key("/root/f.pdf"), providerRoot: "/root",
                                existingRelative: ["Documents"])
        #expect(hit == nil)
    }

    @Test func aFolderCreatedSinceCachingIsStillAHit() {
        // The inverse must not invalidate: the destination got closer to existing, so the cached
        // answer is at worst as good as it was. Otherwise any new folder would mean a full re-spend.
        var cache = FilingVerdictCache()
        cache.record(verdict, for: key("/root/f.pdf"), providerRoot: "/root",
                     existingRelative: ["Documents"], now: Date())

        let hit = cache.verdict(for: key("/root/f.pdf"), providerRoot: "/root",
                                existingRelative: ["Documents", "Documents/Vehicles"])
        #expect(hit?.relativePath == "Documents/Vehicles/Tesla")
    }

    @Test func anUnrelatedNewFolderDoesNotInvalidate() {
        var cache = FilingVerdictCache()
        cache.record(verdict, for: key("/root/f.pdf"), providerRoot: "/root",
                     existingRelative: ["Documents", "Documents/Vehicles"], now: Date())
        let hit = cache.verdict(for: key("/root/f.pdf"), providerRoot: "/root",
                                existingRelative: ["Documents", "Documents/Vehicles", "Photos/2026"])
        #expect(hit != nil)
    }

    // MARK: Persistence

    @Test func roundTripsThroughJSON() throws {
        var cache = FilingVerdictCache()
        cache.record(verdict, for: key("/root/f.pdf"), providerRoot: "/root",
                     existingRelative: ["Documents", "Documents/Vehicles"], now: Date())
        let url = try cacheURL("roundtrip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FilingVerdictStore.save(cache, to: url))
        let reloaded = FilingVerdictStore.load(from: url)
        #expect(reloaded == cache)
        #expect(reloaded.verdict(for: key("/root/f.pdf"), providerRoot: "/root",
                                 existingRelative: ["Documents", "Documents/Vehicles"]) != nil)
    }

    /// A cache file that exists but can't be opened (mode 000, an ACL, an I/O error) loads as
    /// empty, but its bytes are moved aside so the next save doesn't overwrite up to ~10MB of paid
    /// answers. Re-asking is acceptable; destroying the bytes is not.
    @Test func anUnopenableCacheFileIsKeptRatherThanOverwritten() throws {
        let url = try cacheURL("mode000")
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            for aside in setAsidesBeside(url) {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aside.path)
            }
            try? fm.removeItem(at: url.deletingLastPathComponent())
        }
        var cache = FilingVerdictCache()
        cache.record(verdict, for: key("/root/f.pdf"), providerRoot: "/root",
                     existingRelative: ["Documents", "Documents/Vehicles"], now: Date())
        #expect(FilingVerdictStore.save(cache, to: url))
        let original = try #require(fm.contents(atPath: url.path))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        #expect(FilingVerdictStore.load(from: url).count == 0)   // still degrades to empty

        // ...but the paid verdicts were moved aside, where the next save cannot land on them.
        // The kept name is per-episode (``UnreadableSetAside``), so it is discovered, not assumed.
        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
        #expect(fm.contents(atPath: kept.path) == original,
                "the paid verdicts were left where the next save overwrites them")
        #expect(FilingVerdictStore.save(FilingVerdictCache(), to: url))
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
        #expect(fm.contents(atPath: kept.path) == original,
                "the save after the failed load destroyed the set-aside")
        #expect(setAsidesBeside(url).count == 1, "one episode produced more than one set-aside")
    }

    /// The same promise for bytes that open but don't decode, such as a truncated write.
    @Test func aCorruptCacheFileIsKeptRatherThanOverwritten() throws {
        let url = try cacheURL("corrupt-kept")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{not json — half a 10MB write".utf8)
        try corrupt.write(to: url)

        #expect(FilingVerdictStore.load(from: url).count == 0)

        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "the corrupt cache was left where the next save overwrites it")
    }

    // MARK: Bounds

    @Test func trimKeepsTheNewestEntries() {
        var cache = FilingVerdictCache()
        for i in 0..<10 {
            cache.record(verdict, for: key("/root/f\(i).pdf"), providerRoot: "/root",
                         existingRelative: ["Documents", "Documents/Vehicles"],
                         now: Date(timeIntervalSince1970: 1000 + Double(i)))
        }
        cache.trim(to: 4)
        #expect(cache.count == 4)
        // The four most recently written survive.
        for i in 6..<10 {
            #expect(cache.verdict(for: key("/root/f\(i).pdf"), providerRoot: "/root",
                                  existingRelative: ["Documents", "Documents/Vehicles"]) != nil)
        }
        #expect(cache.verdict(for: key("/root/f0.pdf"), providerRoot: "/root",
                              existingRelative: ["Documents", "Documents/Vehicles"]) == nil)
    }

    @Test func removeAllUnderRootForgetsOnlyThatProvider() {
        var cache = FilingVerdictCache()
        let existing: Set<String> = ["Documents", "Documents/Vehicles"]
        cache.record(verdict, for: key("/iCloud/f.pdf"), providerRoot: "/iCloud",
                     existingRelative: existing, now: Date())
        cache.record(verdict, for: key("/Dropbox/f.pdf"), providerRoot: "/Dropbox",
                     existingRelative: existing, now: Date())

        cache.removeAll(under: "/iCloud")
        #expect(cache.count == 1)
        #expect(cache.verdict(for: key("/Dropbox/f.pdf"), providerRoot: "/Dropbox",
                              existingRelative: existing) != nil)
    }

    // MARK: End to end, through the manager

    /// Builds a fixture folder with one loose file that a classifier can place.
    private func fixture(_ name: String) throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "VerdictScan-\(name)")
        try writeFilingFile(root.appendingPathComponent("Documents/Family/Son/.keep"), bytes: 1)
        try writeFilingFile(root.appendingPathComponent("Downloads/mystery-scan-0042.pdf"))
        return root
    }

    /// `fixture(name)`, a cache file of the same name, and the fixture's Downloads folder.
    private func scanFixture(_ name: String) throws -> (root: URL, url: URL, downloads: URL) {
        let root = try fixture(name)
        return (root, try cacheURL(name), root.appendingPathComponent("Downloads"))
    }

    private func remove(_ root: URL, _ url: URL) {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// `identity` is the identity for both tiers by default, which suits tests about the cache key.
    /// `refineIdentity` overrides the refine tier alone, for tests about the paid pass. A cloud
    /// identity belongs only on `refineIdentity`: on `identity` it makes the scan skip
    /// classification (`freePassWouldReachAPaidBackend`), since `Sync` refuses a paid route for
    /// `.free` rather than be billed.
    @MainActor
    private func manager(cacheAt url: URL, log: CallLog,
                         identity: String = "test-model",
                         refineIdentity: String? = nil) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingVerdictCacheURL = url
        m.filingBackendIdentity = { tier in tier == .refine ? (refineIdentity ?? identity) : identity }
        m.filingClassifier = { _, files, _ in
            log.record(files.map(\.fileName))
            var out: [String: FilingVerdict] = [:]
            for f in files {
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Son",
                                                confidence: .high, reason: "Son’s record")
            }
            return out
        }
        return m
    }

    /// A manager whose refine pass routes to a cloud model with the cloud toggle on, the only
    /// configuration in which `cloudSpendAllows` consults the confirmer. The scan stays free.
    @MainActor
    private func refiningManager(cacheAt url: URL, log: CallLog, suite: String,
                                 confirm: @escaping @MainActor (FilingSpendPreflight) -> Bool)
    -> FileSyncManager {
        let m = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-opus-5")
        let scratch = ScratchDefaults(suite)
        m.filingContentDefaults = scratch
        m.filingCloudRefineConfigured = { true }
        m.filingCloudSpendConfirmer = confirm
        return m
    }

    /// Runs a scan and waits for the cache write to land. These tests build a second manager to
    /// prove the entry reached disk, and the write is asynchronous, so without the barrier they
    /// would race it.
    @MainActor
    private func scan(_ m: FileSyncManager, _ folder: URL, root: URL,
                      ignoringCache: Bool = false) async {
        await m.findFilingSuggestions(folder: folder, providerRoot: root, ignoringCache: ignoringCache)
        FilingVerdictStore.waitForPendingWrites()
    }

    /// Scans, then refines everything the scan published: Suggest homes, then Refine.
    @MainActor
    private func scanThenRefine(_ m: FileSyncManager, _ folder: URL, root: URL) async {
        await scan(m, folder, root: root)
        await m.refineFilingSuggestions(m.filingSuggestions)
        FilingVerdictStore.waitForPendingWrites()
    }

    @MainActor
    @Test func anUnchangedFolderIsNotReclassified() async throws {
        // A second scan of an untouched folder must produce identical suggestions while asking
        // the backend nothing. Both halves matter: no calls with different results would be a cache
        // that changed the answer, and the same results with a call would be one that saved nothing.
        let (root, url, downloads) = try scanFixture("equivalence")
        defer { remove(root, url) }

        let log = CallLog()
        let first = manager(cacheAt: url, log: log)
        await scan(first, downloads, root: root)
        let firstResults = first.filingSuggestions
        #expect(log.count == 1)
        #expect(!firstResults.isEmpty)
        #expect(firstResults.first?.best?.fromAI == true)

        // A fresh manager, so the hit has to come off disk rather than out of memory.
        let second = manager(cacheAt: url, log: log)
        await scan(second, downloads, root: root)

        #expect(log.count == 1)                              // the backend was never consulted again
        #expect(second.filingSuggestions == firstResults)    // and the answer is the same one
    }

    @MainActor
    @Test func reuseIsPublishedWithTheResultsAndClearedWithThem() async throws {
        // The figure the "reused" pill reads. It is published with the suggestions, not as the
        // scan runs, or a cancelled scan would relabel the previous results with its numbers.
        let (root, url, downloads) = try scanFixture("reuse-published")
        defer { remove(root, url) }

        let log = CallLog()
        let first = manager(cacheAt: url, log: log)
        await scan(first, downloads, root: root)
        #expect(first.filingLastCacheReuse == nil)      // nothing to reuse on a cold cache

        let second = manager(cacheAt: url, log: log)
        await scan(second, downloads, root: root)
        #expect(second.filingLastCacheReuse == FileSyncManager.FilingCacheReuse(reused: 1, classified: 0))

        second.clearFiling()
        #expect(second.filingLastCacheReuse == nil)     // never outlives the results it describes
    }

    @MainActor
    @Test func aChangedFileIsReclassified() async throws {
        let (root, url, downloads) = try scanFixture("changed")
        defer { remove(root, url) }

        let log = CallLog()
        await scan(manager(cacheAt: url, log: log), downloads, root: root)
        #expect(log.count == 1)

        // Rewrite the file at a different size, so the key's identity of "this file" changes.
        try writeFilingFile(downloads.appendingPathComponent("mystery-scan-0042.pdf"), bytes: 9000)
        await scan(manager(cacheAt: url, log: log), downloads, root: root)

        #expect(log.count == 2)
        #expect(log.lastBatch == ["mystery-scan-0042.pdf"])
    }

    @MainActor
    @Test func switchingFromTheOnDeviceModelToClaudeReclassifies() async throws {
        // Serving an on-device answer as Claude's is the silent substitution the identity exists to
        // prevent. Exercised through refine, the only pass whose backend can vary; the scan is pinned
        // to on-device by its tier.
        let (root, url, downloads) = try scanFixture("backend")
        defer { remove(root, url) }

        let log = CallLog()
        let onDevice = manager(cacheAt: url, log: log, refineIdentity: FileSyncManager.onDeviceBackendIdentity)
        await scanThenRefine(onDevice, downloads, root: root)
        #expect(log.count == 2)                       // one free scan, one refine

        // Same file, same everything, except the backend the refine names.
        let claude = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-opus-5")
        await scanThenRefine(claude, downloads, root: root)

        // The scan reused its cached on-device verdict; the refine did not reuse the on-device one.
        #expect(log.count == 3)
        #expect(claude.filingLastRefine?.classified == 1)
        #expect(claude.filingLastRefine?.reused == 0)
    }

    @MainActor
    @Test func switchingBetweenClaudeModelsReusesTheSavedAnswers() async throws {
        // Any Claude model's saved answer counts (TE335, KR-C), so a model change doesn't pay again.
        let (root, url, downloads) = try scanFixture("claudeModels")
        defer { remove(root, url) }

        let log = CallLog()
        let haiku = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-haiku-4-5")
        await scanThenRefine(haiku, downloads, root: root)
        #expect(log.count == 2)

        let opus = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-opus-5")
        await scanThenRefine(opus, downloads, root: root)

        #expect(log.count == 2, "neither the scan nor the refine asked again")
        #expect(opus.filingLastRefine?.classified == 0)
        #expect(opus.filingLastRefine?.reused == 1)
    }

    @MainActor
    @Test func refiningTwiceOnTheSameModelIsFree() async throws {
        // The direction that costs money if it breaks: an unchanged file this model has already
        // answered must not be sent again. The same guarantee as
        // `anUnchangedFolderIsNotReclassified`, on the pass where a miss is billed.
        let (root, url, downloads) = try scanFixture("refine-twice")
        defer { remove(root, url) }

        let log = CallLog()
        let first = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-opus-5")
        await scanThenRefine(first, downloads, root: root)
        #expect(log.count == 2)
        let refinedResults = first.filingSuggestions

        let second = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-opus-5")
        await scanThenRefine(second, downloads, root: root)
        #expect(log.count == 2)                            // neither pass asked anything
        #expect(second.filingSuggestions == refinedResults)
        #expect(second.filingLastRefine == FileSyncManager.FilingRefineSummary(
            asked: 1, reused: 1, classified: 0, changed: 0))
    }

    @MainActor
    @Test func ignoringCacheReasksButStillRecords() async throws {
        let (root, url, downloads) = try scanFixture("ignoring")
        defer { remove(root, url) }

        let log = CallLog()
        await scan(manager(cacheAt: url, log: log), downloads, root: root)
        #expect(log.count == 1)

        // "Rescan (ignore cache)" asks again despite a warm entry…
        await scan(manager(cacheAt: url, log: log), downloads, root: root, ignoringCache: true)
        #expect(log.count == 2)

        // …and the fresh answer is still written, so the next ordinary scan is free again.
        await scan(manager(cacheAt: url, log: log), downloads, root: root)
        #expect(log.count == 2)
    }

    // MARK: A backend the app cannot name
    //
    // `filingBackendIdentity` returning nil means "I cannot vouch for which backend will run", and
    // must switch the cache off for the scan, read and write. Falling back to the configured
    // identity would cache an on-device answer under a Claude model's name.
    //
    // Two tests, because one fixture can't discriminate both halves. The read half needs the
    // fallback identity to equal the warm entry's, so a fallback would hit; the write half needs it
    // to differ, so an errant write lands as a second entry. Each must fail if a `??` fallback to
    // `configuredFilingBackendIdentity` is restored.

    @MainActor
    @Test func aBackendTheAppCannotNameIsNotServedFromTheCache() async throws {
        let (root, url, downloads) = try scanFixture("nil-identity-read")
        defer { remove(root, url) }

        let log = CallLog()
        // The warm entry is keyed on the identity a fallback would produce: `on-device` is what
        // `configuredFilingBackendIdentity` answers with the cloud toggle off.
        let vouched = manager(cacheAt: url, log: log, identity: FileSyncManager.onDeviceBackendIdentity)
        await scan(vouched, downloads, root: root)
        #expect(log.count == 1)

        let unvouched = manager(cacheAt: url, log: log, identity: FileSyncManager.onDeviceBackendIdentity)
        unvouched.filingBackendIdentity = { _ in nil }
        await scan(unvouched, downloads, root: root)
        #expect(log.count == 2, "a warm entry must not be served to a scan whose backend the app could not name")
    }

    @MainActor
    @Test func aBackendTheAppCannotNameWritesNothingToTheCache() async throws {
        let (root, url, downloads) = try scanFixture("nil-identity-write")
        defer { remove(root, url) }

        let log = CallLog()
        // `test-model` here, different from the `on-device` a fallback would produce, so a write
        // that shouldn't happen lands as a second entry rather than overwriting this one.
        await scan(manager(cacheAt: url, log: log), downloads, root: root)
        #expect(log.count == 1)

        let unvouched = manager(cacheAt: url, log: log)
        unvouched.filingBackendIdentity = { _ in nil }
        await scan(unvouched, downloads, root: root)

        let after = manager(cacheAt: url, log: log)
        #expect(await after.filingVerdictCacheCount() == 1,
                "an unvouched scan must add no entry — a fallback identity would have cached its answer under whatever Settings happened to say")
    }

    @MainActor
    @Test func ignoringTheCacheStillWarmsItOffTheMainActor() async throws {
        // "Rescan (ignore cache)" has no use for the read, but must still warm the memo through
        // the async accessor; otherwise `recordFilingVerdicts` loads it through the synchronous
        // one, decoding a file of up to ~12 MB on the main actor mid-scan.
        //
        // Asserted at classify time, not after the scan: recording warms the memo either way, so
        // only a probe from inside the classifier (after the cache split, before recording) can
        // tell which accessor loaded it. Fails if the ignoring path skips the async load.
        let (root, url, downloads) = try scanFixture("ignore-warms")
        defer { remove(root, url) }

        let log = CallLog()
        await scan(manager(cacheAt: url, log: log), downloads, root: root)

        // A fresh manager whose memo is cold, told to ignore the cache.
        let ignoring = manager(cacheAt: url, log: log)
        #expect(ignoring.filingVerdictCache == nil, "the fixture must start cold")

        let warmAtClassify = WarmProbe()
        ignoring.filingClassifier = { [weak ignoring] _, files, _ in
            log.record(files.map(\.fileName))
            if let ignoring {
                await MainActor.run { warmAtClassify.record(ignoring.filingVerdictCache != nil) }
            }
            return files.reduce(into: [:]) { out, f in
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Son",
                                                confidence: .high, reason: "Son’s record")
            }
        }
        await scan(ignoring, downloads, root: root, ignoringCache: true)

        #expect(warmAtClassify.observed == true,
                "the ignoring scan must warm the memo through the async accessor BEFORE it reaches the synchronous one in recordFilingVerdicts")
        #expect(ignoring.filingVerdictCacheCountNow == 1)
    }

    @MainActor
    @Test func clearingCannotBeOvertakenByAQueuedScanWrite() async throws {
        // A clear must go through the store's write queue, behind any scan write already on it
        // (`recordFilingVerdicts` queues one mid-scan, multi-megabyte at the entry cap). A clear
        // written synchronously could land first and be overwritten by the pre-clear snapshot, and
        // the next launch would reload every verdict the user had just cleared. The large snapshot
        // queued first stands in for that scan write, big enough that its encode outlasts the clear.
        let url = try cacheURL("clear-race")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var big = FilingVerdictCache()
        for i in 0..<20_000 {
            big.record(verdict, for: key("/root/folder-\(i % 40)/file-\(i).pdf"), providerRoot: "/root",
                       existingRelative: ["Documents", "Documents/Vehicles"],
                       now: Date(timeIntervalSince1970: 1000 + Double(i)))
        }

        let m = FileSyncManager()
        m.filingVerdictCacheURL = url
        FilingVerdictStore.saveInBackground(big, to: url)   // the scan's in-flight write
        m.clearFilingVerdictCache()                          // the user's Clear, a beat later
        FilingVerdictStore.waitForPendingWrites()

        #expect(FilingVerdictStore.load(from: url).count == 0,
                "the Clear must be the last write to land — a queued pre-clear snapshot must not resurrect the file")
    }

    @MainActor
    @Test func withNoCacheURLNothingIsReused() async throws {
        // The default for the CLI and most tests: no location configured, no cache, and no
        // reaching into the real Application Support directory.
        let root = try fixture("nourl")
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        for _ in 0..<2 {
            let m = FileSyncManager()
            #expect(m.filingVerdictCacheURL == nil)
            m.filingClassifier = { _, files, _ in log.record(files.map(\.fileName)); return [:] }
            await m.findFilingSuggestions(folder: downloads, providerRoot: root)
        }
        #expect(log.count == 2)
    }

    @MainActor
    @Test func aCancelledScanStillKeepsTheAnswersItPaidFor() async throws {
        // Recording happens before the scan's cancellation check. By the time the classifier
        // returns the cloud call has been billed, and discarding the answers because the user
        // cancelled a moment later would mean paying for them twice.
        let (root, url, downloads) = try scanFixture("cancelled")
        defer { remove(root, url) }

        let log = CallLog()
        let cancelling = FileSyncManager()
        cancelling.filingVerdictCacheURL = url
        cancelling.filingBackendIdentity = { _ in "test-model" }
        cancelling.filingClassifier = { _, files, _ in
            log.record(files.map(\.fileName))
            // Cancel the scan from inside the call: the answer exists and has been paid for, and
            // the scan is abandoned immediately afterwards.
            withUnsafeCurrentTask { $0?.cancel() }
            var out: [String: FilingVerdict] = [:]
            for f in files {
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Son",
                                                confidence: .high, reason: "Son’s record")
            }
            return out
        }
        // Run it in its own task: `withUnsafeCurrentTask` cancels whichever task runs the scan, and
        // awaiting the scan directly would cancel the test's task and every later await in it.
        await Task { await cancelling.findFilingSuggestions(folder: downloads, providerRoot: root) }.value
        FilingVerdictStore.waitForPendingWrites()

        #expect(log.count == 1)
        #expect(cancelling.filingSuggestions.isEmpty)      // the scan really did abandon its results
        #expect(!cancelling.hasSuggestedFiling)

        // …but the paid-for answer survived, so the next scan doesn't buy it again.
        let next = manager(cacheAt: url, log: log)
        await scan(next, downloads, root: root)
        #expect(log.count == 1)
        #expect(next.filingSuggestions.first?.best?.fromAI == true)
    }

    @MainActor
    @Test func aDeclinedSpendIsNotCountedAsClassified() async throws {
        // The refine pill reads this, and it is the user's evidence about cost. If the spend
        // guardrail declines, nothing was sent, and reporting the batch size would claim work (and
        // money) that never happened.
        let root = try makeCanonicalTempRoot(prefix: "VerdictDeclined")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("declined")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeFilingFile(root.appendingPathComponent("Documents/Family/Son/.keep"), bytes: 1)
        try writeFilingFile(root.appendingPathComponent("Downloads/first.pdf"))
        let downloads = root.appendingPathComponent("Downloads")

        // One refine at the paid model, so `first.pdf` has an Opus answer on file.
        let log = CallLog()
        let bought = refiningManager(cacheAt: url, log: log, suite: "verdictBought") { _ in true }
        await scanThenRefine(bought, downloads, root: root)
        #expect(log.count == 2)

        // A second file arrives, and the guardrail refuses the spend for it.
        try writeFilingFile(downloads.appendingPathComponent("second.pdf"))
        let declining = refiningManager(cacheAt: url, log: log, suite: "verdictDeclined") { _ in false }
        await scanThenRefine(declining, downloads, root: root)

        // The free scan classified both files; the refine sent nothing.
        #expect(log.count == 3)
        // `outcome: .declined` is the point: `classified: 0` alone is also what an exhausted cache
        // looks like.
        #expect(declining.filingLastRefine
                == FileSyncManager.FilingRefineSummary(asked: 2, reused: 1, classified: 0,
                                                       changed: 0, outcome: .declined))
        // A decline is not a failure: the free pass's suggestions are still standing, and the one
        // file that had a cached Opus answer still got it.
        #expect(declining.filingSuggestions.count == 2)
        #expect(declining.filingSuggestions.allSatisfy { $0.best != nil })
    }

    @MainActor
    @Test func clearingForgetsEverySavedVerdict() async throws {
        // Settings' Clear button. It throws away work that may have been paid for, so it must reach
        // the file, not just the in-memory copy: a clear that a relaunch undoes is worse than none.
        let (root, url, downloads) = try scanFixture("clear")
        defer { remove(root, url) }

        let log = CallLog()
        let first = manager(cacheAt: url, log: log)
        await scan(first, downloads, root: root)
        #expect(first.filingVerdictCacheCountNow == 1)   // memo warm from the scan

        first.clearFilingVerdictCache()
        FilingVerdictStore.waitForPendingWrites()
        #expect(first.filingVerdictCacheCountNow == 0)

        // A fresh manager reading the file agrees: the clear was persisted. Awaited, because this
        // memo is cold and that read is the load, as in the Settings readout's first read.
        let second = manager(cacheAt: url, log: log)
        #expect(await second.filingVerdictCacheCount() == 0)
        await scan(second, downloads, root: root)
        #expect(log.count == 2)                       // and the backend is consulted again
    }

    @MainActor
    @Test func theSpendPreflightPricesOnlyTheMisses() async throws {
        // Why the cache split happens before `cloudSpendAllows`: the preflight is the figure the
        // user approves, and quoting files that are already answered would make it a fiction (and
        // re-read their contents for nothing).
        let root = try makeCanonicalTempRoot(prefix: "VerdictPreflight")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("preflight")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeFilingFile(root.appendingPathComponent("Documents/Family/Son/.keep"), bytes: 1)
        for i in 0..<4 { try writeFilingFile(root.appendingPathComponent("Downloads/scan-\(i).pdf")) }
        let downloads = root.appendingPathComponent("Downloads")

        let quotes = Quotes()
        let log = CallLog()

        func cloudManager(_ suite: String) -> FileSyncManager {
            refiningManager(cacheAt: url, log: log, suite: suite) { preflight in
                quotes.add(preflight.fileCount); return true
            }
        }

        await scanThenRefine(cloudManager("verdictPreflight1"), downloads, root: root)
        #expect(quotes.all == [4])          // first refine: all four priced and sent
        #expect(log.lastBatch.count == 4)

        // Add a fifth file; the other four are unchanged and already answered by this model.
        try writeFilingFile(downloads.appendingPathComponent("scan-4.pdf"))
        let second = cloudManager("verdictPreflight2")
        await scanThenRefine(second, downloads, root: root)

        #expect(quotes.all == [4, 1])       // the quote covers ONE file, not five
        #expect(log.lastBatch == ["scan-4.pdf"])
        #expect(second.filingLastRefine?.reused == 4)
    }

    @MainActor
    @Test func aCachedVerdictWhoseAnchorFolderVanishedIsRePricedNotServedStale() async throws {
        // The staleness rule, end to end, on the pass where being wrong costs money. A cached
        // verdict whose anchor folder has since been deleted is a miss, so it must be re-asked and
        // must appear in the quote the user approves; a quote that omitted it would understate
        // the bill.
        let (root, url, downloads) = try scanFixture("stale-anchor")
        defer { remove(root, url) }

        let quotes = Quotes()
        let log = CallLog()

        // A paid refine caches a verdict naming Documents/Family/Son, which exists today.
        let first = refiningManager(cacheAt: url, log: log, suite: "verdictStale1") {
            quotes.add($0.fileCount); return true
        }
        await scanThenRefine(first, downloads, root: root)
        #expect(quotes.all == [1])
        #expect(first.filingLastRefine?.classified == 1)

        // Documents/Family goes away, so the cached destination now proposes more new folders than
        // it did when cached, and the staleness rule turns the hit into a miss.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Documents/Family"))

        let second = refiningManager(cacheAt: url, log: log, suite: "verdictStale2") {
            quotes.add($0.fileCount); return true
        }
        await scanThenRefine(second, downloads, root: root)

        #expect(quotes.all == [1, 1], "the stale hit was not re-priced")
        #expect(second.filingLastRefine?.classified == 1)
        #expect(second.filingLastRefine?.reused == 0)
    }

    @MainActor
    @Test func aScanNeverPricesAnythingBecauseItCannotSpend() async throws {
        // The companion to the tests above: the configuration that prices a refine prices nothing
        // for the scan before it. Without this, every quote count above would be equally consistent
        // with the scan doing the pricing.
        let (root, url, downloads) = try scanFixture("scan-unpriced")
        defer { remove(root, url) }

        let log = CallLog()
        let prompts = SpendProbe()
        let m = refiningManager(cacheAt: url, log: log, suite: "verdictScanUnpriced") { _ in
            prompts.record(); return true
        }

        await scan(m, downloads, root: root)
        #expect(prompts.prompts == 0)   // the scan priced nothing…
        #expect(log.count == 1)         // …and still classified, at the free tier

        await m.refineFilingSuggestions(m.filingSuggestions)
        #expect(prompts.prompts == 1)   // the refine is what asks
        #expect(log.count == 2)
    }

    // MARK: The artifacts are part of the question

    private func writeArtifacts(_ dir: URL, id: String, profileFolders: Int) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let folders = (0..<profileFolders).map { #"{"path":"F\#($0)","depth":1,"fileCount":1,"subfolderCount":0,"extensions":{},"axes":{},"anchors":[],"isLeaf":true,"role":"destination"}"# }
        let profile = #"{"schemaVersion":1,"profileId":"\#(id)","root":"~","folders":[\#(folders.joined(separator: ","))]}"#
        try profile.write(to: dir.appendingPathComponent("\(id)/folder-profile.json"),
                          atomically: true, encoding: .utf8)
    }

    /// A re-survey must not replay answers composed against the old tree. The artifacts decide the
    /// router's shortlist, which is the classifier's folder menu, so regenerating them changes what
    /// every file is asked, and the fingerprint must change with them.
    @Test func regeneratingTheArtifactsChangesTheFingerprint() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeArtifacts(dir, id: "me", profileFolders: 10)
        let before = FilingProfileStore.fingerprint(id: "me", in: dir)
        #expect(before?.isEmpty == false)
        #expect(FilingProfileStore.fingerprint(id: "me", in: dir) == before, "not stable across reads")

        try writeArtifacts(dir, id: "me", profileFolders: 11)   // re-surveyed
        #expect(FilingProfileStore.fingerprint(id: "me", in: dir) != before)
    }

    /// An unsurveyed tree has no artifacts and an empty fingerprint, so the field is no reason to
    /// miss on a machine that never had a profile.
    @Test func noArtifactsMeansAnEmptyFingerprint() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-none-\(UUID().uuidString)")
        #expect(FilingProfileStore.fingerprint(id: "me", in: dir) == "")
    }

    // MARK: - An unknown fact is not a value

    /// A file whose mtime can't be read has no key, rather than a key that says 1970. A placeholder
    /// value a real file can have would let a file whose mtime stays unreadable while its contents
    /// change keep its key and be served its old, possibly paid-for verdict. Same rule as a nil
    /// `filingArtifactFingerprint`: an unreadable component is an unknown.
    @Test func anUnreadableModificationDateOrSizeYieldsNoKeyAtAll() {
        #expect(FilingVerdictKey(filePath: "/r/TODO/a.pdf", modificationDate: nil, size: 10,
                                 model: "m", promptVersion: 1, artifacts: "a") == nil)
        #expect(FilingVerdictKey(filePath: "/r/TODO/a.pdf",
                                 modificationDate: Date(timeIntervalSince1970: 1), size: nil,
                                 model: "m", promptVersion: 1, artifacts: "a") == nil)
    }

    /// A file dated exactly at the epoch is ordinary and keys normally; one whose date can't be
    /// read must not mint the same key.
    @Test func aFileDatedAtTheEpochKeysNormallyAndAnUnreadableOneDoesNot() throws {
        let epoch = try #require(FilingVerdictKey(filePath: "/r/TODO/a.pdf",
                                                  modificationDate: Date(timeIntervalSince1970: 0),
                                                  size: 0, model: "m", promptVersion: 1,
                                                  artifacts: "a"),
                                 "an epoch-dated, empty file is ordinary and must still be keyable")
        #expect(epoch.modifiedMillis == 0)
        #expect(epoch.size == 0)
        #expect(FilingVerdictKey(filePath: "/r/TODO/a.pdf", modificationDate: nil, size: nil,
                                 model: "m", promptVersion: 1, artifacts: "a") == nil,
                "the unreadable case still mints the same key as the epoch-dated one")
    }

    /// An ordinary readable file still keys: the guard must not become "never cache".
    @Test func aReadableFileStillKeysAsBefore() throws {
        let k = try #require(FilingVerdictKey(filePath: "/r/TODO/a.pdf",
                                              modificationDate: Date(timeIntervalSince1970: 1.5),
                                              size: 10, model: "m", promptVersion: 1,
                                              artifacts: "a"))
        #expect(k.modifiedMillis == 1500)
        #expect(k.size == 10)
    }

    /// A key written without the `artifacts` field still decodes: a shape change that throws
    /// discards the whole cache file, and those entries are honest answers for a tree with no
    /// artifacts.
    @Test func aKeyWrittenBeforeTheFieldExistedStillDecodes() throws {
        let json = #"{"filePath":"/r/a.pdf","modifiedMillis":1000,"size":10,"model":"on-device","promptVersion":4,"excludedRelativePaths":[]}"#
        let k = try JSONDecoder().decode(FilingVerdictKey.self, from: Data(json.utf8))
        #expect(k.artifacts.isEmpty)
        #expect(k.filePath == "/r/a.pdf")
    }
}
