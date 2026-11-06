import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// The verdict cache's set-aside of an unreadable file, which holds up to ~10MB of paid answers.
/// Each episode gets its own name, so a second episode can't delete the first one's rescue, the
/// only copy of those verdicts (a set-aside is never read back). Nothing is removed before the
/// move, so a failed move costs nothing. And a failed set-aside keeps the next `save` refused until
/// the move works, as `PersonTagStore` does, or that save would write emptiness over the bytes.
@Suite struct FilingVerdictSetAsideTests {


    private func cacheURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "VerdictSetAside-\(name)")
        return dir.appendingPathComponent("filing-verdicts.json")
    }

    /// Every set-aside beside the store, sorted by name: ``setAsidesBeside(_:)``, shared with the
    /// person-tag and storage suites.
    private func setAsides(beside url: URL) -> [URL] { setAsidesBeside(url) }

    private func key(_ path: String) -> FilingVerdictKey {
        // Force-unwrapped: failable only for an unknown mtime or size, both literal here.
        FilingVerdictKey(filePath: path, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                         size: 5000, model: "test-model", promptVersion: 1, artifacts: "")!
    }

    private func cache(_ path: String) -> FilingVerdictCache {
        var c = FilingVerdictCache()
        c.record(FilingVerdict(relativePath: "Documents/Vehicles/Tesla", confidence: .high,
                               reason: "Tesla paperwork", proposesNewFolder: true),
                 for: key(path), providerRoot: "/root", existingRelative: ["Documents"], now: Date())
        return c
    }

    // MARK: - Finding 1: one fixed slot destroys an earlier episode's rescue

    /// A second unreadable episode must not destroy the first episode's rescue. That rescue is
    /// never read back into the cache, so the set-aside is those paid answers.
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

    /// A leftover set-aside from an earlier session, including one under the old fixed
    /// `filing-verdicts.json.unreadable` name, must neither block this episode's rescue nor be
    /// destroyed by it.
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

    // MARK: - Finding 2: a failed set-aside must gate the write, not merely log

    /// After a failed set-aside, `load` answers an empty cache, and a save that then landed would
    /// write it over the paid verdicts the move failed to protect. The save is refused, and keeps
    /// being refused until the move works, as in `PersonTagStore`.
    @Test func aFailedSetAsideRefusesTheSaveInsteadOfDestroyingTheFile() throws {
        let url = try cacheURL("armed")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let paid = Data("{ not json — and the rename is about to fail too".utf8)
        try paid.write(to: url)

        let fm = MoveBlockedFileManager()
        fm.movesToRefuse = 3                       // the load's attempt, then two saves' attempts
        #expect(FilingVerdictStore.load(from: url, fileManager: fm).count == 0)
        #expect(FileManager.default.contents(atPath: url.path) == paid,
                "the failed set-aside moved something anyway")

        // Save 1: the move fails again. Nothing may land on the user's file.
        #expect(FilingVerdictStore.save(cache("/root/a.pdf"), to: url, fileManager: fm) == false,
                "a save that could not protect the file reported success")
        #expect(FileManager.default.contents(atPath: url.path) == paid,
                "a failed set-aside let the write land on ~10MB of paid verdicts")

        // Save 2, the move still failing: the refusal repeats, so the guard is still armed. A guard
        // that disarmed itself would last exactly one save.
        #expect(FilingVerdictStore.save(cache("/root/b.pdf"), to: url, fileManager: fm) == false)
        #expect(FileManager.default.contents(atPath: url.path) == paid,
                "one failed set-aside disarmed the guard and the next save overwrote the file")

        // The obstruction clears: this save sets the original bytes aside and writes fresh.
        #expect(FilingVerdictStore.save(cache("/root/c.pdf"), to: url, fileManager: fm),
                "the save was still refused after the set-aside became possible")
        let kept = try #require(setAsides(beside: url).first, "no set-aside was written")
        #expect(FileManager.default.contents(atPath: kept.path) == paid,
                "the set-aside does not hold the user's original bytes")
        #expect(FilingVerdictStore.load(from: url).count == 1,
                "the fresh cache was not written after the rescue landed")
    }

    /// A move that fails must not have removed anything first: a refused rescue leaves an earlier
    /// episode's bytes untouched, whatever name they sit under, and leaves the current file in
    /// place.
    @Test func aRefusedRescueCostsNeitherTheEarlierSetAsideNorTheCurrentFile() throws {
        let url = try cacheURL("refused")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = url.appendingPathExtension("unreadable")
        let earlier = Data("an earlier episode's rescued paid verdicts".utf8)
        try earlier.write(to: legacy)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)

        let fm = MoveBlockedFileManager()
        fm.movesToRefuse = 9
        #expect(FilingVerdictStore.load(from: url, fileManager: fm).count == 0)
        #expect(FilingVerdictStore.save(cache("/root/a.pdf"), to: url, fileManager: fm) == false)

        #expect(FileManager.default.contents(atPath: legacy.path) == earlier,
                "a move that failed cost the earlier episode's rescue")
        #expect(FileManager.default.contents(atPath: url.path) == corrupt,
                "the refused save landed on the unreadable file anyway")
    }

    /// A source that vanishes after the guard armed (deleted or moved by hand) disarms it. Every
    /// retry would fail source-absent, so a guard that stayed armed would refuse every save for the
    /// rest of the launch and drop fresh verdicts, with nothing left at the path to protect.
    @Test func aVanishedSourceDoesNotLockOutEverySave() throws {
        let url = try cacheURL("vanished")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{ not json — and about to be hand-deleted".utf8).write(to: url)

        let fm = MoveBlockedFileManager()
        fm.movesToRefuse = 1                                  // the load's rescue fails: armed
        #expect(FilingVerdictStore.load(from: url, fileManager: fm).count == 0)
        try FileManager.default.removeItem(at: url)           // the user deletes the file

        #expect(FilingVerdictStore.save(cache("/root/a.pdf"), to: url),
                "the save was refused although there was nothing left to set aside")
        #expect(FilingVerdictStore.load(from: url).count == 1)

        // ...and it stays healed: the next save is ordinary, not another refusal.
        #expect(FilingVerdictStore.save(cache("/root/b.pdf"), to: url))
        #expect(FilingVerdictStore.load(from: url).count == 1)
    }

}

// MARK: - The set-aside's own sentence

/// Each half of the set-aside's log line is said by whoever can know it. From `save` a fresh cache
/// follows at once. From `load` nothing is written, and if the launch never records a verdict
/// nothing ever is, so promising a fresh cache would send the user looking for a file that isn't
/// there. `StorageLensStore.setAsideUnreadable` splits its sentence the same way.
@Suite struct FilingVerdictSetAsideMessageTests {

    /// The fragment has to identify the episode, which is why each one names its own cache file.
    /// The set-aside's stamp has one-second resolution and is uniquified only against its own
    /// directory (`UnreadableSetAside.destination`), and the log line carries only the file name, so
    /// two episodes in different temp directories within a second would log identical lines, and a
    /// concurrent sibling's line could satisfy this one's assertions. The fix belongs in the
    /// fixture: production names are unique within their directory, the only place that matters.
    /// The line is read from a capture the episode opened before acting, so the rest of the package
    /// can't roll it out of the shared buffer (`docs/flaky-tests.md`, "A log assertion reading a
    /// window that has already rolled").
    @MainActor
    private func loggedLine(_ log: LogCapture, containing fragment: String) async -> String? {
        await log.entries.last { $0.message.contains(fragment) }?.message
    }

    /// A cache file name no other episode can produce, so the set-aside made from it is nameable.
    private func uniqueCacheName() -> String { "filing-verdicts-\(UUID().uuidString).json" }

    /// The part of the line after "…has been kept as <name>.": the clause that says what happens
    /// next, which is the caller's fact and not the set-aside's.
    private func tail(of line: String, keptName: String) -> String {
        guard let r = line.range(of: keptName) else { return line }
        return String(line[r.upperBound...])
    }

    /// A set-aside made from `load`, with the file it left behind and the line it wrote.
    @MainActor
    private func loadEpisode() async throws -> (kept: URL, line: String, wroteFile: Bool) {
        let log = LogCapture()
        let dir = try makeCanonicalTempRoot(prefix: "VerdictMsg-load")
        let url = dir.appendingPathComponent(uniqueCacheName())
        try Data("{ not json — half a 12MB write".utf8).write(to: url)
        #expect(FilingVerdictStore.load(from: url).count == 0)
        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        let line = try #require(await loggedLine(log, containing: kept.lastPathComponent),
                                "the set-aside was not logged at all")
        return (kept, line, FileManager.default.fileExists(atPath: url.path))
    }

    /// A set-aside made from `save`, which really does write a fresh cache beside the kept file.
    /// The load's own attempt is blocked so the rescue happens on the save path.
    @MainActor
    private func saveEpisode() async throws -> (kept: URL, line: String, wroteFile: Bool) {
        let log = LogCapture()
        let dir = try makeCanonicalTempRoot(prefix: "VerdictMsg-save")
        let url = dir.appendingPathComponent(uniqueCacheName())
        try Data("{ not json".utf8).write(to: url)
        let blocked = MoveBlockedFileManager()
        blocked.movesToRefuse = 1
        _ = FilingVerdictStore.load(from: url, fileManager: blocked)
        #expect(FileManager.default.contents(atPath: url.path) != nil,
                "fixture: the load's set-aside was supposed to be blocked")
        #expect(FilingVerdictStore.save(FilingVerdictCache(), to: url))
        let kept = try #require(setAsidesBeside(url).first, "the save did not rescue the file")
        let line = try #require(await loggedLine(log, containing: kept.lastPathComponent),
                                "the set-aside was not logged at all")
        return (kept, line, FileManager.default.fileExists(atPath: url.path))
    }

    /// The precondition the three tests below rest on: an episode's line must be nameable. Two
    /// episodes in different temp roots must get different set-aside names, or nothing downstream
    /// can tell their lines apart. A property of the fixture, so it is checked deterministically
    /// rather than left to an interleaving that turns it red.
    @Test @MainActor func twoEpisodesDoNotProduceTheSameSetAsideName() async throws {
        let a = try await loadEpisode()
        defer { try? FileManager.default.removeItem(at: a.kept.deletingLastPathComponent()) }
        let b = try await loadEpisode()
        defer { try? FileManager.default.removeItem(at: b.kept.deletingLastPathComponent()) }
        #expect(a.kept.lastPathComponent != b.kept.lastPathComponent,
                """
                two episodes share a set-aside name, so `loggedLine` cannot tell their lines                 apart and a concurrent sibling's line satisfies this one's assertions
                """)
    }

    /// The two callers leave the user in different places, so they must not say the same thing.
    /// Stated as a difference between the two lines rather than a search for a phrase, which a
    /// re-spelling of the same false promise would satisfy.
    @Test @MainActor func theTwoCallersDoNotMakeTheSamePromise() async throws {
        let load = try await loadEpisode()
        defer { try? FileManager.default.removeItem(at: load.kept.deletingLastPathComponent()) }
        let save = try await saveEpisode()
        defer { try? FileManager.default.removeItem(at: save.kept.deletingLastPathComponent()) }

        // The facts the sentences have to match, measured rather than assumed.
        #expect(load.wroteFile == false, "fixture: a load wrote a file, so there is nothing to fix")
        #expect(save.wroteFile, "fixture: the save wrote no fresh cache, so there is no promise")

        let loadTail = tail(of: load.line, keptName: load.kept.lastPathComponent)
        let saveTail = tail(of: save.line, keptName: save.kept.lastPathComponent)
        #expect(loadTail != saveTail,
                """
                both callers say the same thing about what happens next, and only one of them \
                writes anything — load left: “\(loadTail)”
                """)
    }

    /// After a `load` nothing is at the path, so the line may not send the user looking for a new
    /// file beside the kept one. Any wording of that promise needs the word "fresh".
    @Test @MainActor func aLoadThatWritesNothingPromisesNoNewFile() async throws {
        let load = try await loadEpisode()
        defer { try? FileManager.default.removeItem(at: load.kept.deletingLastPathComponent()) }
        #expect(load.wroteFile == false, "fixture: a load wrote a file")

        let tail = tail(of: load.line, keptName: load.kept.lastPathComponent).lowercased()
        #expect(!tail.contains("fresh"),
                """
                the load claimed a fresh cache beside the kept file. Nothing was written, and if \
                this launch records no verdict nothing ever will be — “\(tail)”
                """)
    }

    /// The other direction, so the fix can't become "never say anything": from `save` a fresh
    /// cache really does follow, and the line must say so.
    @Test @MainActor func aSaveThatWritesOneDoesSaySo() async throws {
        let save = try await saveEpisode()
        defer { try? FileManager.default.removeItem(at: save.kept.deletingLastPathComponent()) }
        #expect(save.wroteFile, "fixture: the save wrote no fresh cache")
        #expect(tail(of: save.line, keptName: save.kept.lastPathComponent).contains("fresh cache"),
                "the save stopped saying that a fresh cache was written beside the kept file")
    }
}

// MARK: - A newer build's cache

/// A `filing-verdicts.json` written by a newer build is good data, and must survive. Its unknown
/// schema decodes as an empty cache rather than throwing, so the decode guard alone would arm
/// nothing and the next `save` would write an empty cache over it. It isn't routed through the
/// set-aside either: a foreign schema repeats on every launch of an old/new build ping-pong, and
/// each round would mint another ~12 MB dated file that nothing sweeps. The file stays where it
/// is, this launch works from memory, and the write is refused.
@Suite struct FilingVerdictForeignSchemaTests {

    private func cacheURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "VerdictSchema-\(name)")
        return dir.appendingPathComponent("filing-verdicts.json")
    }

    private var future: Data { Data(#"{"schema":99,"entries":[]}"#.utf8) }

    @Test func aNewerBuildsCacheIsNotOverwritten() throws {
        let url = try cacheURL("overwrite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try future.write(to: url)

        #expect(FilingVerdictStore.load(from: url).count == 0,
                "fixture: this build cannot read a newer schema, and must not pretend to")
        #expect(FilingVerdictStore.save(FilingVerdictCache(), to: url) == false,
                "the save was allowed to proceed over a newer build's paid verdicts")
        #expect(FileManager.default.contents(atPath: url.path) == future,
                "a newer build's ~12 MB of paid answers were overwritten")
    }

    /// Nor is it treated as an unreadable episode, so a ping-pong between two builds can't mint a
    /// ~12 MB dated file on every launch with nothing to sweep them.
    @Test func aNewerBuildsCacheMintsNoSetAsides() throws {
        let url = try cacheURL("pingpong")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for _ in 0..<5 {
            try future.write(to: url)
            _ = FilingVerdictStore.load(from: url)
            _ = FilingVerdictStore.save(FilingVerdictCache(), to: url)
        }
        #expect(setAsidesBeside(url).isEmpty,
                """
                \(setAsidesBeside(url).count) set-aside(s) after five rounds of an old/new build \
                ping-pong — at the entry cap that is ~12 MB apiece, and nothing sweeps them
                """)
    }

    /// The other direction: bytes that are genuinely unreadable are still set aside.
    @Test func corruptBytesAreStillRescued() throws {
        let url = try cacheURL("corrupt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{ half a 12MB write".utf8)
        try corrupt.write(to: url)

        #expect(FilingVerdictStore.load(from: url).count == 0)
        let kept = try #require(setAsidesBeside(url).first, "corrupt bytes stopped being rescued")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt)
    }
}
