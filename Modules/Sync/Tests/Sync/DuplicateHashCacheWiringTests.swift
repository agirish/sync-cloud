import Testing
import Foundation
@testable import Sync

/// Proves the duplicate finder's two hashing entry points actually CONSULT the session hash cache.
///
/// Verify has used `ContentHashCache` since it was written; the duplicate scan and merge planner
/// called the same hasher with no cache at all, so a scan after a Verify — or a second scan, or the
/// keeper tree re-walked once per redundant copy during a merge — re-read and re-hashed everything.
/// Wiring it up is a one-argument change, which is exactly the kind that can be made and then
/// quietly not take effect; these tests plant a digest the file does not really have and show the
/// grouping decision follows the PLANTED value, which is only possible if the cache was read.
@Suite struct DuplicateHashCacheWiringTests {

    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    /// The key `FileContentVerifier` builds for a real file — through its own spelling of it, which
    /// since FR59 also carries the file number and status-change time.
    private func key(for url: URL) throws -> ContentHashKey {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require((attrs[.size] as? NSNumber)?.intValue)
        return try #require(FileContentVerifier.cacheKey(statPath: url.path, attributes: attrs, size: size))
    }

    /// Two byte-identical files group as duplicates. Plant a different digest for one of them and
    /// the group must not form — proof the scan read the cache instead of the bytes.
    @MainActor
    @Test func findDuplicatesReadsTheSessionCache() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheWiring")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A/report.pdf")
        let b = root.appendingPathComponent("B/report.pdf")
        try write(a, bytes: 4096, fill: 0x41)
        try write(b, bytes: 4096, fill: 0x41)   // identical bytes

        // Mutation guard FIRST: with no cache these genuinely group, so the assertion below is
        // about the cache and not about the fixture failing to be a duplicate pair.
        let uncached = FileSyncManager()
        await uncached.findDuplicates(root: root, cache: nil)
        #expect(uncached.duplicateGroups.count == 1, "the fixture must be a real duplicate pair")

        // Now plant a digest `b` does not have. Same size, so it stays a size-collision candidate
        // and still reaches the hasher — it just gets the planted answer.
        let cache = ContentHashCache()
        await cache.store(String(repeating: "f", count: 64), for: try key(for: b))

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, cache: cache)

        #expect(manager.duplicateGroups.isEmpty,
                "the planted digest must have been served, splitting the pair")
    }

    /// A file over the edge-sample size whose same-size twin could not be sampled (cloud-only, so
    /// never opened) must still be read whole: no sample means unknown, not different, and the
    /// twin's digest may already be cached. Dropping the local copy for having the only sample of
    /// its size would lose a pair the cache can prove.
    @MainActor
    @Test func anUnsampledTwinKeepsALargeCandidateInTheFullHash() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheSample")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("A/movie.mp4")
        let cloud = root.appendingPathComponent("B/movie.mp4")
        try write(local, bytes: 5000, fill: 0x42)
        try write(cloud, bytes: 5000, fill: 0x42)

        // The cloud copy's digest is known from when it was local; the local copy's is not.
        let real = try #require(await FileContentVerifier.sha256Hex(filePath: local.path))
        let cache = ContentHashCache()
        await cache.store(real, for: try key(for: cloud))

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, sampleAbove: 1000,
                                     isCloudOnly: { $0.hasPrefix(cloud.deletingLastPathComponent().path) },
                                     cache: cache)
        #expect(manager.duplicateGroups.count == 1)
        #expect(manager.duplicateScanSkips == FileSyncManager.DuplicateScanSkips())
        // The local copy was read whole: a full hash is the only thing that stores a digest.
        #expect(await cache.hash(for: try key(for: local)) == real)
    }

    /// Over the edge-sample size, a candidate is read whole only when its ends match another
    /// same-size candidate's. The cache is the witness — only a full hash stores a digest:
    /// - an identical pair matches at the ends, is read whole, and groups;
    /// - a pair differing in its first byte is ruled out on the sample, never read whole, and
    ///   counted as no skip — it is proven different, not unknown;
    /// - a pair differing only in the middle matches at the ends, so it is read whole, and does
    ///   not group.
    @MainActor
    @Test func largeCandidatesAreReadWholeOnlyWhenTheirEndsMatch() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheEnds")
        defer { try? FileManager.default.removeItem(at: root) }
        let movieA = root.appendingPathComponent("A/movie.mp4")
        let movieB = root.appendingPathComponent("B/movie.mp4")
        try write(movieA, bytes: 5000, fill: 0x41)
        try write(movieB, bytes: 5000, fill: 0x41)

        let headA = root.appendingPathComponent("A/disk.img")
        let headB = root.appendingPathComponent("B/disk.img")
        try write(headA, bytes: 6000, fill: 0x44)
        var head = Data(repeating: 0x44, count: 6000)
        head[0] = 0x45
        try head.write(to: headB)

        // Longer than both samples together, so the middle byte is in neither.
        let middleSize = 2 * FileContentVerifier.edgeSampleBytes + 4096
        let middleA = root.appendingPathComponent("A/archive.zip")
        let middleB = root.appendingPathComponent("B/archive.zip")
        try write(middleA, bytes: middleSize, fill: 0x4D)
        var middle = Data(repeating: 0x4D, count: middleSize)
        middle[middleSize / 2] = 0x4E
        try middle.write(to: middleB)

        let cache = ContentHashCache()
        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, sampleAbove: 1000, isCloudOnly: { _ in false },
                                     cache: cache)

        #expect(manager.duplicateGroups.map(\.name) == ["movie.mp4"])
        #expect(manager.duplicateScanSkips == FileSyncManager.DuplicateScanSkips())
        #expect(await cache.hash(for: try key(for: movieA)) != nil)
        #expect(await cache.hash(for: try key(for: movieB)) != nil)
        #expect(await cache.hash(for: try key(for: headA)) == nil)
        #expect(await cache.hash(for: try key(for: headB)) == nil)
        #expect(await cache.hash(for: try key(for: middleA)) != nil)
        #expect(await cache.hash(for: try key(for: middleB)) != nil)
    }

    /// The headline claim: Verify and the duplicate finder stop paying for each other's work. Verify hashes through
    /// the shared cache; a duplicates scan of the same files must then find those digests already there.
    /// Proved the same way — by what Verify leaves behind being the thing the duplicates scan answers from.
    @MainActor
    @Test func aVerifyPopulatesTheCacheThatADuplicatesScanThenReadsFrom() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheCrossFeature")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A/report.pdf")
        let b = root.appendingPathComponent("B/report.pdf")
        try write(a, bytes: 4096, fill: 0x41)
        try write(b, bytes: 4096, fill: 0x41)   // identical

        let shared = ContentHashCache()

        // Verify's own entry point, through the cache.
        let same = await FileContentVerifier.filesHaveSameContent(
            leftPath: a.path, rightPath: b.path, cache: shared)
        #expect(same == true)

        // Both digests are now cached — and they are the REAL ones, so the scan must group.
        #expect(await shared.hash(for: try key(for: a)) != nil)
        #expect(await shared.hash(for: try key(for: b)) != nil)

        let manager = FileSyncManager()
        await manager.findDuplicates(root: root, cache: shared)
        #expect(manager.duplicateGroups.count == 1)

        // Mutation guard for the direction of the claim: overwrite ONE of the digests Verify left
        // behind, and the scan's answer changes — so the scan really did read Verify's entries and
        // not just re-hash the files itself.
        await shared.store(String(repeating: "c", count: 64), for: try key(for: b))
        let after = FileSyncManager()
        await after.findDuplicates(root: root, cache: shared)
        #expect(after.duplicateGroups.isEmpty)
    }

    /// A size whose every large candidate already has its digest cached is not edge-sampled: the
    /// full hash answers each from the cache, so the 2 MB read per file bought nothing. The
    /// cloud-only seam is the witness — a sample asks it before opening a file, and a cache hit in
    /// the full hash returns before asking. With only one digest cached, both files are sampled:
    /// that is the control, and the reason a partly cached size is sampled whole.
    @MainActor
    @Test func aFullyCachedSizeIsNotEdgeSampled() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheNoSample")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A/movie.mp4")
        let b = root.appendingPathComponent("B/movie.mp4")
        try write(a, bytes: 5000, fill: 0x42)
        try write(b, bytes: 5000, fill: 0x42)
        let real = try #require(await FileContentVerifier.sha256Hex(filePath: a.path))

        func scan(planting: [URL]) async throws -> (asked: [String], groups: Int) {
            let cache = ContentHashCache()
            for url in planting { await cache.store(real, for: try key(for: url)) }
            let asked = LockedBox<[String]>([])
            let manager = FileSyncManager()
            await manager.findDuplicates(root: root, sampleAbove: 1000,
                                         isCloudOnly: { path in asked.withLock { $0.append(path) }; return false },
                                         cache: cache)
            return (asked.withLock { $0 }, manager.duplicateGroups.count)
        }

        let warm = try await scan(planting: [a, b])
        #expect(warm.asked.isEmpty, "a fully cached size was sampled: \(warm.asked)")
        #expect(warm.groups == 1)

        let partial = try await scan(planting: [a])
        #expect(Set(partial.asked).isSuperset(of: [a.path, b.path]))
        #expect(partial.groups == 1)
    }

    /// `planMerge` decides "the keeper already has this content at this path" from a hash compare,
    /// and it re-hashes the WHOLE keeper tree once per redundant copy — the merge path's real cost.
    /// Plant matching digests for a keeper/copy pair and the step disappears from the plan.
    @Test func planMergeReadsTheSessionCache() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheMerge")
        defer { try? FileManager.default.removeItem(at: root) }
        let keeper = root.appendingPathComponent("Keeper")
        let copy = root.appendingPathComponent("Copy")
        // Same relative path on both sides, DIFFERENT bytes — so an honest plan must copy it in.
        try write(keeper.appendingPathComponent("doc.txt"), bytes: 64, fill: 0x41)
        try write(copy.appendingPathComponent("doc.txt"), bytes: 64, fill: 0x42)

        let honest = await FileSyncManager.planMerge(from: copy, into: keeper,
                                                     fileManager: FileManager.default, cache: nil)
        #expect(honest.steps.count == 1, "differing content must be planned for copying")

        // Plant one shared digest for both, so the planner believes the keeper already has it.
        let cache = ContentHashCache()
        let digest = String(repeating: "b", count: 64)
        await cache.store(digest, for: try key(for: keeper.appendingPathComponent("doc.txt")))
        await cache.store(digest, for: try key(for: copy.appendingPathComponent("doc.txt")))

        let warm = await FileSyncManager.planMerge(from: copy, into: keeper,
                                                   fileManager: FileManager.default, cache: cache)
        #expect(warm.steps.isEmpty, "the planted match must have been served from the cache")
    }

    /// `planMerge` reads only files whose size the other side also has: every skip compares
    /// digests across the trees, and equal digests need equal sizes, so the rest could change no
    /// step. The cache is the witness — only a hash stores a digest — and the plan is the control:
    /// the same pair is still recognised, and the copy-only file is still copied.
    @Test func planMergeHashesOnlyFilesWithASameSizeCounterpart() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheMergeSizes")
        defer { try? FileManager.default.removeItem(at: root) }
        let keeper = root.appendingPathComponent("Keeper")
        let copy = root.appendingPathComponent("Copy")
        try write(keeper.appendingPathComponent("doc.txt"), bytes: 64, fill: 0x41)
        try write(copy.appendingPathComponent("doc.txt"), bytes: 64, fill: 0x41)
        try write(keeper.appendingPathComponent("keeper-only.bin"), bytes: 5000, fill: 0x4B)
        try write(copy.appendingPathComponent("copy-only.bin"), bytes: 3000, fill: 0x43)

        let cache = ContentHashCache()
        let plan = await FileSyncManager.planMerge(from: copy, into: keeper,
                                                   fileManager: FileManager.default, cache: cache)
        #expect(plan.steps.map(\.src.lastPathComponent) == ["copy-only.bin"])
        #expect(await cache.hash(for: try key(for: keeper.appendingPathComponent("doc.txt"))) != nil)
        #expect(await cache.hash(for: try key(for: copy.appendingPathComponent("doc.txt"))) != nil)
        #expect(await cache.hash(for: try key(for: keeper.appendingPathComponent("keeper-only.bin"))) == nil)
        #expect(await cache.hash(for: try key(for: copy.appendingPathComponent("copy-only.bin"))) == nil)
    }

    /// A Stop during merge planning reaches its reads: the same identical pair, planned with a
    /// stop already given, hashes nothing — so the cache stays empty, where the test above fills it.
    @Test func planMergePassesItsStopToTheReads() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheMergeStop")
        defer { try? FileManager.default.removeItem(at: root) }
        let keeper = root.appendingPathComponent("Keeper")
        let copy = root.appendingPathComponent("Copy")
        try write(keeper.appendingPathComponent("doc.txt"), bytes: 64, fill: 0x41)
        try write(copy.appendingPathComponent("doc.txt"), bytes: 64, fill: 0x41)

        let cache = ContentHashCache()
        _ = await FileSyncManager.planMerge(from: copy, into: keeper, fileManager: FileManager.default,
                                            cache: cache, isCancelled: { true })
        #expect(await cache.count == 0)
    }

    /// **A document copied over under its old dates is fingerprinted again (FR59).** The
    /// fingerprint index keeps an entry while it is used, and a copy takes the source's dates (FR32): replace
    /// a document with a same-size one carrying the old modification date and its path, mtime and
    /// size are all unchanged, so a key of those three served the replaced document's fingerprint,
    /// and Duplicates could call a different file "same text" and offer to trash a copy. The key
    /// now carries the file number and status-change time, as the byte-hash key does.
    @Test func aDocumentReplacedUnderItsOldDatesIsFingerprintedAgain() async throws {
        let root = try makeCanonicalTempRoot(prefix: "FingerprintKey")
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("letter.pdf")
        let fm = FileManager.default
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try write(doc, bytes: 4096, fill: 0x41)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: doc.path)
        func triple() throws -> ContentHashKey {
            let attrs = try fm.attributesOfItem(atPath: doc.path)
            return ContentHashKey(path: doc.path,
                                  mtime: try #require(attrs[.modificationDate] as? Date).timeIntervalSince1970,
                                  size: try #require((attrs[.size] as? NSNumber)?.intValue))
        }
        let before = try triple()
        let cache = ContentHashCache()
        let first = await FileSyncManager.fingerprintDocuments([doc.path], fileManager: fm, cache: cache,
                                                               extract: { _ in .digest("fingerprint-of-the-first") })
        #expect(first[doc.path] == "fingerprint-of-the-first")

        // A copy over it: a different document, the same size, the old date.
        try fm.removeItem(at: doc)
        try write(doc, bytes: 4096, fill: 0x42)
        try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: doc.path)
        #expect(try triple() == before, "the fixture must leave path, mtime and size exactly as they were")

        let second = await FileSyncManager.fingerprintDocuments([doc.path], fileManager: fm, cache: cache,
                                                                extract: { _ in .digest("fingerprint-of-the-second") })
        #expect(second[doc.path] == "fingerprint-of-the-second",
                "the replaced document's fingerprint was served from the cache")
    }
}
