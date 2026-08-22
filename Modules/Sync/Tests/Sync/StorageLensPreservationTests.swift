import Events
import Foundation
import Testing
@testable import Sync

/// **Both writers are read-modify-writes over a read that answered `[]` for everything.**
///
/// `load` returned an empty list for a file that is absent, one it could not decode, and one
/// written under another schema alike — and the doc said that costs a re-scan. It cost more than
/// that: the next analysis wrote a file holding ONE snapshot with the other eleven roots gone, and
/// "Forget this root" filtered `[]` to `[]`, which trips the guard that deletes the file. Forget
/// one silently meant forget all, with the request itself as the trigger.
///
/// `FilingProfileStore.indexForAmending` is the sibling that gets this right: it refuses to amend
/// what it could not read.
@Suite struct StorageLensPreservationTests {

    private func storeURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "StoragePreserve-\(name)")
        return dir.appendingPathComponent("storage-lens.json")
    }

    private func report(_ bytes: Int = 1234) -> StorageLensReport {
        StorageLensReport(treemap: [TreemapNode(name: "D", path: "/r/D", bytes: bytes)],
                          largest: [], stale: [], reclaimCandidates: [], totalBytes: bytes)
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

    /// **The sharper half: a file from a NEWER build is good data, not corruption.** A schema this
    /// build does not know used to read as empty and be overwritten.
    @Test func aForeignSchemaIsKeptRatherThanOverwritten() throws {
        let url = try storeURL("schema")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let future = Data("{\"schema\":99,\"snapshots\":[]}".utf8)
        try future.write(to: url)

        StorageLensStore.saveInBackground(snapshot("/b"), to: url)
        StorageLensStore.waitForPendingWrites()

        let kept = try #require(setAsidesBeside(url).first, "no set-aside was written")
        #expect(FileManager.default.contents(atPath: kept.path) == future,
                "a newer build's file was overwritten")
    }

    /// **The read layer has the same two states as the parse layer, and it lost them** — in the
    /// same file that fixed the parse layer. A file that EXISTS but cannot be opened — mode 000,
    /// an ACL, an I/O error — failed the `try?` read exactly like no file at all and answered
    /// `.absent`, so `saveInBackground` merged into `[]` and overwrote one snapshot over up to
    /// twelve roots.
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

    /// A genuinely absent file still reads `.absent` — a first scan stays quiet and ordinary.
    @Test func aGenuinelyAbsentFileStillReadsAsAbsent() throws {
        let url = try storeURL("absent")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard case .absent = StorageLensStore.read(from: url) else {
            Issue.record("an absent file did not read as .absent")
            return
        }
    }

    /// The end-to-end consequence: a new analysis must not replace a file the process cannot
    /// open — the same promise `anUnreadableFileIsKeptRatherThanReplaced` makes for corrupt bytes.
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
        // A perfectly good file holding another root's snapshot — only the read fails.
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

    /// **"Forget this root" may not empty a file it could not read.**
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

    /// The ordinary paths are untouched — the refusals must not be "the store stopped working".
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

    /// Forget-all still deletes the file — that is what the user asked for either way.
    @Test func forgettingEverythingStillRemovesTheFile() throws {
        let url = try storeURL("clearall")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        StorageLensStore.saveInBackground(snapshot("/a"), to: url)
        StorageLensStore.waitForPendingWrites()
        StorageLensStore.clearInBackground(root: nil, from: url)
        StorageLensStore.waitForPendingWrites()
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    /// And forgetting the last remaining root removes it too — an empty store has no file, which is
    /// the existing rule and not what this change is about.
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

    /// **A second unreadable episode must not destroy the first episode's rescue.** Lower stakes
    /// than the verdict cache — a snapshot is re-scannable — but the single fixed slot plus its
    /// unconditional `removeItem` is the same shape, and it is the one the other two stores were
    /// fixed out of. There is now one destination helper for all three.
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

    /// A leftover under the old fixed `storage-lens.json.unreadable` name a previous build wrote
    /// must neither block this episode's rescue nor be destroyed by it.
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

    /// **The refusal line claimed a rescue that did not happen.** `clearInBackground` discarded
    /// `setAsideUnreadable`'s result and logged "It has been kept beside the fresh one" whatever
    /// happened — so a failed move read as a successful rescue, and a user going looking for the
    /// kept file found nothing. (It also promised a "fresh one": forget writes no file at all.)
    @MainActor
    @Test func aFailedSetAsideIsNotLoggedAsARescue() async throws {
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

        await Logger.shared.debug("storage-lens clear flush marker").value
        let line = try #require(Logger.shared.entries.last {
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

    /// The other outcome, said as precisely: the move landed, so the line may name the kept file —
    /// and must not promise a fresh one, because forgetting writes none.
    @MainActor
    @Test func aSuccessfulSetAsideNamesTheKeptFileAndPromisesNoFreshOne() async throws {
        let url = try makeCanonicalTempRoot(prefix: "StoragePreserve-clearkept")
            .appendingPathComponent("storage-lens-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let corrupt = Data("{\"schema\":1,\"snapshots\":[{\"root\"".utf8)
        try corrupt.write(to: url)

        StorageLensStore.clearInBackground(root: "/a", from: url)
        StorageLensStore.waitForPendingWrites()

        await Logger.shared.debug("storage-lens clear flush marker").value
        let line = try #require(Logger.shared.entries.last {
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

/// **A half-wired seam proves less than it reads as proving.**
///
/// `StorageLensStore.clearInBackground(root:from:fileManager:)` forwarded its injected manager to
/// `setAsideUnreadable` but called `read(from:)`, which took no manager and hardcoded
/// `FileManager.default`; `saveInBackground` called the set-aside with no manager at all. A test
/// handing in a double therefore got the double for the rename and the real filesystem for the
/// decision about whether a rename was needed at all — the half that decides everything.
///
/// The seam covers the *probe* and the *moves*. `Data(contentsOf:)` takes no `FileManager` and is
/// deliberately not faked: what the doubles here exist for is the present-vs-absent decision, and
/// pinning that is what these assert.
@Suite struct StorageLensSeamTests {

    /// Claims ONE path is present, whatever the disk says — the seam's decision half in isolation.
    ///
    /// **Scoped to that path deliberately.** A first version answered "present" for everything and
    /// hung the test host at 100% CPU: `UnreadableSetAside.destination` probes candidate names with
    /// this same call until one comes back absent, so a manager that never says absent is an
    /// infinite loop. Real filesystems terminate it; a double is under no such obligation, and the
    /// loop is now bounded (see `UnreadableSetAside`).
    private final class ClaimsPresent: FileManager, @unchecked Sendable {
        let path: String
        init(_ url: URL) { self.path = url.path; super.init() }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            guard path == self.path else { return try super.attributesOfItem(atPath: path) }
            return [.size: NSNumber(value: 0)]
        }
    }

    private func storeURL(_ name: String) throws -> URL {
        let dir = try makeCanonicalTempRoot(prefix: "StorageSeam-\(name)")
        return dir.appendingPathComponent("storage-lens.json")
    }

    @MainActor
    private func loggedLine(containing fragment: String) async -> String? {
        await Logger.shared.debug("storage-seam flush marker").value
        return Logger.shared.entries.last { $0.message.contains(fragment) }?.message
    }

    /// With nothing on disk, the answer is `absent` from the real manager and `unreadable` from a
    /// manager that says the entry is there. Only a `read` that actually uses the injected one can
    /// tell them apart — so this fails on any wiring that reaches past it.
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

    /// And the wiring through the two background entry points, which is where a caller's double
    /// actually has to arrive.
    @Test @MainActor func clearAndSaveBothCarryTheManagerIntoTheRead() async throws {
        let url = try storeURL("wired")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Nothing on disk, but the injected manager insists there is: both writers must take the
        // unreadable path rather than treating it as a first scan.
        //
        // The forget is asserted on its LOG line, not on the file: with the manager reaching past
        // to `FileManager.default` the read answers `.absent`, the forget returns silently, and
        // the file is empty either way — an assertion on emptiness would pass on both wirings.
        StorageLensStore.clearInBackground(root: "/a", from: url, fileManager: ClaimsPresent(url))
        StorageLensStore.waitForPendingWrites()
        #expect(await loggedLine(containing: url.lastPathComponent) != nil,
                """
                “Forget this root” said nothing, so it took the absent path — the injected \
                manager did not reach the read
                """)

        let snapshot = StorageLensSnapshot(
            root: "/b",
            report: StorageLensReport(treemap: [], largest: [], stale: [], reclaimCandidates: [],
                                      totalBytes: 0),
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
