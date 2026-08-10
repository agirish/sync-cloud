import Foundation
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
                                     textFingerprint: { $0.hasSuffix(".pdf") ? "FP" : nil },
                                     fingerprintCache: nil)

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
                                     textFingerprint: { log.record($0); return nil },
                                     fingerprintCache: nil)

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
            textFingerprint: { $0.hasSuffix("readable.pdf") ? "FP" : nil },
            fingerprintCache: nil)

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
                                     textFingerprint: { log.record($0); return "FP" },
                                     fingerprintCache: nil)

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
                                         textFingerprint: { log.record($0); return "FP" },
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
                                     textFingerprint: { log.record($0); return "FP" },
                                     fingerprintCache: cache)
        #expect(log.recorded.count == 2)

        try write(edited, bytes: 6100, fill: 0x43)
        manager.clearDuplicates()
        await manager.findDuplicates(root: root,
                                     textFingerprint: { log.record($0); return "FP" },
                                     fingerprintCache: cache)
        #expect(log.recorded.filter { $0 == edited.path }.count == 2)
    }
}
