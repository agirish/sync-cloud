import Combine
import Foundation
import os
import Testing
@testable import Sync

/// The scan side of the same-text pass: which files it offers to the reader, what it reports about
/// the ones it could not judge, and that the digests survive to the next scan.
///
/// Every test injects its own extractor and its own cache — never `PDFTextExtractor.fingerprint`
/// or `ContentHashCache.sharedFingerprints`, which would read the user's real index.
@Suite struct SameTextScanTests {

    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    /// Records which paths the reader was asked about, across concurrent calls.
    private final class ReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        var recorded: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    }

    @MainActor
    @Test func aRestampedDownloadIsFoundEndToEnd() async throws {
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        // Different bytes AND different sizes — the case a (name, size) or (size, page count)
        // pre-filter would never even offer to the reader.
        try write(root.appendingPathComponent("Utilities/Jul 2023.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("Downloads/9829custbill.pdf"), bytes: 6040, fill: 0x42)
        try write(root.appendingPathComponent("Utilities/u-only.txt"), bytes: 8, fill: 0x61)
        try write(root.appendingPathComponent("Downloads/d-only.txt"), bytes: 12, fill: 0x62)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root,
                                     textFingerprint: { $0.hasSuffix(".pdf") ? .digest("FP") : .tooLittleText },
                                     fingerprintCache: nil, textlessCache: nil)

        let group = try #require(manager.duplicateGroups.first { $0.matchType == .sameText })
        #expect(group.copies.count == 2)
        #expect(group.keeper.path == root.appendingPathComponent("Utilities/Jul 2023.pdf").path)
        #expect(group.isRecommendedForBatch == false)
        // It must not inflate the headline, which promises exactly what "Apply recommended" does.
        #expect(manager.duplicateSummary.reclaimableBytes == 0)
        #expect(manager.duplicateSummary.needsReviewCount == 1)
    }

    @MainActor
    @Test func onlyDocumentsAreOfferedToTheReader() async throws {
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("a.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("b.PDF"), bytes: 6001, fill: 0x42)
        try write(root.appendingPathComponent("c.txt"), bytes: 6002, fill: 0x43)
        try write(root.appendingPathComponent("d.jpg"), bytes: 6003, fill: 0x44)

        let log = ReadLog()
        let manager = FileSyncManager()
        await manager.findDuplicates(root: root,
                                     textFingerprint: { log.record($0); return .tooLittleText },
                                     fingerprintCache: nil, textlessCache: nil)

        let asked = Set(log.recorded.map { ($0 as NSString).lastPathComponent })
        #expect(asked == ["a.pdf", "b.PDF"])
    }

    @MainActor
    @Test func documentsThatSaidTooLittleAreCountedNotSwallowed() async throws {
        // The blind spot this feature exists to close was silent. A pass that declined every
        // image-only scan without saying so would recreate it one level down.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("readable.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("scan-1.pdf"), bytes: 6001, fill: 0x42)
        try write(root.appendingPathComponent("scan-2.pdf"), bytes: 6002, fill: 0x43)

        let manager = FileSyncManager()
        await manager.findDuplicates(
            root: root,
            textFingerprint: { $0.hasSuffix("readable.pdf") ? .digest("FP") : .tooLittleText },
            fingerprintCache: nil, textlessCache: nil)

        #expect(manager.duplicateScanSkips.textUnreadable == 2)
        // Not folded into the headline skip count: those files were hashed and grouped normally,
        // and only the weaker text claim was declined for them.
        #expect(manager.duplicateScanSkips.total == 0)
    }

    @MainActor
    @Test func theOptionStopsTheReaderBeingCalledAtAll() async throws {
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("a.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("b.pdf"), bytes: 6001, fill: 0x42)

        var options = DuplicateFinderOptions()
        options.detectSameText = false
        let log = ReadLog()
        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, options: options,
                                     textFingerprint: { log.record($0); return .digest("FP") },
                                     fingerprintCache: nil, textlessCache: nil)

        #expect(log.recorded.isEmpty)
        #expect(manager.duplicateGroups.isEmpty)
        #expect(manager.duplicateScanSkips.textUnreadable == 0)
    }

    @MainActor
    @Test func anUnchangedDocumentIsNotReadTwice() async throws {
        // The cost argument for reading every document rather than only size-colliding ones rests
        // entirely on this: a rescan must re-parse nothing.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("A/bill.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("B/bill-copy.pdf"), bytes: 6040, fill: 0x42)

        let log = ReadLog()
        let cache = ContentHashCache()
        let manager = FileSyncManager()
        for _ in 0..<2 {
            manager.clearDuplicates()
            await manager.findDuplicates(root: root,
                                         textFingerprint: { log.record($0); return .digest("FP") },
                                         fingerprintCache: cache)
        }

        #expect(manager.duplicateGroups.contains { $0.matchType == .sameText })
        #expect(log.recorded.count == 2)   // two documents, read once each across two scans
    }

    @MainActor
    @Test func anEditedDocumentIsReadAgain() async throws {
        // The other direction of the cache key: a rewrite moves the mtime, so the stale digest is
        // bypassed rather than served. Without this the cache would be a correctness bug, not a
        // speed-up.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let edited = root.appendingPathComponent("A/bill.pdf")
        try write(edited, bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("B/bill-copy.pdf"), bytes: 6040, fill: 0x42)

        let log = ReadLog()
        let cache = ContentHashCache()
        let manager = FileSyncManager()
        await manager.findDuplicates(root: root,
                                     textFingerprint: { log.record($0); return .digest("FP") },
                                     fingerprintCache: cache)
        #expect(log.recorded.count == 2)

        try write(edited, bytes: 6100, fill: 0x43)
        manager.clearDuplicates()
        await manager.findDuplicates(root: root,
                                     textFingerprint: { log.record($0); return .digest("FP") },
                                     fingerprintCache: cache)
        #expect(log.recorded.filter { $0 == edited.path }.count == 2)
    }

    // MARK: What the review pass found

    @MainActor
    @Test func theProgressBarEndsTheReadingPhaseFull() async throws {
        // The `done == total` progress hop is an unstructured main-actor Task, and the scan's
        // `defer` bumps the epoch on the way out — so without a deterministic terminal publish the
        // bar can be dropped at the last 50-multiple and sit there for the rest of the scan. This
        // is the long phase now, so that is minutes of a bar frozen just short of full.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<60 {
            try write(root.appendingPathComponent("docs/doc-\(i).pdf"), bytes: 6000 + i, fill: UInt8(i % 251))
        }

        let manager = FileSyncManager()
        var seen: [(completed: Int, total: Int)] = []
        let cancellable = manager.$duplicateScanProgress.sink { if let p = $0 { seen.append(p) } }
        defer { cancellable.cancel() }

        await manager.findDuplicates(root: root,
                                     textFingerprint: { _ in .tooLittleText },
                                     fingerprintCache: nil, textlessCache: nil)

        // The reading phase's own totals — 60 documents, distinct from the hashing phase's.
        let reading = seen.filter { $0.total == 60 }
        #expect(!reading.isEmpty)
        #expect(reading.last?.completed == 60)
    }

    @MainActor
    @Test func oneCacheInstanceForBothDigestKindsIsRefusedRatherThanConfused() async throws {
        // Both caches key on (path, mtime, size) and both store a 64-hex string, so a single
        // instance holding both would let a file's SHA-256 be served as its fingerprint with
        // nothing about the value to give it away. The scan declines the cache instead.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("A/bill.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("B/bill-copy.pdf"), bytes: 6040, fill: 0x42)

        let shared = ContentHashCache()
        let log = ReadLog()
        let manager = FileSyncManager()
        for _ in 0..<2 {
            manager.clearDuplicates()
            await manager.findDuplicates(root: root, cache: shared,
                                         textFingerprint: { log.record($0); return .digest("FP") },
                                         fingerprintCache: shared)
        }

        // Still finds the group — the guard costs re-reading, never correctness…
        #expect(manager.duplicateGroups.contains { $0.matchType == .sameText })
        // …and every read went to the extractor, because no fingerprint was cached under a key the
        // content hashes also own.
        #expect(log.recorded.count == 4)
    }

    @MainActor
    @Test func aSameTextGroupSurvivesApplyRecommended() async throws {
        // The call-site half of `isRecommendedForBatch`. The group property is pinned in
        // DuplicateFinderSameTextTests; this is the check that the manager's batch actually
        // consults it — a filter dropped here would leave that property true and unused.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("Utilities/Jul 2023.pdf")
        let other = root.appendingPathComponent("Downloads/9829custbill.pdf")
        try write(kept, bytes: 6000, fill: 0x41)
        try write(other, bytes: 6040, fill: 0x42)
        try write(root.appendingPathComponent("Utilities/u-only.txt"), bytes: 8, fill: 0x61)
        try write(root.appendingPathComponent("Downloads/d-only.txt"), bytes: 12, fill: 0x62)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root,
                                     textFingerprint: { $0.hasSuffix(".pdf") ? .digest("FP") : .tooLittleText },
                                     fingerprintCache: nil, textlessCache: nil)
        #expect(manager.duplicateGroups.contains { $0.matchType == .sameText })

        await manager.applyRecommendedDuplicates(manager.duplicateGroups)

        // Both copies still on disk, and the group still listed for a per-group look.
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(manager.duplicateGroups.contains { $0.matchType == .sameText })
    }

    @MainActor
    @Test func resolvingACopyOutOfBandUpdatesEVERYGroupHoldingIt() async throws {
        // `groupedFilePaths` used to guarantee a file was in at most one file group, and
        // `removeResolvedDuplicateCopy` relied on it by taking the FIRST match. The same-text pass
        // broke that on purpose: an identical group's keeper may also anchor a same-text group.
        // Trash it from the Compare review and the first-match version left the other group listing
        // a file that is now in the Trash.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        // A and Copy are byte-identical; Restamped has the same text but different bytes.
        try write(root.appendingPathComponent("A/bill.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("Copy/bill.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("B/restamped.pdf"), bytes: 6040, fill: 0x42)
        try write(root.appendingPathComponent("A/a-only.txt"), bytes: 8, fill: 0x61)
        try write(root.appendingPathComponent("Copy/c-only.txt"), bytes: 9, fill: 0x62)
        try write(root.appendingPathComponent("B/b-only.txt"), bytes: 10, fill: 0x63)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root,
                                     textFingerprint: { $0.hasSuffix(".pdf") ? .digest("FP") : .tooLittleText },
                                     fingerprintCache: nil, textlessCache: nil)

        let identical = try #require(manager.duplicateGroups.first { $0.matchType == .identical })
        #expect(manager.duplicateGroups.contains { $0.matchType == .sameText })
        let anchor = identical.keeper.path
        // The fixture is only meaningful if that one path really is in both groups.
        #expect(manager.duplicateGroups.filter { $0.copies.contains { $0.id == anchor } }.count == 2)

        manager.removeResolvedDuplicateCopy(atPath: anchor)

        #expect(manager.duplicateGroups.allSatisfy { !$0.copies.contains { $0.id == anchor } })
    }

    // MARK: Documents that said too little (item 21)

    @MainActor
    @Test func aWarmRescanParsesNoTextlessDocumentAndNeverGroupsThem() async throws {
        // A textless document's answer is cached, so a rescan of an unchanged tree reads none of
        // them — 858 on the real tree, re-read on every scan before. And the cached answer is the
        // SAME string for all of them, so if it were ever served as a digest the two below would
        // become one "same text" group.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Scans/receipt.pdf"), bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("Other/photo-id.pdf"), bytes: 6040, fill: 0x42)

        let log = ReadLog()
        let cache = ContentHashCache()
        let textless = ContentHashCache()
        let manager = FileSyncManager()
        for _ in 0..<2 {
            manager.clearDuplicates()
            await manager.findDuplicates(root: root,
                                         textFingerprint: { log.record($0); return .tooLittleText },
                                         fingerprintCache: cache, textlessCache: textless)
            #expect(manager.duplicateGroups.isEmpty)
            #expect(manager.duplicateScanSkips.textUnreadable == 2)   // still reported, every scan
        }
        #expect(log.recorded.count == 2)   // read once each across two scans
        // And the negatives never reach the fingerprint index, which a build from before them
        // would read as two identical digests.
        #expect(await cache.count == 0)
        #expect(await textless.count == 2)
    }

    @MainActor
    @Test func aTextlessCacheSharedWithADigestCacheIsRefused() async throws {
        // One instance for digests and negatives would put the marker where an older build reads
        // digests. The scan declines the negative cache instead, and re-reads.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Scans/receipt.pdf"), bytes: 6000, fill: 0x41)

        let log = ReadLog()
        let shared = ContentHashCache()
        let manager = FileSyncManager()
        for _ in 0..<2 {
            manager.clearDuplicates()
            await manager.findDuplicates(root: root,
                                         textFingerprint: { log.record($0); return .tooLittleText },
                                         fingerprintCache: shared, textlessCache: shared)
        }
        #expect(await shared.count == 0)
        #expect(log.recorded.count == 2)
    }

    /// The other half of the refusal: the negatives sharing the BYTE-hash cache, which Verify and
    /// Duplicates read as digests just the same.
    @MainActor
    @Test func aTextlessCacheSharedWithTheByteCacheIsRefused() async throws {
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("Scans/receipt.pdf"), bytes: 6000, fill: 0x41)
        let log = ReadLog()
        let shared = ContentHashCache()
        let manager = FileSyncManager()
        for _ in 0..<2 {
            manager.clearDuplicates()
            await manager.findDuplicates(root: root, cache: shared,
                                         textFingerprint: { log.record($0); return .tooLittleText },
                                         fingerprintCache: ContentHashCache(), textlessCache: shared)
        }
        #expect(await shared.hash(for: try #require(
            FileSyncManager.fingerprintCacheKey(forPath: root.appendingPathComponent("Scans/receipt.pdf").path,
                                                fileManager: FileManager.default))) == nil,
                "a negative landed in the byte-hash cache")
        #expect(log.recorded.count == 2, "the declined negative cache should leave the document read every scan")
    }

    @MainActor
    @Test func aDocumentThatCouldNotBeReadIsTriedAgainNextScan() async throws {
        // Not on this disk, locked, unparseable: none of that is a fact about the document's text,
        // so none of it is remembered. Once it reads, its digest is.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let placeholder = root.appendingPathComponent("A/statement.pdf")
        try write(placeholder, bytes: 6000, fill: 0x41)
        try write(root.appendingPathComponent("B/statement-copy.pdf"), bytes: 6040, fill: 0x42)

        let log = ReadLog()
        let cache = ContentHashCache()
        let manager = FileSyncManager()
        let downloaded = OSAllocatedUnfairLock(initialState: false)
        let reader: @Sendable (String) async -> FingerprintReading = { path in
            log.record(path)
            if path == placeholder.path, !downloaded.withLock({ $0 }) { return .unreadable }
            return .digest("FP")
        }
        for scan in 0..<3 {
            if scan == 2 { downloaded.withLock { $0 = true } }
            manager.clearDuplicates()
            await manager.findDuplicates(root: root, textFingerprint: reader, fingerprintCache: cache,
                                         textlessCache: ContentHashCache())
        }
        // Scans 1 and 2 each read it (unreadable), scan 3 read it and grouped it, and the copy was
        // read once and served from the cache after.
        #expect(log.recorded.filter { $0 == placeholder.path }.count == 3)
        #expect(log.recorded.count == 4)
        #expect(manager.duplicateGroups.contains { $0.matchType == .sameText })
    }

    @Test func aNegativeFromAnotherSchemeIsAMiss() async throws {
        // The token floor is versioned by the scheme, so a negative recorded under another one is
        // not trusted: the document is read again.
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("A/old.pdf")
        try write(doc, bytes: 6000, fill: 0x41)
        let textless = ContentHashCache()
        let key = try #require(FileSyncManager.fingerprintCacheKey(forPath: doc.path, fileManager: FileManager.default))
        await textless.store("none:pdf-text-0", for: key)

        let log = ReadLog()
        let out = await FileSyncManager.fingerprintDocuments([doc.path], fileManager: FileManager.default,
                                                             cache: ContentHashCache(), textless: textless,
                                                             extract: { log.record($0); return .digest("FP") })
        #expect(out[doc.path] == "FP")
        #expect(log.recorded == [doc.path])
    }

    /// A negative recorded under another token floor is a miss too: the floor can move without a
    /// scheme bump, and a document the new floor would fingerprint must be read again.
    @Test func aNegativeFromAnotherFloorIsAMiss() async throws {
        let root = try makeCanonicalTempRoot(prefix: "SameTextScan")
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("A/floor.pdf")
        try write(doc, bytes: 6000, fill: 0x41)
        let textless = ContentHashCache()
        let key = try #require(FileSyncManager.fingerprintCacheKey(forPath: doc.path, fileManager: FileManager.default))
        await textless.store("none:\(ContentFingerprint.scheme):floor\(ContentFingerprint.minimumTokens + 1)", for: key)
        let log = ReadLog()
        let out = await FileSyncManager.fingerprintDocuments([doc.path], fileManager: FileManager.default,
                                                             cache: ContentHashCache(), textless: textless,
                                                             extract: { log.record($0); return .digest("FP") })
        #expect(out[doc.path] == "FP")
        #expect(log.recorded == [doc.path])
        #expect(ContentFingerprint.tooLittleTextMarker.hasSuffix(":floor\(ContentFingerprint.minimumTokens)"))
    }
}
