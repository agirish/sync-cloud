import Foundation
import Testing
@testable import Sync

/// Records what the classifier was asked, across concurrent calls.
/// One observation made from inside the injected classifier — mid-scan, where no assertion made
/// after the scan can reach. `nil` means the classifier never ran, which is its own failure.
private final class WarmProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func record(_ warm: Bool) { lock.lock(); defer { lock.unlock() }; value = warm }
    var observed: Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func record(_ names: [String]) { lock.lock(); defer { lock.unlock() }; calls.append(names) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var lastBatch: [String] { lock.lock(); defer { lock.unlock() }; return calls.last ?? [] }
    var everSaw: [String] { lock.lock(); defer { lock.unlock() }; return calls.flatMap { $0 } }
}

/// Counts spend-confirmer calls. Same shape as `LensAutoRescanTests`' probe, redeclared because
/// both are file-private — the two suites assert opposite things about the same seam and are read
/// on their own.
private final class SpendProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    var prompts: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@Suite struct FilingVerdictCacheTests {

    private func write(_ url: URL, bytes: Int = 5000, fill: UInt8 = 0x41) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    private func cacheURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "VerdictCache-\(name)")
        return dir.appendingPathComponent("verdicts.json")
    }

    private func key(_ path: String, model: String = "test-model", size: Int = 5000,
                     excluded: [String] = [], artifacts: String = "") -> FilingVerdictKey {
        FilingVerdictKey(filePath: path, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                         size: size, model: model, promptVersion: 1, excludedRelativePaths: excluded,
                         artifacts: artifacts)
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
        // Mutation-style: each field, changed alone, must produce a different key. A field that
        // silently dropped out of the key would serve one backend's answer for another's.
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

    /// **The artifacts axis, which nothing compared.** Two halves existed — the fingerprint on a
    /// temp directory, and key equality with a hand-passed value — and neither joined them. A
    /// re-survey changes what every file is asked about; a key that ignored it would replay
    /// answers composed against the old tree.
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

        // Vehicles has since been deleted, so the same verdict now proposes creating TWO. That is
        // a different offer than the one that was approved for caching — re-ask.
        let hit = cache.verdict(for: key("/root/f.pdf"), providerRoot: "/root",
                                existingRelative: ["Documents"])
        #expect(hit == nil)
    }

    @Test func aFolderCreatedSinceCachingIsStillAHit() {
        // The inverse direction must NOT invalidate: the destination got closer to existing, so
        // the cached answer is at worst as good as it was. Invalidating here is what would make
        // "one new folder anywhere = full re-spend" true, which is the thing the design avoids.
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

    @Test func aMissingOrCorruptFileLoadsAsEmptyRatherThanThrowing() throws {
        let url = try cacheURL("corrupt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FilingVerdictStore.load(from: url).count == 0)          // never written

        try Data("{not json".utf8).write(to: url)
        #expect(FilingVerdictStore.load(from: url).count == 0)          // unreadable
    }

    @Test func aForeignSchemaLoadsAsEmpty() throws {
        let url = try cacheURL("schema")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(#"{"schema":999,"entries":[]}"#.utf8).write(to: url)
        #expect(FilingVerdictStore.load(from: url).count == 0)
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
        try write(root.appendingPathComponent("Documents/Family/Divit/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/mystery-scan-0042.pdf"))
        return root
    }

    /// `identity` is the identity for BOTH tiers by default, which is what most of these tests
    /// want: they are about the cache key, and the scan is the cheapest way to exercise it.
    ///
    /// `refineIdentity` overrides the refine tier alone, for the tests that are about the paid
    /// pass. Note that an `identity` naming a cloud backend makes the SCAN skip classification
    /// (`freePassWouldReachAPaidBackend`) — a scan that reports a paid route for `.free` is a
    /// misrouted app, and `Sync` refuses rather than being billed. So a cloud identity belongs on
    /// `refineIdentity`, never on `identity`.
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
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Divit",
                                                confidence: .high, reason: "Divit’s record")
            }
            return out
        }
        return m
    }

    /// A manager whose refine pass routes to a cloud model with the cloud toggle on — the only
    /// configuration in which `cloudSpendAllows` consults the confirmer. The scan stays free.
    @MainActor
    private func refiningManager(cacheAt url: URL, log: CallLog, suite: String,
                                 confirm: @escaping @MainActor (FilingSpendPreflight) -> Bool)
    -> FileSyncManager {
        let m = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-opus-5")
        let scratch = ScratchDefaults(suite)
        scratch.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        m.filingContentDefaults = scratch
        m.filingCloudSpendConfirmer = confirm
        return m
    }

    /// Runs a scan and waits for the cache write to land. The wait is the point: these tests
    /// build a SECOND manager to prove the entry survived to disk, and the write is asynchronous —
    /// without the barrier they would be racing it.
    @MainActor
    private func scan(_ m: FileSyncManager, _ folder: URL, root: URL,
                      ignoringCache: Bool = false) async {
        await m.findFilingSuggestions(folder: folder, providerRoot: root, ignoringCache: ignoringCache)
        FilingVerdictStore.waitForPendingWrites()
    }

    /// Scans, then refines everything the scan published — the two-pass sequence a user performs
    /// by clicking Suggest homes and then Refine.
    @MainActor
    private func scanThenRefine(_ m: FileSyncManager, _ folder: URL, root: URL) async {
        await scan(m, folder, root: root)
        await m.refineFilingSuggestions(m.filingSuggestions)
        FilingVerdictStore.waitForPendingWrites()
    }

    @MainActor
    @Test func anUnchangedFolderIsNotReclassified() async throws {
        // THE equivalence proof: a second scan of an untouched folder must produce byte-identical
        // suggestions while asking the backend nothing at all. Both halves matter — "no calls" with
        // different results would be a cache that changed the answer, and identical results with a
        // call would be a cache that saved nothing.
        let root = try fixture("equivalence")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("equivalence")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        let first = manager(cacheAt: url, log: log)
        await scan(first, downloads, root: root)
        let firstResults = first.filingSuggestions
        #expect(log.count == 1)
        #expect(!firstResults.isEmpty)
        #expect(firstResults.first?.best?.fromAI == true)

        // A FRESH manager, so the hit has to come off disk rather than out of memory.
        let second = manager(cacheAt: url, log: log)
        await scan(second, downloads, root: root)

        #expect(log.count == 1)                              // the backend was never consulted again
        #expect(second.filingSuggestions == firstResults)    // and the answer is the same one
    }

    @MainActor
    @Test func reuseIsPublishedWithTheResultsAndClearedWithThem() async throws {
        // The figure the "reused" pill reads. It has to be published WITH the suggestions, not as
        // the scan runs, or a cancelled scan would relabel the previous results with its numbers.
        let root = try fixture("reuse-published")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("reuse-published")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

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
        let root = try fixture("changed")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("changed")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        await scan(manager(cacheAt: url, log: log), downloads, root: root)
        #expect(log.count == 1)

        // Rewrite the file at a different size — the key's identity of "this file" changes.
        try write(downloads.appendingPathComponent("mystery-scan-0042.pdf"), bytes: 9000)
        await scan(manager(cacheAt: url, log: log), downloads, root: root)

        #expect(log.count == 2)
        #expect(log.lastBatch == ["mystery-scan-0042.pdf"])
    }

    @MainActor
    @Test func switchingBackendReclassifies() async throws {
        // Changing the model in Settings must re-ask: an on-device answer is not an Opus answer,
        // and serving one as the other is the silent-substitution failure the identity exists for.
        //
        // Exercised through REFINE, because that is the only pass whose backend can vary now —
        // the scan is pinned to on-device by its tier. The old version switched the scan's
        // identity between two runs, which after the split is not a state the app can produce.
        let root = try fixture("backend")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("backend")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        let haiku = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-haiku-4-5")
        await scanThenRefine(haiku, downloads, root: root)
        #expect(log.count == 2)                       // one free scan, one refine

        // Same file, same everything — except the model the refine names.
        let opus = manager(cacheAt: url, log: log, refineIdentity: "cloud:claude-opus-5")
        await scanThenRefine(opus, downloads, root: root)

        // The scan reused its cached on-device verdict; the refine did NOT reuse Haiku's.
        #expect(log.count == 3)
        #expect(opus.filingLastRefine?.classified == 1)
        #expect(opus.filingLastRefine?.reused == 0)
    }

    @MainActor
    @Test func refiningTwiceOnTheSameModelIsFree() async throws {
        // The other direction, and the one that costs money if it breaks: an unchanged file that
        // this model has already answered must not be sent again. Same key, same guarantee as
        // `anUnchangedFolderIsNotReclassified` — but on the pass where a miss is billed.
        let root = try fixture("refine-twice")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("refine-twice")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

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
        let root = try fixture("ignoring")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("ignoring")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        await scan(manager(cacheAt: url, log: log), downloads, root: root)
        #expect(log.count == 1)

        // "Rescan (ignore cache)" — asks again despite a warm entry…
        await scan(manager(cacheAt: url, log: log), downloads, root: root, ignoringCache: true)
        #expect(log.count == 2)

        // …and the fresh answer is still written, so the NEXT ordinary scan is free again.
        await scan(manager(cacheAt: url, log: log), downloads, root: root)
        #expect(log.count == 2)
    }

    // MARK: A backend the app cannot name
    //
    // **The contract `filingBackendIdentity` documents: returning nil means "I cannot vouch for
    // which backend will run", and must switch the cache off for the scan — read AND write.**
    //
    // It did not. `filingBackendIdentity?() ?? configuredFilingBackendIdentity` FLATTENS in Swift,
    // so a closure that RETURNED nil was indistinguishable from one that was never SET, and `??`
    // answered the configured identity for both. A verdict from an unvouched scan was then cached
    // under whatever Settings happened to say — an on-device answer filed under a Claude model's
    // name, which is the silent substitution the seam exists to prevent, made durable.
    //
    // **Two tests, because one fixture cannot discriminate both halves — measured, not assumed.**
    // The first version asserted both against a single `identity: "test-model"` fixture and its
    // READ assertion passed against the bug: with the fallback in place the unvouched scan resolves
    // to "on-device" (the configured identity in a test, where the cloud toggle is off), which is a
    // DIFFERENT key from "test-model" — so it misses and re-asks either way.
    //
    // So the read half needs the fallback identity to EQUAL the warm entry's, and the write half
    // needs it to DIFFER (or the errant write lands on the same key and the count never moves).
    // Each test below is mutation-checked against restoring the `??`.

    @MainActor
    @Test func aBackendTheAppCannotNameIsNotServedFromTheCache() async throws {
        let root = try fixture("nil-identity-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("nil-identity-read")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        // The warm entry is keyed on the SAME identity the fallback would produce — `on-device` is
        // what `configuredFilingBackendIdentity` answers with the cloud toggle off. That is what
        // makes this discriminating: under the bug the unvouched scan hits this entry.
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
        let root = try fixture("nil-identity-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("nil-identity-write")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        // `test-model` here, DIFFERENT from the `on-device` the fallback would produce — so a write
        // that should not have happened lands as a SECOND entry rather than overwriting this one.
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
        // "Rescan (ignore cache)" skipped the ASYNC accessor (it has no use for the READ) and then
        // reached the SYNCHRONOUS one from `recordFilingVerdicts` — putting a decode of a file that
        // reaches ~12 MB at the entry cap back on the main actor, mid-scan, which is the one thing
        // the async accessor exists to prevent.
        //
        // **Asserted at CLASSIFY time, not at the end of the scan.** The first version of this
        // checked `filingVerdictCache != nil` afterwards and passed against the bug: recording
        // warms the memo through the synchronous accessor, so it is non-nil either way — the
        // measurement could not see WHICH accessor had loaded it. The classifier runs after the
        // cache split and before recording, so "already warm by then" is exactly the invariant,
        // and it is false under the mutation.
        let root = try fixture("ignore-warms")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("ignore-warms")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        await scan(manager(cacheAt: url, log: log), downloads, root: root)

        // A FRESH manager whose memo is cold, told to ignore the cache.
        let ignoring = manager(cacheAt: url, log: log)
        #expect(ignoring.filingVerdictCache == nil, "the fixture must start cold")

        let warmAtClassify = WarmProbe()
        ignoring.filingClassifier = { [weak ignoring] _, files, _ in
            log.record(files.map(\.fileName))
            if let ignoring {
                await MainActor.run { warmAtClassify.record(ignoring.filingVerdictCache != nil) }
            }
            return files.reduce(into: [:]) { out, f in
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Divit",
                                                confidence: .high, reason: "Divit’s record")
            }
        }
        await scan(ignoring, downloads, root: root, ignoringCache: true)

        #expect(warmAtClassify.observed == true,
                "the ignoring scan must warm the memo through the async accessor BEFORE it reaches the synchronous one in recordFilingVerdicts")
        #expect(ignoring.filingVerdictCacheCountNow == 1)
    }

    @MainActor
    @Test func clearingCannotBeOvertakenByAQueuedScanWrite() async throws {
        // Clear used to write SYNCHRONOUSLY, bypassing the store's write queue, while a scan's own
        // write sits ON that queue (`recordFilingVerdicts` fires it mid-scan, and at the entry cap
        // it is a multi-megabyte encode). The queued PRE-clear snapshot could then land after the
        // clear's write, and the next launch reloaded every verdict the user had just cleared.
        //
        // The fixture stages exactly that: a large snapshot queued first — standing in for the
        // in-flight scan write, and large so its encode outlasts the clear's — then the clear.
        // Ordering on one queue is the fix, so after the barrier the file must be empty. Against
        // the synchronous clear this fails: the clear's empty write lands first and the big
        // snapshot overwrites it.
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
        // The default for the CLI and every existing test: no location configured, no cache, and
        // in particular no reaching into the real Application Support directory.
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
        // Recording deliberately happens BEFORE this scan's cancellation check. By the time the
        // classifier returns the cloud call has already been billed; throwing the answers away
        // because the user cancelled a moment later would mean paying for them twice.
        let root = try fixture("cancelled")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("cancelled")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        let cancelling = FileSyncManager()
        cancelling.filingVerdictCacheURL = url
        cancelling.filingBackendIdentity = { _ in "test-model" }
        cancelling.filingClassifier = { _, files, _ in
            log.record(files.map(\.fileName))
            // Cancel the scan from inside the call — the answer exists and has been paid for,
            // and the scan is abandoned immediately afterwards.
            withUnsafeCurrentTask { $0?.cancel() }
            var out: [String: FilingVerdict] = [:]
            for f in files {
                out[f.filePath] = FilingVerdict(relativePath: "Documents/Family/Divit",
                                                confidence: .high, reason: "Divit’s record")
            }
            return out
        }
        // Run it in a task of its own: `withUnsafeCurrentTask` cancels whatever task is running the
        // scan, and awaiting the scan directly would make that the TEST's task — poisoning every
        // later await in this function with a cancellation that has nothing to do with the subject.
        await Task { await cancelling.findFilingSuggestions(folder: downloads, providerRoot: root) }.value
        FilingVerdictStore.waitForPendingWrites()

        #expect(log.count == 1)
        #expect(cancelling.filingSuggestions.isEmpty)      // the scan really did abandon its results
        #expect(!cancelling.hasSuggestedFiling)

        // …but the paid-for answer survived, so the next scan does not buy it again.
        let next = manager(cacheAt: url, log: log)
        await scan(next, downloads, root: root)
        #expect(log.count == 1)
        #expect(next.filingSuggestions.first?.best?.fromAI == true)
    }

    @MainActor
    @Test func aDeclinedSpendIsNotCountedAsClassified() async throws {
        // The refine pill reads off this, and it is the user's evidence about cost. If the spend
        // guardrail declines, NOTHING was sent — reporting the batch size would claim work (and
        // money) that never happened.
        let root = try makeCanonicalTempRoot(prefix: "VerdictDeclined")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("declined")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(root.appendingPathComponent("Documents/Family/Divit/.keep"), bytes: 1)
        try write(root.appendingPathComponent("Downloads/first.pdf"))
        let downloads = root.appendingPathComponent("Downloads")

        // One refine at the paid model, so `first.pdf` has an Opus answer on file.
        let log = CallLog()
        let bought = refiningManager(cacheAt: url, log: log, suite: "verdictBought") { _ in true }
        await scanThenRefine(bought, downloads, root: root)
        #expect(log.count == 2)

        // A second file arrives, and the guardrail refuses the spend for it.
        try write(downloads.appendingPathComponent("second.pdf"))
        let declining = refiningManager(cacheAt: url, log: log, suite: "verdictDeclined") { _ in false }
        await scanThenRefine(declining, downloads, root: root)

        // The free scan classified both files; the refine sent nothing.
        #expect(log.count == 3)
        // `outcome: .declined` is the point of the fixture, not incidental to it: `classified: 0`
        // alone is also what an exhausted cache looks like, and every reader that had only the
        // number to go on described this pass as one.
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
        // Settings' Clear button. It throws away work that, on the cloud backend, was paid for —
        // so it has to actually reach the file, not just the in-memory copy: a clear that a
        // relaunch undoes is worse than no clear at all.
        let root = try fixture("clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("clear")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        let first = manager(cacheAt: url, log: log)
        await scan(first, downloads, root: root)
        #expect(first.filingVerdictCacheCountNow == 1)   // memo warm from the scan

        first.clearFilingVerdictCache()
        FilingVerdictStore.waitForPendingWrites()
        #expect(first.filingVerdictCacheCountNow == 0)

        // A fresh manager reading the file agrees — the clear was persisted, not just forgotten.
        // AWAITED, because this one's memo is cold and that is the load: the same distinction the
        // Settings readout makes between its first read and the one after `Clear`.
        let second = manager(cacheAt: url, log: log)
        #expect(await second.filingVerdictCacheCount() == 0)
        await scan(second, downloads, root: root)
        #expect(log.count == 2)                       // and the backend is consulted again
    }

    @MainActor
    @Test func theSpendPreflightPricesOnlyTheMisses() async throws {
        // The reason the cache split happens before `cloudSpendAllows` and not after. The preflight
        // is what the user is shown and approves; quoting it for files that are already answered
        // would make the figure a fiction — and would also re-read their contents for nothing.
        let root = try makeCanonicalTempRoot(prefix: "VerdictPreflight")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("preflight")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(root.appendingPathComponent("Documents/Family/Divit/.keep"), bytes: 1)
        for i in 0..<4 { try write(root.appendingPathComponent("Downloads/scan-\(i).pdf")) }
        let downloads = root.appendingPathComponent("Downloads")

        final class Quotes: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [Int] = []
            func add(_ n: Int) { lock.lock(); defer { lock.unlock() }; seen.append(n) }
            var all: [Int] { lock.lock(); defer { lock.unlock() }; return seen }
        }
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
        try write(downloads.appendingPathComponent("scan-4.pdf"))
        let second = cloudManager("verdictPreflight2")
        await scanThenRefine(second, downloads, root: root)

        #expect(quotes.all == [4, 1])       // the quote covers ONE file, not five
        #expect(log.lastBatch == ["scan-4.pdf"])
        #expect(second.filingLastRefine?.reused == 4)
    }

    @MainActor
    @Test func aCachedVerdictWhoseAnchorFolderVanishedIsRePricedNotServedStale() async throws {
        // The staleness rule, end to end and on the pass where being wrong costs money. A cached
        // verdict whose destination no longer resolves the way it did — its anchor folder deleted
        // since — is a MISS, so it must be re-asked and must appear in the quote the user approves.
        //
        // This replaces the scan-level test the tier split retired
        // (`aCachedButNoLongerResolvableVerdictIsStoppedByThePhaseThreeCheck`, which existed to
        // stop an auto-scan paying for it). The rule still matters, and it matters here now: on the
        // free pass a stale hit costs a re-run, on the refine pass it costs a re-purchase, and a
        // quote that omitted it would understate the bill.
        let root = try fixture("stale-anchor")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("stale-anchor")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        final class Quotes: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [Int] = []
            func add(_ n: Int) { lock.lock(); defer { lock.unlock() }; seen.append(n) }
            var all: [Int] { lock.lock(); defer { lock.unlock() }; return seen }
        }
        let quotes = Quotes()
        let log = CallLog()

        // A paid refine caches a verdict naming Documents/Family/Divit, which exists today.
        let first = refiningManager(cacheAt: url, log: log, suite: "verdictStale1") {
            quotes.add($0.fileCount); return true
        }
        await scanThenRefine(first, downloads, root: root)
        #expect(quotes.all == [1])
        #expect(first.filingLastRefine?.classified == 1)

        // Documents/Family goes away, so the cached destination now proposes MORE new folders than
        // it did when cached — the staleness rule turns the hit into a miss.
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
        // The companion assertion to the one above, and the whole point of the split: the same
        // configuration that prices a refine prices NOTHING for the scan that preceded it. Without
        // this, every quote count above is equally consistent with the scan doing the pricing.
        let root = try fixture("scan-unpriced")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("scan-unpriced")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

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

    /// **A re-survey must not replay answers composed against the old tree.** The artifacts decide
    /// the router's shortlist, the shortlist is the classifier's folder menu, so regenerating them
    /// changes what every file is asked — and the key said nothing about it. Installing a freshly
    /// generated profile logged `reused 14 of 14 classification(s) from cache, 0 sent to the
    /// backend`; the re-survey did nothing until the cache file was deleted by hand.
    @Test func regeneratingTheArtifactsChangesTheFingerprint() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeArtifacts(dir, id: "me", profileFolders: 10)
        let before = FilingProfileStore.fingerprint(id: "me", in: dir)
        #expect(!before.isEmpty)
        #expect(FilingProfileStore.fingerprint(id: "me", in: dir) == before, "not stable across reads")

        try writeArtifacts(dir, id: "me", profileFolders: 11)   // re-surveyed
        #expect(FilingProfileStore.fingerprint(id: "me", in: dir) != before)
    }

    /// An unsurveyed tree has no artifacts and no fingerprint — the field must not become a reason
    /// to miss on a machine that never had a profile.
    @Test func noArtifactsMeansAnEmptyFingerprint() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fp-none-\(UUID().uuidString)")
        #expect(FilingProfileStore.fingerprint(id: "me", in: dir).isEmpty)
    }

    /// The fingerprint is key material: two otherwise identical questions asked against different
    /// artifacts are different questions.
    @Test func theFingerprintSeparatesOtherwiseIdenticalKeys() {
        func key(_ fp: String) -> FilingVerdictKey {
            FilingVerdictKey(filePath: "/r/TODO/a.pdf", modificationDate: Date(timeIntervalSince1970: 1),
                             size: 10, model: "on-device", promptVersion: 5, artifacts: fp)
        }
        #expect(key("aaaa") != key("bbbb"))
        #expect(key("aaaa") == key("aaaa"))
    }

    /// An entry written before the field existed still decodes — a shape change that throws
    /// discards the whole cache file, and those entries are honest answers to the question a tree
    /// with no artifacts asks.
    @Test func aKeyWrittenBeforeTheFieldExistedStillDecodes() throws {
        let json = #"{"filePath":"/r/a.pdf","modifiedMillis":1000,"size":10,"model":"on-device","promptVersion":4,"excludedRelativePaths":[]}"#
        let k = try JSONDecoder().decode(FilingVerdictKey.self, from: Data(json.utf8))
        #expect(k.artifacts.isEmpty)
        #expect(k.filePath == "/r/a.pdf")
    }
}
