import Events
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

    /// Every set-aside beside the store, sorted by name — ``setAsidesBeside(_:)``, shared with the
    /// person-tag and storage suites rather than spelled a third time here.
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

    // MARK: - Finding 2: a failed set-aside must gate the write, not merely log

    /// **A save that lands after a failed set-aside is the original defect with extra steps.**
    /// `load` answers an empty cache and the next `save` wrote it straight over the paid verdicts
    /// the move had failed to protect. The doc admitted this and called it a residual; it is the
    /// finding. `PersonTagStore` refuses in exactly this situation and keeps refusing until the
    /// move works.
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

        // Save 2, the move still failing: the refusal repeats — the observable form of "the guard
        // is still armed". A guard that disarms itself lasts exactly one save.
        #expect(FilingVerdictStore.save(cache("/root/b.pdf"), to: url, fileManager: fm) == false)
        #expect(FileManager.default.contents(atPath: url.path) == paid,
                "one failed set-aside disarmed the guard and the next save overwrote the file")

        // The obstruction clears: this save sets the ORIGINAL bytes aside and writes fresh.
        #expect(FilingVerdictStore.save(cache("/root/c.pdf"), to: url, fileManager: fm),
                "the save was still refused after the set-aside became possible")
        let kept = try #require(setAsides(beside: url).first, "no set-aside was written")
        #expect(FileManager.default.contents(atPath: kept.path) == paid,
                "the set-aside does not hold the user's original bytes")
        #expect(FilingVerdictStore.load(from: url).count == 1,
                "the fresh cache was not written after the rescue landed")
    }

    /// **A move that fails must not have removed anything first.** Per-episode names left no
    /// collision to handle, so no `removeItem` exists at all — this is what keeps one from coming
    /// back: a refused rescue leaves an earlier episode's bytes untouched, whatever name they sit
    /// under, and leaves the current file exposed to nothing.
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

    /// **A source that vanishes mid-launch is the protection arriving by other means.** With the
    /// guard armed, the file is deleted (or moved) by hand: every retry then fails source-absent,
    /// so a guard that stayed armed would refuse every save for the rest of the launch and drop
    /// this scan's fresh verdicts — with nothing left at the path to protect.
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

/// **Each half of the sentence is said by whoever can actually know it.**
///
/// `StorageLensStore.setAsideUnreadable` was changed on this branch to stop promising the caller's
/// outcome, with the reason written at its call site: "each says its own half rather than this one
/// promising a 'fresh file' that a forget never produces". `FilingVerdictStore` still carried the
/// unsplit version — "a fresh cache starts beside it" — from BOTH callers.
///
/// From `save` that is true; a fresh cache follows immediately. From `load` nothing is written, and
/// if the launch never records a verdict nothing ever is: the user is sent to look beside the kept
/// file for something that is not there, at exactly the moment they are trying to work out what
/// happened to ~12 MB of paid answers.
@Suite struct FilingVerdictSetAsideMessageTests {

    /// **The fragment has to identify the EPISODE, which is why each one names its own cache
    /// file.** The set-aside's name is `<cache name>.unreadable-<stamp>` and the stamp is
    /// `yyyy-MM-dd'T'HH:mm:ss` — one-second resolution, uniquified only against the directory it
    /// lands in (`UnreadableSetAside.destination`). Two episodes in different temp directories
    /// within the same second therefore produce the byte-identical *file name*, and the log line
    /// carries only `lastPathComponent` — no directory anywhere in it — so `entries.last` cannot
    /// tell one episode's line from the other's. That is what took CI red on `ac37e9d8`: the load
    /// and the save read the same line, so `theTwoCallersDoNotMakeTheSamePromise` compared a
    /// sentence with itself, and `aLoadThatWritesNothingPromisesNoNewFile` — which never runs a
    /// save at all — read its concurrent sibling's.
    ///
    /// Fixed in the fixture rather than in the message: production names are unique within the
    /// directory they are written to, which is the only place uniqueness means anything to a file.
    /// See `docs/flaky-tests.md`, the rolled log window, for why a bounded window would not have
    /// closed this — it bounds time, not authorship, and these two run concurrently.
    @MainActor
    private func loggedLine(containing fragment: String) async -> String? {
        await Logger.shared.debug("verdict-message flush marker").value
        return Logger.shared.entries.last { $0.message.contains(fragment) }?.message
    }

    /// A cache file name no other episode can produce, so the set-aside made from it is nameable.
    private func uniqueCacheName() -> String { "filing-verdicts-\(UUID().uuidString).json" }

    /// The part of the line AFTER "…has been kept as <name>." — the clause that says what happens
    /// next, which is the caller's fact and not the set-aside's.
    private func tail(of line: String, keptName: String) -> String {
        guard let r = line.range(of: keptName) else { return line }
        return String(line[r.upperBound...])
    }

    /// A set-aside made from `load`, with the file it left behind and the line it wrote.
    @MainActor
    private func loadEpisode() async throws -> (kept: URL, line: String, wroteFile: Bool) {
        let dir = try makeCanonicalTempRoot(prefix: "VerdictMsg-load")
        let url = dir.appendingPathComponent(uniqueCacheName())
        try Data("{ not json — half a 12MB write".utf8).write(to: url)
        #expect(FilingVerdictStore.load(from: url).count == 0)
        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        let line = try #require(await loggedLine(containing: kept.lastPathComponent),
                                "the set-aside was not logged at all")
        return (kept, line, FileManager.default.fileExists(atPath: url.path))
    }

    /// A set-aside made from `save`, which really does write a fresh cache beside the kept file.
    /// The load's own attempt is blocked so the rescue happens on the save path.
    @MainActor
    private func saveEpisode() async throws -> (kept: URL, line: String, wroteFile: Bool) {
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
        let line = try #require(await loggedLine(containing: kept.lastPathComponent),
                                "the set-aside was not logged at all")
        return (kept, line, FileManager.default.fileExists(atPath: url.path))
    }

    /// **The precondition the three tests below all rest on: an episode's line must be nameable.**
    ///
    /// Deterministic, where the failure it guards is not. The set-aside stamp is one-second
    /// resolution and is uniquified only against its own directory, so two episodes a millisecond
    /// apart in different temp roots used to produce the byte-identical file name — and since the
    /// log line carries no directory, nothing downstream could tell their lines apart. That is a
    /// property of the fixture, so it is checked as one, rather than waiting for the interleaving
    /// that turns it into a red run.
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

    /// **The two callers leave the user in different places, so they must not say the same thing.**
    ///
    /// Stated as a difference between the two lines rather than as a search for a phrase: a guard
    /// that pins the old wording is satisfied by re-spelling the same false promise, which is
    /// exactly what a first attempt at this test did — it passed with `load` claiming "A fresh
    /// cache is written beside it."
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

    /// And the half that matters most, stated on the fact rather than on a phrase: after a `load`
    /// nothing is at the path, so the line may not send the user looking for a new file beside the
    /// kept one. Any wording of that promise needs the word.
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

    /// The other direction, so the fix cannot become "never say anything": from `save` a fresh
    /// cache really does follow, and the line is required to say so.
    @Test @MainActor func aSaveThatWritesOneDoesSaySo() async throws {
        let save = try await saveEpisode()
        defer { try? FileManager.default.removeItem(at: save.kept.deletingLastPathComponent()) }
        #expect(save.wroteFile, "fixture: the save wrote no fresh cache")
        #expect(tail(of: save.line, keptName: save.kept.lastPathComponent).contains("fresh cache"),
                "the save stopped saying that a fresh cache was written beside the kept file")
    }
}

// MARK: - A newer build's cache

/// **A `filing-verdicts.json` written by a NEWER build is good data, and this build destroyed it
/// silently.**
///
/// `FilingVerdictCache.init(from:)` answers an EMPTY cache for a schema it does not know rather
/// than throwing, so `load`'s decode guard never fired: nothing was armed, nothing was set aside,
/// and the next `save` wrote an empty cache straight over the file. Measured on this branch before
/// the fix — `bytes intact after save = false`, `set-asides = []` — over what the store's own doc
/// calls "~10MB of PAID answers".
///
/// The fix is NOT to route it through the set-aside machinery. That is what `StorageLensStore` did,
/// and a foreign schema is not an episode: it repeats every launch of an old/new ping-pong, each
/// round minting another ~12 MB dated file that nothing sweeps. It is its own case — the file
/// stays exactly where it is, this launch works from memory, and the write is refused.
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

    /// And it is not treated as an unreadable episode either, so a ping-pong between two builds
    /// cannot mint a ~12 MB dated file on every launch with nothing to sweep them.
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

    /// The other direction: bytes that are genuinely unreadable are still rescued, and the store
    /// still refuses to write until the rescue lands.
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
