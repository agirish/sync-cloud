import Testing
import Foundation
@testable import Sync

/// Every attempt to catch a filter pass mid-compute lost the race. Thrown rather than swallowed:
/// the alternative is a test that quietly stops testing the reconcile pass.
private struct FilterPassWindowMissed: Error, CustomStringConvertible {
    var description: String {
        "200 filter passes all published before the test regained the main actor"
    }
}

/// Holds the serial file-operation queue closed until `open()` so a bulk sync can be caught
/// (and inspected) mid-flight deterministically, without wall-clock sleeps.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Pins the two in-flight-state invariants:
/// 1. `isSyncing` is owned by `syncingDifferenceIds` and survives `applyFilters()` rebuilding
///    `differences` from `rawDifferences` mid-operation (the header sync actions must stay
///    disabled while files are being written).
/// 2. `verifyAllWithChecksum` and bulk syncs are mutually exclusive: hashing a file that is
///    mid-overwrite could record a bogus "identical" and offer a wrong bulk copy.
@Suite struct InFlightSyncStateTests {

    /// One difference whose destination collides (resolved as Skip, so the row survives the
    /// run) and one clean copy (so the run has real work to park behind the gated queue).
    @MainActor
    private func makeBulkFixture() throws -> (FileSyncManager, MockFileManager, skip: FileDifference, copy: FileDifference) {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        manager.bulkCollisionResolver = { _ in (.skip, false) }

        func diff(_ name: String, type: FileDifference.DifferenceType) -> FileDifference {
            FileDifference(
                relativePath: name,
                leftItemPath: "/src/\(name)",
                rightItemPath: "/dst/\(name)",
                type: type,
                action: .copyToRight,
                description: "test"
            )
        }
        let skip = diff("a.txt", type: .differentDates)
        let copy = diff("b.txt", type: .missingOnRight)
        manager.rawDifferences = [skip, copy]
        manager.differences = [skip, copy]
        return (manager, mockFM, skip, copy)
    }

    /// Blocks the manager's serial operation queue behind `gate`, then starts `syncAll` and
    /// waits (cooperatively) until it has marked its rows in-flight. The returned task cannot
    /// finish until the gate opens.
    @MainActor
    private func startGatedSyncAll(_ manager: FileSyncManager, gate: Gate) async -> Task<Void, Never> {
        Task { await manager.enqueueFileOperation { await gate.wait() } }
        await waitUntil("the gated operation occupies the queue") { manager.activeFileOperationsCount > 0 }

        let syncTask = Task { await manager.syncAll(direction: .copyToRight) }
        await waitUntil("syncAll marks its rows in-flight") { !manager.syncingDifferenceIds.isEmpty }
        return syncTask
    }

    /// Starts a filter pass and returns with the main actor still held while that pass is
    /// provably suspended inside its detached compute — the window the reconcile tests below
    /// claim to act in.
    ///
    /// **`await Task.yield()` on its own does not put a test there.** The compute is detached at
    /// `.userInitiated` and its continuation competes for the main actor with the yield's own, so
    /// under a loaded suite the whole pass can finish before the test's next line runs. The row
    /// assertions still hold when it does — a pass that publishes BEFORE the mutation reaches the
    /// same rows by another route — so nothing goes red; only `reconcilePassesRun` can tell the
    /// two apart. It read 0 in a full-package run while all three tests passed in isolation.
    /// That is a vacuous green, not a flake, and it was invisible until the counter existed.
    ///
    /// So the window is verified rather than assumed. `lastPublishedFilterGeneration` moves the
    /// instant a pass commits, so if it has not moved the pass is still suspended — and a
    /// suspended pass needs the main actor to continue, which the caller holds until it next
    /// suspends. Whatever the caller does before its next `await` therefore lands inside the
    /// window. A missed window is drained and retried; the retries are ordinary fast-path passes
    /// over unchanged state, so they publish nothing and leave `reconcilePassesRun` alone.
    @MainActor
    private func filterPassParkedInsideItsCompute(_ manager: FileSyncManager) async throws -> Task<Void, Never> {
        for _ in 0..<200 {
            let startedBefore = manager.filterGeneration
            let publishedBefore = manager.lastPublishedFilterGeneration
            let pass = Task { await manager.applyFilters() }
            await Task.yield()
            // BOTH halves, because "parked inside the compute" is two facts and the yield
            // guarantees neither. `filterGeneration` moving says the pass ran its prologue and
            // took its snapshots; `lastPublishedFilterGeneration` standing still says it has not
            // committed. Checking only the second reports a pass that has not STARTED as parked —
            // the caller then mutates BEFORE the snapshot, the pass sees the mutation as its own
            // input, takes the fast path, and `reconcilePassesRun` reads 0 for a reason that has
            // nothing to do with the gate under test.
            if manager.filterGeneration != startedBefore
                && manager.lastPublishedFilterGeneration == publishedBefore { return pass }
            await pass.value
        }
        throw FilterPassWindowMissed()
    }

    /// Pin (bug A): a filter pass mid-bulk-sync must republish rows with `isSyncing` intact —
    /// `rawDifferences` never carries the flag, so it has to be re-stamped from
    /// `syncingDifferenceIds` — and the run's exit must clear both the set and the rows.
    @MainActor
    @Test func testIsSyncingSurvivesFilterPassMidBulkSync() async throws {
        let (manager, mockFM, skipDiff, copyDiff) = try makeBulkFixture()
        let gate = Gate()
        let syncTask = await startGatedSyncAll(manager, gate: gate)

        // Both rows are marked while the run is parked behind the gated queue.
        #expect(manager.syncingDifferenceIds == [skipDiff.id, copyDiff.id])

        // A full filter pass mid-operation (what a hidden-files toggle, ignore change,
        // re-sort, or completing scan triggers) rebuilds `differences` from raw.
        await manager.applyFilters()

        #expect(manager.differences.count == 2)
        #expect(manager.differences.allSatisfy { $0.isSyncing })

        await gate.open()
        await syncTask.value

        // b.txt copied (row resolved away); a.txt was skipped so it survives, un-marked.
        #expect(mockFM.virtualDisk["/dst/b.txt"] != nil)
        #expect(manager.differences.map(\.relativePath) == ["a.txt"])
        #expect(manager.differences.first?.isSyncing == false)
        #expect(manager.syncingDifferenceIds.isEmpty)

        // And a post-completion filter pass stays un-marked.
        await manager.applyFilters()
        #expect(manager.differences.first?.isSyncing == false)
    }

    /// Pin: the mark/clear helpers keep the published rows and the id set in lockstep across
    /// filter passes — the single-file (`syncFile`) paths use exactly these helpers.
    @MainActor
    @Test func testMarkAndClearSyncingSurviveFilterPasses() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = FileDifference(
            relativePath: "x.txt",
            leftItemPath: "/l/x.txt",
            rightItemPath: "/r/x.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test"
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        manager.markSyncing(ids: [diff.id])
        await manager.applyFilters()
        #expect(manager.differences.first?.isSyncing == true)
        #expect(manager.syncingDifferenceIds == [diff.id])

        manager.clearSyncing(ids: [diff.id])
        await manager.applyFilters()
        #expect(manager.differences.first?.isSyncing == false)
        #expect(manager.syncingDifferenceIds.isEmpty)

        // Resolving a marked row must not leak its id into the set (the pane swap and
        // Verify All would stay refused forever).
        manager.markSyncing(ids: [diff.id])
        manager.removeResolvedDifferences(ids: [diff.id])
        #expect(manager.syncingDifferenceIds.isEmpty)
    }

    /// Pin: a filter pass publishes against the LIVE state, not its entry snapshot — a row
    /// resolved (`removeResolvedDifferences`) while the pass's detached compute ran must not
    /// resurrect, and a row marked in-flight in that window keeps its spinner. The pass
    /// snapshots synchronously on entry, then suspends for the compute; one yield parks the
    /// test exactly inside that window.
    @MainActor
    @Test func testFilterPassPublishReconcilesRowsChangedDuringCompute() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        func diff(_ name: String) -> FileDifference {
            FileDifference(
                relativePath: name,
                leftItemPath: "/l/\(name)",
                rightItemPath: "/r/\(name)",
                type: .missingOnRight,
                action: .copyToRight,
                description: "test"
            )
        }
        let resolved = diff("resolved.txt")
        let marked = diff("marked.txt")
        manager.rawDifferences = [resolved, marked]
        manager.differences = [resolved, marked]

        let pass = try await filterPassParkedInsideItsCompute(manager)

        manager.removeResolvedDifferences(ids: [resolved.id])
        manager.markSyncing(ids: [marked.id])

        await pass.value

        #expect(manager.differences.map(\.id) == [marked.id])   // resolved row must not resurrect
        #expect(manager.differences.first?.isSyncing == true)   // mid-compute mark survives publish
        #expect(manager.syncingDifferenceIds == [marked.id])
        // And it reached the reconcile pass to do it. Without this the test passes just as well
        // against a gate that skips the pass and gets the right answer by luck of the snapshot.
        #expect(manager.reconcilePassesRun == 1)
        manager.clearSyncing(ids: [marked.id])
    }

    /// The same gate from the other side: with nothing moving mid-compute, the reconcile pass is
    /// SKIPPED, not merely made cheaper.
    ///
    /// Its two halves are provable no-ops when neither input moved — every row was filtered from
    /// the same `rawDifferences`, and `computeFilteredState` already stamped `isSyncing` from the
    /// same set — so skipping is what removes the ~5 ms of main-actor work, not a faster rebuild.
    /// The two tests around this one cover the fallback; none of them can see a gate whose fast
    /// path never fires, which would leave the cost exactly where it was with every test green.
    @MainActor
    @Test func theReconcilePassIsSkippedWhenNothingMovedMidCompute() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let rows = (0..<3).map { i in
            FileDifference(relativePath: "x\(i).txt",
                           leftItemPath: "/l/x\(i).txt",
                           rightItemPath: "/r/x\(i).txt",
                           type: .missingOnRight,
                           action: .copyToRight,
                           description: "test")
        }
        manager.rawDifferences = rows
        manager.differences = rows

        await manager.applyFilters()

        #expect(manager.reconcilePassesRun == 0, "the gate never took its fast path")
        #expect(manager.differences.map(\.id) == rows.map(\.id), "and it published the right rows")
        #expect(manager.differences.allSatisfy { !$0.isSyncing })

        // A second pass over unchanged inputs must also skip, and must not republish: an
        // identical array assigned again tears down and rebuilds the pane List for nothing.
        let versionBefore = manager.publishedDifferencesVersion
        await manager.applyFilters()
        #expect(manager.reconcilePassesRun == 0)
        #expect(manager.publishedDifferencesVersion == versionBefore,
                "an unchanged list was republished — the off-main compare is not being trusted")
    }

    /// Pin (other direction): a clear that lands during the compute wins over the snapshot's
    /// stale mark — the published row must not get its spinner back at publish time.
    @MainActor
    @Test func testFilterPassPublishDoesNotResurrectClearedSyncingFlag() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let diff = FileDifference(
            relativePath: "x.txt",
            leftItemPath: "/l/x.txt",
            rightItemPath: "/r/x.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test"
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        manager.markSyncing(ids: [diff.id])

        let pass = try await filterPassParkedInsideItsCompute(manager)

        manager.clearSyncing(ids: [diff.id])

        await pass.value

        #expect(manager.differences.first?.isSyncing == false)
        #expect(manager.syncingDifferenceIds.isEmpty)
        #expect(manager.reconcilePassesRun == 1)   // by the reconcile pass, not by the snapshot
    }

    /// Pin: `computeFilteredState`'s postcondition holds for the EMPTY set too — a row arriving
    /// with `isSyncing` set and no operation behind it is published cleared.
    ///
    /// Unreachable from the app as it stands, because nothing writes the flag into
    /// `rawDifferences`. It is pinned because `applyFilters()` now SKIPS the reconcile pass that
    /// used to re-stamp every row unconditionally, and the skip is sound only while the flag a
    /// row already carries is the flag the set says it should have. Left as an unwritten
    /// invariant about a different property, the first write of `isSyncing` into `rawDifferences`
    /// puts a spinner on a row with no operation behind it, with every test still green.
    @MainActor
    @Test func aRowCarryingAStaleInFlightFlagIsPublishedCleared() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let stale = FileDifference(
            relativePath: "x.txt",
            leftItemPath: "/l/x.txt",
            rightItemPath: "/r/x.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test",
            isSyncing: true
        )
        manager.rawDifferences = [stale]
        manager.differences = [stale]
        #expect(manager.syncingDifferenceIds.isEmpty)

        await manager.applyFilters()

        #expect(manager.reconcilePassesRun == 0, "the fast path is the one under test")
        #expect(manager.differences.first?.isSyncing == false)
    }

    /// Pin: a published list replaced from outside the pass is compared LIVE, not against the
    /// entry snapshot the off-main compare answered about.
    ///
    /// The reconcile pass's two inputs both hold here, so the skip stays taken and this is the
    /// only clause standing between the two. Without it the pass asks "did the rows change since
    /// entry?", is told no, publishes nothing — and the row stays missing from the list while
    /// `rawDifferences` still holds it, until something else happens to write `differences`.
    @MainActor
    @Test func aPublishedListReplacedMidComputeIsComparedLive() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let row = FileDifference(
            relativePath: "x.txt",
            leftItemPath: "/l/x.txt",
            rightItemPath: "/r/x.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test"
        )
        manager.rawDifferences = [row]
        manager.differences = [row]

        let pass = try await filterPassParkedInsideItsCompute(manager)

        manager.differences = []   // only the published list moves; raw and the syncing set hold

        await pass.value

        #expect(manager.reconcilePassesRun == 0, "neither reconcile input moved")
        #expect(manager.differences.map(\.id) == [row.id],
                "the row is back — the entry snapshot's answer was not reused")
    }

    /// Pin (bug B): Verify All refuses to start while a bulk sync is in flight — including
    /// while the run is still queued behind other operations — with a visible warning banner,
    /// and never publishes verify progress or a copy offer.
    @MainActor
    @Test func testVerifyAllRefusedWhileBulkSyncInFlight() async throws {
        let (manager, _, _, _) = try makeBulkFixture()
        let gate = Gate()
        let syncTask = await startGatedSyncAll(manager, gate: gate)

        await manager.verifyAllWithChecksum()

        // (Field comparison — banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "Wait for the current operation to finish before verifying")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.verifyAllProgress == nil)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(!manager.isVerifyAllRunning)

        await gate.open()
        await syncTask.value
    }

    /// Pin (bug B): Verify All also refuses while any queued file operation or a single-file
    /// sync (e.g. parked at its collision prompt) is in flight, and while another Verify All
    /// is already running.
    @MainActor
    @Test func testVerifyAllRefusedWhileFileOperationOrSyncFileInFlight() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let refusalMessage = "Wait for the current operation to finish before verifying"
        // (Field comparison — banner equality includes a per-publish id.)
        func refused() -> Bool {
            manager.banner?.message == refusalMessage && manager.banner?.severity == .warning
        }

        manager.activeFileOperationsCount = 1
        await manager.verifyAllWithChecksum()
        #expect(refused())
        manager.activeFileOperationsCount = 0
        manager.banner = nil

        manager.markSyncing(ids: [UUID()])
        // markSyncing on an id with no row still records intent; verify must refuse.
        await manager.verifyAllWithChecksum()
        #expect(refused())
        manager.clearSyncing(ids: manager.syncingDifferenceIds)
        manager.banner = nil

        manager.isVerifyAllRunning = true
        await manager.verifyAllWithChecksum()
        #expect(refused())
        // The refusal path must not reset the running flag it refused on.
        #expect(manager.isVerifyAllRunning)
        manager.isVerifyAllRunning = false
    }

    /// Pin (bug B, other direction): a bulk sync refuses to start while Verify All is running,
    /// with a visible warning banner and no files touched — and proceeds once it's done.
    @MainActor
    @Test func testSyncAllRefusedWhileVerifyAllInFlight() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/f.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let diff = FileDifference(
            relativePath: "f.txt",
            leftItemPath: "/src/f.txt",
            rightItemPath: "/dst/f.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test"
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        manager.isVerifyAllRunning = true
        await manager.syncAll(direction: .copyToRight)

        // (Field comparison — banner equality includes a per-publish id.)
        #expect(manager.banner?.message == "Wait for the current operation to finish before syncing")
        #expect(manager.banner?.severity == .warning)
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
        #expect(manager.differences.count == 1)
        #expect(manager.syncingDifferenceIds.isEmpty)

        // With the verify run finished, the identical call goes through.
        manager.isVerifyAllRunning = false
        await manager.syncAll(direction: .copyToRight)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
        #expect(manager.differences.isEmpty)
    }
}

/// `markSyncing`/`clearSyncing` stamp the published rows in one write.
///
/// `differences` is `@Published`, which offers a getter and a setter and no `_modify`, so
/// `differences[i].isSyncing = x` copies the whole array and publishes — once per row. Marking m of
/// n rows was O(n·m) main-actor copying and m `objectWillChange` sends: measured at **11,144 ms**
/// for a 29,000-row "Sync All" and 11,107 ms again to clear it, against 7.9 ms and 7.1 ms now.
///
/// The publish COUNT is the assertion rather than a duration, because the count is what the bug
/// actually was and it is deterministic — a timing threshold here would be a flake on a loaded
/// runner ([[docs/flaky-tests.md]] passim). `publishedDifferencesVersion` bumps on every write to
/// `differences`, so "one write" is directly observable.
@Suite struct SyncingFlagStampingTests {

    private func rows(_ n: Int) -> [FileDifference] {
        (0..<n).map { i in
            FileDifference(relativePath: "p\(i).txt",
                           leftItemPath: "/l/p\(i).txt",
                           rightItemPath: "/r/p\(i).txt",
                           type: .missingOnRight,
                           action: .copyToRight,
                           description: "test")
        }
    }

    @MainActor
    @Test func markingEveryRowPublishesExactlyOnce() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let all = rows(500)
        manager.differences = all
        let ids = Set(all.map(\.id))

        let before = manager.publishedDifferencesVersion
        manager.markSyncing(ids: ids)

        #expect(manager.publishedDifferencesVersion - before == 1,
                "stamped row by row — that is O(n·m) copying and one publish each")
        #expect(manager.differences.allSatisfy { $0.isSyncing }, "and every row really is marked")
        #expect(manager.syncingDifferenceIds == ids)
    }

    @MainActor
    @Test func clearingEveryRowPublishesExactlyOnce() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let all = rows(500)
        manager.differences = all
        let ids = Set(all.map(\.id))
        manager.markSyncing(ids: ids)

        let before = manager.publishedDifferencesVersion
        manager.clearSyncing(ids: ids)

        #expect(manager.publishedDifferencesVersion - before == 1)
        #expect(manager.differences.allSatisfy { !$0.isSyncing })
        #expect(manager.syncingDifferenceIds.isEmpty)
    }

    /// A stamp that changes no row must not republish at all: an identical list assigned again
    /// tears down and rebuilds the pane `List`, which is what eats a click mid-drag.
    @MainActor
    @Test func aStampThatChangesNothingDoesNotRepublish() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let all = rows(50)
        manager.differences = all
        let ids = Set(all.map(\.id))
        manager.markSyncing(ids: ids)

        let before = manager.publishedDifferencesVersion
        manager.markSyncing(ids: ids)          // already marked
        #expect(manager.publishedDifferencesVersion == before)

        // An id that matches no published row is the other no-op — `clearSyncing` documents it.
        manager.clearSyncing(ids: [UUID()])
        #expect(manager.publishedDifferencesVersion == before)
        #expect(manager.differences.allSatisfy { $0.isSyncing }, "and nothing else was disturbed")
    }

    /// Marking a subset leaves the rest alone — the loop's `where` clause, pinned so a future
    /// "simplify" cannot stamp the whole list.
    @MainActor
    @Test func markingASubsetLeavesTheOtherRowsUntouched() {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let all = rows(10)
        manager.differences = all
        let marked = Set(all.prefix(3).map(\.id))

        manager.markSyncing(ids: marked)

        for row in manager.differences {
            #expect(row.isSyncing == marked.contains(row.id), "row \(row.relativePath)")
        }
    }
}
