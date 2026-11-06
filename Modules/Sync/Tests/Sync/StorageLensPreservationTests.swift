import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// Both `StorageLensStore` writers are read-modify-writes, so the read must tell an absent file
/// from one it couldn't decode or one written under another schema. Read as `[]`, the next analysis
/// would write one snapshot over every other root's, and "Forget this root" would filter `[]` to
/// `[]` and trip the guard that deletes the file: forget one would mean forget all.
/// `FilingProfileStore.indexForAmending` follows the same rule: it refuses to amend what it
/// couldn't read.
@Suite struct StorageLensPreservationTests {

    private func storeURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "StoragePreserve-\(name)")
        return dir.appendingPathComponent("storage-lens.json")
    }

    private func report(_ bytes: Int = 1234) -> StorageLensReport {
        StorageLensReport(treemap: [TreemapNode(name: "D", path: "/r/D", bytes: bytes)],
                          largest: [], stale: [], reclaimCandidates: [], totalBytes: bytes,
                          fileCount: 0, staleCount: 0, reclaimCount: 0, reclaimableBytes: 0)
    }

    private func snapshot(_ root: String, at: TimeInterval = 1_800_000_000) -> StorageLensSnapshot {
        StorageLensSnapshot(root: root, report: report(), completedAt: Date(timeIntervalSince1970: at))
    }

    /// A new analysis must not replace a file it could not read with a single snapshot.
    @Test func anUnreadableFileIsKeptRatherThanReplaced() throws {
        let url = try storeURL("save")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{\"schema\":1,\"snapshots\":[{\"root\":\"/a\"".utf8)   // truncated
        try corrupt.write(to: url)

        StorageLensStore.saveInBackground(snapshot("/b"), to: url)
        StorageLensStore.waitForPendingWrites()

        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "the other roots were destroyed rather than kept")
        // ...and the app kept working: the new analysis is on disk beside it.
        #expect(StorageLensStore.load(from: url).map(\.root) == ["/b"])
    }

    /// A file from a newer build is good data, not corruption: it is kept where it is, not set
    /// aside (`aForeignSchemaIsNotAnUnreadableEpisode` says why).
    @Test func aForeignSchemaIsKeptRatherThanOverwritten() throws {
        let url = try storeURL("schema")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let future = Data("{\"schema\":99,\"snapshots\":[]}".utf8)
        try future.write(to: url)

        StorageLensStore.saveInBackground(snapshot("/b"), to: url)
        StorageLensStore.waitForPendingWrites()

        #expect(FileManager.default.contents(atPath: url.path) == future,
                "a newer build's file was overwritten")
    }

    /// A newer build's file is not a self-clearing episode. Corruption clears: the set-aside frees
    /// the path and the next write lands a readable file. A foreign schema repeats: this build would
    /// set the newer file aside and write its own, the newer build would do the same back, and every
    /// launch would mint another set-aside that nothing sweeps (about 12 MB each for
    /// `FilingVerdictCache`). So the file stays where it is, this build works from memory, the write
    /// is refused, and the log tells the user how to recover.
    @Test func aForeignSchemaIsNotAnUnreadableEpisode() throws {
        let url = try storeURL("pingpong")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let future = Data("{\"schema\":99,\"snapshots\":[]}".utf8)
        try future.write(to: url)

        // Five rounds of the ping-pong: the newer build writes its file, then this build runs.
        for _ in 0..<5 {
            try future.write(to: url)
            StorageLensStore.saveInBackground(snapshot("/b"), to: url)
            StorageLensStore.waitForPendingWrites()
        }

        #expect(setAsidesBeside(url).isEmpty,
                """
                \(setAsidesBeside(url).count) set-aside(s) after five rounds of an old/new \
                build ping-pong, and nothing anywhere sweeps them
                """)
        #expect(FileManager.default.contents(atPath: url.path) == future,
                "the newer build's file did not survive")
    }

    /// The tests above write `{"schema":99,"snapshots":[]}`, a foreign version whose payload this
    /// build still decodes. A real schema bump usually changes the record, so this build's `Payload`
    /// decode fails; if the schema check ran only after a full decode, the read would answer
    /// `.unreadable` and the ping-pong would return. This pins the check before the decode.
    @Test func aForeignSchemaWhoseRecordsThisBuildCannotDecodeIsStillNotAnEpisode() throws {
        let url = try storeURL("pingpongShape")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Schema 99 AND a snapshot record of a shape this build has no model for.
        let future = Data("""
        {"schema":99,"snapshots":[{"root":"/b","aFieldThisBuildHasNever":true}]}
        """.utf8)

        for _ in 0..<5 {
            try future.write(to: url)
            StorageLensStore.saveInBackground(snapshot("/b"), to: url)
            StorageLensStore.waitForPendingWrites()
        }

        #expect(setAsidesBeside(url).isEmpty,
                """
                \(setAsidesBeside(url).count) set-aside(s) after five rounds — a newer build's \
                file whose RECORDS this build cannot decode is still being treated as an \
                unreadable episode
                """)
        #expect(FileManager.default.contents(atPath: url.path) == future,
                "the newer build's file did not survive")
    }

    /// The other direction, so the case above can't become "nothing is ever set aside": genuinely
    /// unreadable bytes still are, and only once, since the path is free afterwards and the next
    /// write lands a fresh file.
    @Test func aGenuinelyUnreadableFileIsStillSetAsideAndOnlyOnce() throws {
        let url = try storeURL("oneepisode")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{ truncated".utf8).write(to: url)

        for _ in 0..<5 {
            StorageLensStore.saveInBackground(snapshot("/b"), to: url)
            StorageLensStore.waitForPendingWrites()
        }
        #expect(setAsidesBeside(url).count == 1,
                "one corruption episode minted \(setAsidesBeside(url).count) set-asides")
    }

    /// The read layer has the same two states as the parse layer. A file that exists but can't be
    /// opened (mode 000, an ACL, an I/O error) must read as `.unreadable`, not `.absent`, or
    /// `saveInBackground` merges into `[]` and writes one snapshot over every root's.
    @Test func aFileTheProcessCannotOpenReadsAsUnreadableNotAbsent() throws {
        let url = try storeURL("mode000")
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? fm.removeItem(at: url.deletingLastPathComponent())
        }
        try Data("{\"schema\":1,\"snapshots\":[]}".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        guard case .unreadable = StorageLensStore.read(from: url) else {
            Issue.record("an exists-but-unreadable file did not read as .unreadable")
            return
        }
    }

    /// A genuinely absent file still reads `.absent`, so a first scan stays quiet and ordinary.
    @Test func aGenuinelyAbsentFileStillReadsAsAbsent() throws {
        let url = try storeURL("absent")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard case .absent = StorageLensStore.read(from: url) else {
            Issue.record("an absent file did not read as .absent")
            return
        }
    }

    /// End to end: a new analysis must not replace a file the process can't open, the promise
    /// `anUnreadableFileIsKeptRatherThanReplaced` makes for corrupt bytes.
    @Test func aNewAnalysisDoesNotReplaceAFileTheProcessCannotOpen() throws {
        let url = try storeURL("mode000save")
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            for aside in setAsidesBeside(url) {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aside.path)
            }
            try? fm.removeItem(at: url.deletingLastPathComponent())
        }
        // A good file holding another root's snapshot; only the read fails.
        StorageLensStore.saveInBackground(snapshot("/a"), to: url)
        StorageLensStore.waitForPendingWrites()
        let original = try #require(fm.contents(atPath: url.path))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        StorageLensStore.saveInBackground(snapshot("/b"), to: url)
        StorageLensStore.waitForPendingWrites()

        // The set-aside keeps the mode with the bytes; open it up to compare them. The kept name
        // is per-episode (``UnreadableSetAside``), so it is discovered rather than assumed.
        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
        #expect(fm.contents(atPath: kept.path) == original,
                "the unopenable snapshots were overwritten — a failed read mistaken for no file")
        #expect(StorageLensStore.load(from: url).map(\.root) == ["/b"])
    }

    /// "Forget this root" may not empty a file it couldn't read.
    @Test func forgettingOneRootDoesNotForgetAllOfAnUnreadableFile() throws {
        let url = try storeURL("clear")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{\"schema\":1,\"snapshots\":[{\"root\"".utf8)
        try corrupt.write(to: url)

        StorageLensStore.clearInBackground(root: "/a", from: url)
        StorageLensStore.waitForPendingWrites()

        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "forgetting one root destroyed the whole file")
    }

    /// The ordinary paths still work: the refusals must not mean "the store stopped working".
    @Test func aReadableFileStillSavesAndForgetsOneRoot() throws {
        let url = try storeURL("ordinary")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StorageLensStore.saveInBackground(snapshot("/a", at: 1_800_000_000), to: url)
        StorageLensStore.saveInBackground(snapshot("/b", at: 1_800_000_100), to: url)
        StorageLensStore.waitForPendingWrites()
        #expect(Set(StorageLensStore.load(from: url).map(\.root)) == ["/a", "/b"])

        StorageLensStore.clearInBackground(root: "/a", from: url)
        StorageLensStore.waitForPendingWrites()
        #expect(StorageLensStore.load(from: url).map(\.root) == ["/b"],
                "forgetting one root took the other with it")
        #expect(setAsidesBeside(url).isEmpty, "a readable file was set aside")
    }

    /// Forget-all still deletes the file, which is what the user asked for either way.
    @Test func forgettingEverythingStillRemovesTheFile() throws {
        let url = try storeURL("clearall")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StorageLensStore.saveInBackground(snapshot("/a"), to: url)
        StorageLensStore.waitForPendingWrites()
        StorageLensStore.clearInBackground(root: nil, from: url)
        StorageLensStore.waitForPendingWrites()
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    /// Forgetting the last remaining root removes the file too: an empty store has no file.
    @Test func forgettingTheLastRootRemovesTheFile() throws {
        let url = try storeURL("last")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StorageLensStore.saveInBackground(snapshot("/only"), to: url)
        StorageLensStore.waitForPendingWrites()
        StorageLensStore.clearInBackground(root: "/only", from: url)
        StorageLensStore.waitForPendingWrites()
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    // MARK: - The kept name is per-episode, and the log says what actually happened

    /// A second unreadable episode must not destroy the first episode's rescue. A snapshot can be
    /// re-scanned, but a single fixed slot cleared with `removeItem` would lose it; all three stores
    /// share one destination helper that names each episode's file afresh.
    @Test func aSecondUnreadableEpisodeDoesNotDestroyTheFirstEpisodesRescue() throws {
        let url = try storeURL("episodes")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let episode1 = Data("{\"schema\":1,\"snapshots\":[{\"root\":\"/one\"".utf8)
        try episode1.write(to: url)
        StorageLensStore.saveInBackground(snapshot("/a"), to: url)
        StorageLensStore.waitForPendingWrites()

        let episode2 = Data("{\"schema\":1,\"snapshots\":[{\"root\":\"/two\"".utf8)
        try episode2.write(to: url)
        StorageLensStore.saveInBackground(snapshot("/b"), to: url)
        StorageLensStore.waitForPendingWrites()

        let keptBytes = setAsidesBeside(url).compactMap { FileManager.default.contents(atPath: $0.path) }
        #expect(keptBytes.contains(episode1),
                "episode 2's set-aside destroyed the only copy of episode 1's snapshots")
        #expect(keptBytes.contains(episode2), "episode 2's own bytes were not set aside")
        #expect(StorageLensStore.load(from: url).map(\.root) == ["/b"])
    }

    /// A leftover under the fixed `storage-lens.json.unreadable` name an older build wrote must
    /// neither block this episode's rescue nor be destroyed by it.
    @Test func aLeftoverSetAsideNeitherBlocksNorIsDestroyed() throws {
        let url = try storeURL("leftover")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let legacy = url.appendingPathExtension("unreadable")
        let earlier = Data("an earlier episode's snapshots".utf8)
        try earlier.write(to: legacy)
        let corrupt = Data("{\"schema\":1,\"snapshots\":[{\"root\"".utf8)
        try corrupt.write(to: url)

        StorageLensStore.saveInBackground(snapshot("/b"), to: url)
        StorageLensStore.waitForPendingWrites()

        #expect(FileManager.default.contents(atPath: legacy.path) == earlier,
                "the earlier episode's set-aside was destroyed by this one")
        let keptBytes = setAsidesBeside(url).compactMap { FileManager.default.contents(atPath: $0.path) }
        #expect(keptBytes.contains(corrupt), "the leftover blocked this episode's set-aside")
    }

    /// The refusal line must report what happened: if `setAsideUnreadable` failed, it says the file
    /// couldn't be moved aside, not that it was kept. Forget writes no file, so it never promises a
    /// "fresh one" either.
    @MainActor
    @Test func aFailedSetAsideIsNotLoggedAsARescue() async throws {
        let log = LogCapture()
        // A file name unique to this test: `Logger.shared.entries` is process-wide, and the
        // sibling test below logs a line matching every other part of this search.
        let url = try makeCanonicalTempRoot(prefix: "StoragePreserve-clearfail")
            .appendingPathComponent("storage-lens-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{\"schema\":1,\"snapshots\":[{\"root\"".utf8)
        try corrupt.write(to: url)

        let fm = MoveBlockedFileManager()
        fm.movesToRefuse = 9
        StorageLensStore.clearInBackground(root: "/a", from: url, fileManager: fm)
        StorageLensStore.waitForPendingWrites()

        let line = try #require(await log.entries.last {
            $0.message.contains("Forget this root") && $0.message.contains(url.lastPathComponent)
        }, "the refusal was not logged at all")
        #expect(line.message.contains("could not be moved aside"),
                "a failed set-aside was reported as a rescue: \(line.message)")
        #expect(!line.message.contains("has been kept"),
                "the log claimed the file was kept aside when the move failed: \(line.message)")
        // ...and the claim matches the disk: nothing moved, nothing emptied.
        #expect(FileManager.default.contents(atPath: url.path) == corrupt)
        #expect(setAsidesBeside(url).isEmpty)
    }

    /// The other outcome, as precisely: the move landed, so the line names the kept file, and it
    /// promises no fresh one, because forgetting writes none.
    @MainActor
    @Test func aSuccessfulSetAsideNamesTheKeptFileAndPromisesNoFreshOne() async throws {
        let log = LogCapture()
        let url = try makeCanonicalTempRoot(prefix: "StoragePreserve-clearkept")
            .appendingPathComponent("storage-lens-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{\"schema\":1,\"snapshots\":[{\"root\"".utf8)
        try corrupt.write(to: url)

        StorageLensStore.clearInBackground(root: "/a", from: url)
        StorageLensStore.waitForPendingWrites()

        let line = try #require(await log.entries.last {
            $0.message.contains("Forget this root") && $0.message.contains(url.lastPathComponent)
        }, "the refusal was not logged at all")
        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        #expect(line.message.contains(kept.lastPathComponent),
                "the line does not name the file the user has to go and find: \(line.message)")
        #expect(!line.message.contains("fresh one"),
                "forgetting a root writes no fresh file, and the line said it did: \(line.message)")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt)
        #expect(FileManager.default.fileExists(atPath: url.path) == false,
                "the unreadable file was left in place after a set-aside that reported success")
    }

}

/// `StorageLensStore`'s injected `FileManager` must reach the read as well as the moves. A seam
/// that reached only the moves would hand a double the rename and the real filesystem the decision
/// whether a rename is needed, which is the half that decides everything. The seam covers the
/// presence probe and the moves; `Data(contentsOf:)` takes no `FileManager` and is deliberately not
/// faked, since the present-vs-absent decision is what these pin.
@Suite struct StorageLensSeamTests {

    /// Claims one path is present, whatever the disk says: the seam's decision half in isolation.
    /// Scoped to that one path on purpose: `UnreadableSetAside.destination` probes candidate names
    /// with this same call until one is absent, so a double that never says absent would loop (now
    /// bounded, see `UnreadableSetAside`).
    private final class ClaimsPresent: FileManager, @unchecked Sendable {
        let path: String
        init(_ url: URL) { self.path = url.path; super.init() }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            guard path == self.path else { return try super.attributesOfItem(atPath: path) }
            return [.size: NSNumber(value: 0)]
        }
    }

    /// The name goes in the file, not only in the directory.
    /// `clearAndSaveBothCarryTheManagerIntoTheRead` asserts on a log line, and every line
    /// `StorageLensStore` writes names the file by `lastPathComponent` alone, so a fixed
    /// `storage-lens.json` would give every test in the package the same fragment and
    /// `entries.last` could return a sibling's line: a false pass.
    private func storeURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "StorageSeam-\(name)")
        return dir.appendingPathComponent("storage-lens-\(name)-\(UUID().uuidString).json")
    }

    /// The most recent line `log` captured containing `fragment`. A capture, not the shared buffer,
    /// so the rest of the package logging past the line cannot take it away.
    @MainActor
    private func loggedLine(_ log: LogCapture, containing fragment: String) async -> String? {
        await log.entries.last { $0.message.contains(fragment) }?.message
    }

    /// With nothing on disk, the real manager answers `absent` and one that says the entry is there
    /// answers `unreadable`. Only a `read` that uses the injected manager can tell them apart.
    @Test func readHonoursTheInjectedManagersPresenceProbe() throws {
        let url = try storeURL("read")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        guard case .absent = StorageLensStore.read(from: url) else {
            Issue.record("fixture: nothing is on disk, so the real manager must answer absent")
            return
        }
        guard case .unreadable = StorageLensStore.read(from: url, fileManager: ClaimsPresent(url)) else {
            Issue.record("""
                read reached past the injected manager to FileManager.default — a test passing a \
                double gets the real filesystem for the half that decides whether anything is at \
                risk
                """)
            return
        }
    }

    /// And through the two background entry points, which is where a caller's double has to arrive.
    @Test @MainActor func clearAndSaveBothCarryTheManagerIntoTheRead() async throws {
        let log = LogCapture()
        let url = try storeURL("wired")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Nothing on disk, but the injected manager insists there is: both writers must take the
        // unreadable path rather than treat it as a first scan. The forget is asserted on its log
        // line, not the file: with the real manager the read answers `.absent` and the forget
        // returns silently, leaving the file empty either way.
        StorageLensStore.clearInBackground(root: "/a", from: url, fileManager: ClaimsPresent(url))
        StorageLensStore.waitForPendingWrites()
        #expect(await loggedLine(log, containing: url.lastPathComponent) != nil,
                """
                “Forget this root” said nothing, so it took the absent path — the injected \
                manager did not reach the read
                """)

        let snapshot = StorageLensSnapshot(
            root: "/b",
            report: StorageLensReport(treemap: [], largest: [], stale: [], reclaimCandidates: [],
                                      totalBytes: 0, fileCount: 0, staleCount: 0,
                                      reclaimCount: 0, reclaimableBytes: 0),
            completedAt: Date(timeIntervalSince1970: 1_800_000_000))
        StorageLensStore.saveInBackground(snapshot, to: url, fileManager: ClaimsPresent(url))
        StorageLensStore.waitForPendingWrites()
        #expect(StorageLensStore.load(from: url).isEmpty,
                """
                the save merged into an empty list and wrote it — the set-aside could not move a \
                file that is not there, so the write had to be refused
                """)
    }
}
