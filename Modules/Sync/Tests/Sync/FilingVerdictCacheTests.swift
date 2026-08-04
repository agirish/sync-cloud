import Foundation
import Testing
@testable import Sync

/// Records what the classifier was asked, across concurrent calls.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func record(_ names: [String]) { lock.lock(); defer { lock.unlock() }; calls.append(names) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var lastBatch: [String] { lock.lock(); defer { lock.unlock() }; return calls.last ?? [] }
    var everSaw: [String] { lock.lock(); defer { lock.unlock() }; return calls.flatMap { $0 } }
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
                     excluded: [String] = []) -> FilingVerdictKey {
        FilingVerdictKey(filePath: path, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                         size: size, model: model, promptVersion: 1, excludedRelativePaths: excluded)
    }

    private let verdict = FilingVerdict(relativePath: "Documents/Vehicles/Tesla",
                                        confidence: .high, reason: "Tesla paperwork")

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
                                         size: 5000, model: "test-model", promptVersion: 1))
        #expect(base != FilingVerdictKey(filePath: "/root/f.pdf",
                                         modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                         size: 5000, model: "test-model", promptVersion: 2))
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

    @MainActor
    private func manager(cacheAt url: URL, log: CallLog,
                         identity: String = "test-model") -> FileSyncManager {
        let m = FileSyncManager()
        m.filingVerdictCacheURL = url
        m.filingBackendIdentity = { identity }
        m.filingClassifier = { _, files in
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
        await first.findFilingSuggestions(folder: downloads, providerRoot: root)
        let firstResults = first.filingSuggestions
        #expect(log.count == 1)
        #expect(!firstResults.isEmpty)
        #expect(firstResults.first?.best?.fromAI == true)

        // A FRESH manager, so the hit has to come off disk rather than out of memory.
        let second = manager(cacheAt: url, log: log)
        await second.findFilingSuggestions(folder: downloads, providerRoot: root)

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
        await first.findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(first.filingLastCacheReuse == nil)      // nothing to reuse on a cold cache

        let second = manager(cacheAt: url, log: log)
        await second.findFilingSuggestions(folder: downloads, providerRoot: root)
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
        await manager(cacheAt: url, log: log).findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(log.count == 1)

        // Rewrite the file at a different size — the key's identity of "this file" changes.
        try write(downloads.appendingPathComponent("mystery-scan-0042.pdf"), bytes: 9000)
        await manager(cacheAt: url, log: log).findFilingSuggestions(folder: downloads, providerRoot: root)

        #expect(log.count == 2)
        #expect(log.lastBatch == ["mystery-scan-0042.pdf"])
    }

    @MainActor
    @Test func switchingBackendReclassifies() async throws {
        // Changing the model in Settings must re-ask: an on-device answer is not an Opus answer,
        // and serving one as the other is the silent-substitution failure the identity exists for.
        let root = try fixture("backend")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("backend")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        await manager(cacheAt: url, log: log, identity: "on-device")
            .findFilingSuggestions(folder: downloads, providerRoot: root)
        await manager(cacheAt: url, log: log, identity: "cloud:claude-opus-5")
            .findFilingSuggestions(folder: downloads, providerRoot: root)

        #expect(log.count == 2)
    }

    @MainActor
    @Test func ignoringCacheReasksButStillRecords() async throws {
        let root = try fixture("ignoring")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try cacheURL("ignoring")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let downloads = root.appendingPathComponent("Downloads")

        let log = CallLog()
        await manager(cacheAt: url, log: log).findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(log.count == 1)

        // "Rescan (ignore cache)" — asks again despite a warm entry…
        await manager(cacheAt: url, log: log)
            .findFilingSuggestions(folder: downloads, providerRoot: root, ignoringCache: true)
        #expect(log.count == 2)

        // …and the fresh answer is still written, so the NEXT ordinary scan is free again.
        await manager(cacheAt: url, log: log).findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(log.count == 2)
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
            m.filingClassifier = { _, files in log.record(files.map(\.fileName)); return [:] }
            await m.findFilingSuggestions(folder: downloads, providerRoot: root)
        }
        #expect(log.count == 2)
    }

    @MainActor
    @Test func theSpendPreflightPricesOnlyTheMisses() async throws {
        // The reason the split happens before `cloudSpendAllows` and not after. The preflight is
        // what the user is shown and approves; quoting it for files that are already answered
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

        func cloudManager() -> FileSyncManager {
            let m = manager(cacheAt: url, log: log, identity: "cloud:claude-opus-5")
            let scratch = ScratchDefaults("verdictPreflight")
            scratch.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
            m.filingContentDefaults = scratch
            m.filingCloudSpendConfirmer = { preflight in quotes.add(preflight.fileCount); return true }
            return m
        }

        await cloudManager().findFilingSuggestions(folder: downloads, providerRoot: root)
        #expect(quotes.all == [4])          // first scan: all four priced and sent

        // Add a fifth file; the other four are unchanged and already answered.
        try write(downloads.appendingPathComponent("scan-4.pdf"))
        await cloudManager().findFilingSuggestions(folder: downloads, providerRoot: root)

        #expect(quotes.all == [4, 1])       // the quote covers ONE file, not five
        #expect(log.lastBatch == ["scan-4.pdf"])
    }
}
