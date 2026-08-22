import Foundation
import Testing
@testable import Sync

/// **The verdict cache's set-aside carried the two defects the person-tag store had just fixed.**
///
/// `FilingVerdictStore.setAsideUnreadable` moved the unreadable file to ONE fixed slot
/// (`filing-verdicts.json.unreadable`) after an unconditional `removeItem` on it — in the file the
/// store's own doc calls "~10MB of PAID answers". Two losses follow, and neither is hypothetical:
///
/// - a SECOND unreadable episode deleted episode 1's rescue, which is the ONLY copy of those
///   verdicts (a set-aside is never re-ingested);
/// - the remove happened BEFORE the move, so a move that then failed left the user with neither
///   the earlier rescue nor a protected current file — strictly worse than not trying.
///
/// And the write was not gated on the set-aside landing: `load` answered an empty cache, and the
/// next `save` wrote that emptiness straight over bytes the move had failed to protect. The store's
/// own doc admitted this ("the next save can still land on the file"), which is the finding rather
/// than a justification — `PersonTagStore` keeps its guard armed until the move actually works.
@Suite struct FilingVerdictSetAsideTests {

    private func cacheURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "VerdictSetAside-\(name)")
        return dir.appendingPathComponent("filing-verdicts.json")
    }

    /// Every set-aside beside the store, sorted by name. The kept name is unique per episode, so
    /// tests discover the files rather than assuming a single fixed slot.
    private func setAsides(beside url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".unreadable"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { dir.appendingPathComponent($0) }
    }

    private func key(_ path: String) -> FilingVerdictKey {
        FilingVerdictKey(filePath: path, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                         size: 5000, model: "test-model", promptVersion: 1, artifacts: "")
    }

    private func cache(_ path: String) -> FilingVerdictCache {
        var c = FilingVerdictCache()
        c.record(FilingVerdict(relativePath: "Documents/Vehicles/Tesla", confidence: .high,
                               reason: "Tesla paperwork", proposesNewFolder: true),
                 for: key(path), providerRoot: "/root", existingRelative: ["Documents"], now: Date())
        return c
    }

    // MARK: - Finding 1: one fixed slot destroys an earlier episode's rescue

    /// **A second unreadable episode must not destroy the only copy of the first episode's paid
    /// verdicts.** Episode 1's rescue is never read back into the cache, so the set-aside IS those
    /// answers; the single-slot name made episode 2's `removeItem` delete them permanently.
    @Test func aSecondUnreadableEpisodeDoesNotDestroyTheFirstEpisodesRescue() throws {
        let url = try cacheURL("episodes")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let episode1 = Data("{ episode one — ~10MB of paid answers, unreadable".utf8)
        try episode1.write(to: url)
        #expect(FilingVerdictStore.load(from: url).count == 0)

        let episode2 = Data("{ episode two — the fresh file corrupted too".utf8)
        try episode2.write(to: url)
        #expect(FilingVerdictStore.load(from: url).count == 0)

        let keptBytes = setAsides(beside: url).compactMap { FileManager.default.contents(atPath: $0.path) }
        #expect(keptBytes.contains(episode1),
                "episode 2's set-aside destroyed the only copy of episode 1's paid verdicts")
        #expect(keptBytes.contains(episode2), "episode 2's own bytes were not set aside")
    }

    /// A leftover set-aside from an earlier session — including one under the old fixed
    /// `filing-verdicts.json.unreadable` name a previous build wrote — must neither block this
    /// episode's rescue nor be destroyed by it.
    @Test func aLeftoverSetAsideNeitherBlocksNorIsDestroyed() throws {
        let url = try cacheURL("leftover")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = url.appendingPathExtension("unreadable")
        let earlier = Data("an earlier episode's rescued verdicts".utf8)
        try earlier.write(to: legacy)
        let corrupt = Data("{ not json — half a 10MB write".utf8)
        try corrupt.write(to: url)

        #expect(FilingVerdictStore.load(from: url).count == 0)

        #expect(FileManager.default.contents(atPath: legacy.path) == earlier,
                "the earlier episode's set-aside was destroyed by this one")
        let keptBytes = setAsides(beside: url).compactMap { FileManager.default.contents(atPath: $0.path) }
        #expect(keptBytes.contains(corrupt), "the leftover blocked this episode's set-aside")
    }

    /// The ordinary path is untouched: a readable file is neither set aside nor disturbed.
    @Test func aReadableCacheIsNeverSetAside() throws {
        let url = try cacheURL("ordinary")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FilingVerdictStore.save(cache("/root/f.pdf"), to: url))
        #expect(FilingVerdictStore.load(from: url).count == 1)
        #expect(setAsides(beside: url).isEmpty, "a readable cache was set aside")
    }

    /// An absent file stays silent: a first launch has nothing to protect and nothing to keep.
    @Test func anAbsentCacheLeavesNoSetAside() throws {
        let url = try cacheURL("absent")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FilingVerdictStore.load(from: url).count == 0)
        #expect(setAsides(beside: url).isEmpty)
        #expect(FilingVerdictStore.save(cache("/root/f.pdf"), to: url),
                "the write was refused although there was never a file to protect")
    }
}
