import Testing
import Foundation
@testable import Sync

/// Every attempt to catch a filter pass mid-compute lost the race. Thrown rather than swallowed,
/// or the test would quietly stop testing the reconcile pass.
private struct FilterPassWindowMissed: Error, CustomStringConvertible {
    var description: String {
        "200 filter passes all published before the test regained the main actor"
    }
}

/// Holds the serial file-operation queue closed until `open()`, so a bulk sync can be caught and
/// inspected mid-flight deterministically, without wall-clock sleeps.
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
///    `differences` from `rawDifferences` mid-operation, so the header sync actions stay disabled
///    while files are being written.
/// 2. `verifyAllWithChecksum` and bulk syncs are mutually exclusive: hashing a file mid-overwrite
///    could record a bogus "identical" and offer a wrong bulk copy.
@Suite struct InFlightSyncStateTests {

    /// One difference whose destination collides (resolved as Skip, so the row survives the run)
    /// and one clean copy (so the run has real work to park behind the gated queue).
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

    /// Blocks the manager's serial operation queue behind `gate`, starts `syncAll`, and waits until
    /// it has marked its rows in-flight. The returned task can't finish until the gate opens.
    @MainActor
    private func startGatedSyncAll(_ manager: FileSyncManager, gate: Gate) async -> Task<Void, Never> {
        Task { await manager.enqueueFileOperation { await gate.wait() } }
        await waitUntil("the gated operation occupies the queue") { manager.activeFileOperationsCount > 0 }

        let syncTask = Task { await manager.syncAll(direction: .copyToRight) }
        await waitUntil("syncAll marks its rows in-flight") { !manager.syncingDifferenceIds.isEmpty }
        return syncTask
    }

    /// Starts a filter pass and returns with the main actor still held while that pass is provably
    /// suspended inside its detached compute, the window the reconcile tests below act in.
    ///
    /// `await Task.yield()` alone doesn't put a test there: the compute is detached at
    /// `.userInitiated` and its continuation competes for the main actor, so under load the whole
    /// pass can finish first. The row assertions would still hold, by another route, and only
    /// `reconcilePassesRun` would show the green was vacuous (`docs/flaky-tests.md`, "`Task.yield()`
    /// assumed to park a test inside an async window"). So the window is verified: while
    /// `lastPublishedFilterGeneration` hasn't moved the pass is suspended, and it needs the main
    /// actor the caller holds until its next `await`. A missed window is drained and retried; the
    /// retries are fast-path passes over unchanged state and leave `reconcilePassesRun` alone.
    @MainActor
    private func filterPassParkedInsideItsCompute(_ manager: FileSyncManager) async throws -> Task<Void, Never> {
        for _ in 0..<200 {
            let startedBefore = manager.filterGeneration
            let publishedBefore = manager.lastPublishedFilterGeneration
            let pass = Task { await manager.applyFilters() }
            await Task.yield()
            // Both halves, because "parked inside the compute" is two facts and the yield
            // guarantees neither: `filterGeneration` moving says the pass took its snapshots, and
            // `lastPublishedFilterGeneration` standing still says it hasn't committed. With only the
            // second, a pass that hasn't started reads as parked; the caller then mutates before
            // the snapshot, and the pass takes the fast path for an unrelated reason.
            if manager.filterGeneration != startedBefore
                && manager.lastPublishedFilterGeneration == publishedBefore { return pass }
            await pass.value
        }
        throw FilterPassWindowMissed()
    }

    /// A filter pass mid-bulk-sync must republish rows with `isSyncing` intact (`rawDifferences`
    /// never carries the flag, so it is re-stamped from `syncingDifferenceIds`), and the run's exit
    /// must clear both the set and the rows.
    @MainActor
    @Test func testIsSyncingSurvivesFilterPassMidBulkSync() async throws {
        let (manager, mockFM, skipDiff, copyDiff) = try makeBulkFixture()
        let gate = Gate()
        let syncTask = await startGatedSyncAll(manager, gate: gate)

        // Both rows are marked while the run is parked behind the gated queue.
        #expect(manager.syncingDifferenceIds == [skipDiff.id, copyDiff.id])

        // A full filter pass mid-operation (as a hidden-files toggle, ignore change, re-sort or
        // completing scan triggers) rebuilds `differences` from raw.
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

    /// The mark/clear helpers keep the published rows and the id set in lockstep across filter
    /// passes; the single-file (`syncFile`) paths use exactly these helpers.
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

        // Resolving a marked row must not leak its id into the set, or the pane swap and Verify
        // All would stay refused forever.
        manager.markSyncing(ids: [diff.id])
        manager.removeResolvedDifferences(ids: [diff.id])
        #expect(manager.syncingDifferenceIds.isEmpty)
    }

    /// A filter pass publishes against the live state, not its entry snapshot: a row resolved
    /// (`removeResolvedDifferences`) while the pass's detached compute ran must not resurrect, and
    /// a row marked in-flight in that window keeps its spinner.
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
        // And it reached the reconcile pass to do it; otherwise a gate that skips the pass could
        // pass this by luck of the snapshot.
        #expect(manager.reconcilePassesRun == 1)
        manager.clearSyncing(ids: [marked.id])
    }

    /// The same gate from the other side: with nothing moving mid-compute, the reconcile pass is
    /// skipped, not merely made cheaper. Its two halves are provable no-ops then (every row comes
    /// from the same `rawDifferences`, and `computeFilteredState` already stamped `isSyncing`), so
    /// skipping is what saves the ~5 ms of main-actor work. The neighbouring tests cover the
    /// fallback and can't see a gate whose fast path never fires.
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

        // A second pass over unchanged inputs must also skip, and must not republish: an identical
        // array assigned again tears down and rebuilds the pane List for nothing.
        let versionBefore = manager.publishedDifferencesVersion
        await manager.applyFilters()
        #expect(manager.reconcilePassesRun == 0)
        #expect(manager.publishedDifferencesVersion == versionBefore,
                "an unchanged list was republished — the off-main compare is not being trusted")
    }

    /// The other direction: a clear that lands during the compute wins over the snapshot's stale
    /// mark, so the published row doesn't get its spinner back.
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

    /// `computeFilteredState`'s postcondition holds for the empty set too: a row arriving with
    /// `isSyncing` set and no operation behind it is published cleared. Unreachable from the app
    /// today, since nothing writes the flag into `rawDifferences`, but `applyFilters()` skips the
    /// reconcile pass on the assumption that a row's flag already matches the set. Without this,
    /// the first such write would put a spinner on a row with nothing behind it, every test green.
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

    /// A published list replaced from outside the pass is compared live, not against the entry
    /// snapshot the off-main compare answered about. Both reconcile inputs hold here, so the skip is
    /// taken and only this clause stands between the two: otherwise the pass is told "unchanged",
    /// publishes nothing, and the row stays missing while `rawDifferences` still holds it.
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

    /// Verify All refuses to start while a bulk sync is in flight, including while the run is
    /// still queued behind other operations, with a visible warning banner, and never publishes
    /// verify progress or a copy offer.
    @MainActor
    @Test func testVerifyAllRefusedWhileBulkSyncInFlight() async throws {
        let (manager, _, _, _) = try makeBulkFixture()
        let gate = Gate()
        let syncTask = await startGatedSyncAll(manager, gate: gate)

        await manager.verifyAllWithChecksum()

        // Field comparison: banner equality includes a per-publish id.
        #expect(manager.banner?.message == "Wait for the current operation to finish before verifying")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.verifyAllProgress == nil)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(!manager.isVerifyAllRunning)

        await gate.open()
        await syncTask.value
    }

    /// Verify All also refuses while any queued file operation or a single-file sync (say, parked
    /// at its collision prompt) is in flight, and while another Verify All is already running.
    @MainActor
    @Test func testVerifyAllRefusedWhileFileOperationOrSyncFileInFlight() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let refusalMessage = "Wait for the current operation to finish before verifying"
        // Field comparison: banner equality includes a per-publish id.
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

    /// The other direction: a bulk sync refuses to start while Verify All is running, with a
    /// visible warning banner and no files touched, and proceeds once it's done.
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

        // Field comparison: banner equality includes a per-publish id.
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

/// `markSyncing`/`clearSyncing` stamp the published rows in one write. `differences` is
/// `@Published`, which has no `_modify`, so `differences[i].isSyncing = x` copies the whole array
/// and publishes once per row: O(n·m) main-actor copying, about 11 s to mark a 29,000-row Sync All.
/// The publish count is asserted rather than a duration because it is deterministic, and a timing
/// threshold would flake on a loaded runner (`docs/flaky-tests.md`). `publishedDifferencesVersion`
/// bumps on every write to `differences`, so "one write" is directly observable.
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

    /// A stamp that changes no row must not republish: an identical list assigned again tears down
    /// and rebuilds the pane `List`, which eats a click mid-drag.
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

        // An id that matches no published row is the other no-op, as `clearSyncing` documents.
        manager.clearSyncing(ids: [UUID()])
        #expect(manager.publishedDifferencesVersion == before)
        #expect(manager.differences.allSatisfy { $0.isSyncing }, "and nothing else was disturbed")
    }

    /// Marking a subset leaves the rest alone: the loop's `where` clause, pinned so a later
    /// "simplify" can't stamp the whole list.
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

/// The filter gate's ratio, and the line that puts it in `~/sync-cloud.log`. `applyFilters()`
/// skips its reconcile pass whenever neither input moved mid-compute, but the tests above run on
/// three-row fixtures and can't say whether the skip fires on a real tree. A gate that never takes
/// its fast path costs as much as no gate, every test green, so the ratio is logged once per scan
/// and its numbers are pinned here. Asserted through `filterGateSummary`, not `Logger.entries`:
/// `info` returns a `Task`, so reading the entries races the handoff (`docs/flaky-tests.md`, "A log
/// assertion reading a window that has already rolled"). The scan site only adds a prefix.
@Suite struct FilterGateVisibilityTests {

    /// The denominator counts passes that reached the gate, which is why it isn't
    /// `filterGeneration`: that counts passes started, and a superseded pass returns before the
    /// gate. Counting it would make a gate that never fires read as one that fires often. Not pinned
    /// here: that a superseded pass is excluded, since which of two suspended passes resumes first
    /// is not something a test can decide.
    @MainActor
    @Test func everyPassThatEvaluatesTheGateIsCounted() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        #expect(manager.filterPassesReachingPublish == 0)

        for _ in 0..<3 { await manager.applyFilters() }

        #expect(manager.filterPassesReachingPublish == 3)
        #expect(manager.reconcilePassesRun == 0, "nothing moved, so nothing should have reconciled")
    }

    /// The wording is pinned, not just the numbers: it is a record he reads, and it is only useful
    /// if it is unambiguous about which number is which.
    @MainActor
    @Test func theSummaryNamesBothNumbersAndTheListItMeasured() async {
        let manager = FileSyncManager(fileManager: MockFileManager())
        await manager.applyFilters()

        #expect(manager.filterGateSummary(rawDifferenceCount: 29_143)
                == "0 of 1 list rebuilds needed a reconcile pass since launch (29143 raw differences)")
    }
}
