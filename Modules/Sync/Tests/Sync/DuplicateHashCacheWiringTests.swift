import Testing
import Foundation
@testable import Sync

/// Proves Tidy's two hashing entry points actually CONSULT the session hash cache.
///
/// Verify has used `ContentHashCache` since it was written; Tidy's duplicate scan and merge planner
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

    /// The key `FileContentVerifier` builds for a real file: resolved path, mtime, size.
    private func key(for url: URL) throws -> ContentHashKey {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require((attrs[.size] as? NSNumber)?.intValue)
        let mtime = try #require(attrs[.modificationDate] as? Date)
        return ContentHashKey(path: url.path, mtime: mtime.timeIntervalSince1970, size: size)
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

    /// A cached digest is served even for a file over the size cap, because the cache holds digests
    /// while the cap only decides whether computing one is worth it. Pinned because it is the one
    /// place a hit changes a classification, and it is why a caller varying the cap must not share
    /// a cache (see `hashFilesCounting`).
    @MainActor
    @Test func aCachedDigestIsServedDespiteTheSizeCap() async throws {
        let root = try makeCanonicalTempRoot(prefix: "DuplicateCacheCap")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A/movie.mp4")
        let b = root.appendingPathComponent("B/movie.mp4")
        try write(a, bytes: 5000, fill: 0x42)
        try write(b, bytes: 5000, fill: 0x42)

        // Uncached, a 1000-byte cap skips both and no group can form.
        let capped = FileSyncManager()
        await capped.findDuplicates(root: root, maxBytesToHash: 1000, cache: nil)
        #expect(capped.duplicateScanSkips.tooLarge == 2)
        #expect(capped.duplicateGroups.isEmpty)

        // With both digests already known, the same capped scan groups them and skips nothing.
        let cache = ContentHashCache()
        let digest = String(repeating: "a", count: 64)
        await cache.store(digest, for: try key(for: a))
        await cache.store(digest, for: try key(for: b))

        let warm = FileSyncManager()
        await warm.findDuplicates(root: root, maxBytesToHash: 1000, cache: cache)
        #expect(warm.duplicateScanSkips.tooLarge == 0)
        #expect(warm.duplicateGroups.count == 1)
    }

    /// The headline claim: Verify and Tidy stop paying for each other's work. Verify hashes through
    /// the shared cache; a Tidy scan of the same files must then find those digests already there.
    /// Proved the same way — by what Verify leaves behind being the thing Tidy answers from.
    @MainActor
    @Test func aVerifyPopulatesTheCacheThatTidyThenReadsFrom() async throws {
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
}
