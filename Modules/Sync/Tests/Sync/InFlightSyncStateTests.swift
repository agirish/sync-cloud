import Testing
import Foundation
@testable import Sync

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
        while manager.activeFileOperationsCount == 0 { await Task.yield() }

        let syncTask = Task { await manager.syncAll(direction: .copyToRight) }
        while manager.syncingDifferenceIds.isEmpty { await Task.yield() }
        return syncTask
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

        let pass = Task { await manager.applyFilters() }
        await Task.yield()   // pass has snapshotted and suspended for its detached compute

        manager.removeResolvedDifferences(ids: [resolved.id])
        manager.markSyncing(ids: [marked.id])

        await pass.value

        #expect(manager.differences.map(\.id) == [marked.id])   // resolved row must not resurrect
        #expect(manager.differences.first?.isSyncing == true)   // mid-compute mark survives publish
        #expect(manager.syncingDifferenceIds == [marked.id])
        manager.clearSyncing(ids: [marked.id])
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

        let pass = Task { await manager.applyFilters() }
        await Task.yield()   // snapshot (with the mark) taken; compute in flight

        manager.clearSyncing(ids: [diff.id])

        await pass.value

        #expect(manager.differences.first?.isSyncing == false)
        #expect(manager.syncingDifferenceIds.isEmpty)
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
