import Testing
import Foundation
@testable import Sync

/// Pins the verified-copy bulk run (`bulkCopyDifferencesLeftToRight`) into the same mutual
/// exclusion as `syncAll` and Verify All: both bulk runs write `bulkSyncProgress` and nil it
/// in their defer, so overlapping them interleaves the shared counter and whichever finishes
/// first tears down the other's overlay — and syncAll's up-front destination stats would be
/// staled by the verified-copy overwrites.
@Suite struct BulkCopyExclusionTests {

    /// A source-only file per name plus one difference each; the verified-copy run needs no
    /// collision seams (it overwrites unconditionally).
    @MainActor
    private func makeFixture(names: [String]) throws -> (FileSyncManager, MockFileManager, [FileDifference]) {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        var diffs: [FileDifference] = []
        for name in names {
            mockFM.virtualDisk["/src/\(name)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            diffs.append(FileDifference(
                relativePath: name,
                leftItemPath: "/src/\(name)",
                rightItemPath: "/dst/\(name)",
                type: .missingOnRight,
                action: .copyToRight,
                description: "Missing"
            ))
        }
        manager.rawDifferences = diffs
        manager.differences = diffs
        return (manager, mockFM, diffs)
    }

    /// (Field comparison — banner equality includes a per-publish id.)
    @MainActor
    private func refused(_ manager: FileSyncManager) -> Bool {
        manager.banner?.message == "Wait for the current operation to finish before copying"
            && manager.banner?.severity == .warning
    }

    /// Pin: a verified copy started while another bulk run is in flight refuses with a visible
    /// banner — no files touched, no rows marked, and the running run's flag left alone.
    ///
    /// The state is built the way production reaches it. A real file operation runs first, so
    /// the offer is stamped at a MOVED epoch rather than at the initial 0 where every
    /// comparison matches vacuously. `isBulkSyncRunning` is then latched WITHOUT moving the
    /// epoch or the count, which is exactly `syncAll`'s prepare window: it latches the flag
    /// before its confirmation prompt and before a single operation is enqueued (see the
    /// comment at that assignment), so nothing has been written and `confirmVerifiedCopy`'s own
    /// two guards both legitimately pass. `bulkCopyDifferencesLeftToRight`'s exclusion is the
    /// only thing left standing here — which is the point of pinning it.
    @MainActor
    @Test func testVerifiedCopyRefusedWhileAnotherBulkRunIsInFlight() async throws {
        let (manager, mockFM, diffs) = try makeFixture(names: ["a.txt"])

        await manager.enqueueFileOperation { }
        try #require(manager.fileOperationsEpoch > 0)
        try #require(manager.activeFileOperationsCount == 0)

        manager.isBulkSyncRunning = true
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: diffs, asOf: manager.fileOperationsEpoch)
        // Both confirm-time guards pass; only bulkCopy's exclusion can refuse from here.
        try #require(manager.verifiedIdenticalForCopy?.asOf == manager.fileOperationsEpoch)
        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(refused(manager))
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.syncingDifferenceIds.isEmpty)
        #expect(manager.differences.count == 1)
        // The refusal path must not reset the running run's flag.
        #expect(manager.isBulkSyncRunning)
        manager.isBulkSyncRunning = false
    }

    /// Pin: a verified copy also refuses while Verify All is running — its overwrites would be
    /// hashed mid-write and could record bogus "identical" results.
    @MainActor
    @Test func testVerifiedCopyRefusedWhileVerifyAllInFlight() async throws {
        let (manager, mockFM, diffs) = try makeFixture(names: ["a.txt"])

        manager.isVerifyAllRunning = true
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: diffs, asOf: manager.fileOperationsEpoch)
        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(refused(manager))
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.isVerifyAllRunning)
        manager.isVerifyAllRunning = false

        // With the verify run finished, the identical offer goes through.
        manager.banner = nil
        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: diffs, asOf: manager.fileOperationsEpoch)
        await manager.confirmVerifiedCopy()?.value
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        #expect(!refused(manager))
    }

    /// Pin (against a real in-flight run): while a verified copy is mid-flight it holds
    /// `isBulkSyncRunning`, so a concurrent `syncAll` is dropped before touching any file, and
    /// the run's exit releases the flag and tears down only its own progress.
    ///
    /// The run is held by its OWN copy I/O. It used to be held by parking a foreign operation
    /// on the queue ahead of it, and that state production cannot reach: an offer is only
    /// published while `activeFileOperationsCount == 0` and the epoch is still the one its
    /// verdicts were hashed under, and `confirmVerifiedCopy` refuses if either has moved since
    /// — so "an operation occupies the queue AND a live offer confirms" is a contradiction. The
    /// old premise survived only because assigning the offer silently re-stamped it.
    ///
    /// The second-verified-copy leg is gone with it, for the same reason: `confirmVerifiedCopy`
    /// nils the offer as it claims it, and Verify All refuses to run (so cannot publish a fresh
    /// offer) while `isBulkSyncRunning`. There is no reachable second offer to confirm. The
    /// refusal banner is pinned instead by `testVerifiedCopyRefusedWhileAnotherBulkRunIsInFlight`.
    @MainActor
    @Test func testVerifiedCopyExcludesConcurrentBulkRuns() async throws {
        let (manager, mockFM, diffs) = try makeFixture(names: ["a.txt", "b.txt"])
        let verifiedDiff = diffs[0]
        let bulkDiff = diffs[1]

        // Park the FIRST copy this run makes, so the run is genuinely in flight while the
        // assertions below run — no wall-clock sleeps, and nothing queued ahead of it.
        let inCopy = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let parked = LockedBox(false)
        mockFM.beforeCopyItem = { _ in
            let isFirst = parked.withLock { seen in defer { seen = true }; return !seen }
            guard isFirst else { return }
            inCopy.signal()
            _ = release.wait(timeout: .now() + 10)
        }

        manager.verifiedIdenticalForCopy = VerifiedCopyOffer(differences: [verifiedDiff], asOf: manager.fileOperationsEpoch)
        let copyTask = manager.confirmVerifiedCopy()
        try #require(copyTask != nil, "nothing is in flight and the stamp is current: the confirm must be accepted")
        await awaitSignal(inCopy)
        #expect(manager.isBulkSyncRunning)
        #expect(manager.bulkSyncProgress != nil)

        // A bulk sync started now must be dropped, not queued behind the run.
        let syncAllTask = Task { await manager.syncAll(direction: .copyToRight, subset: [bulkDiff]) }
        for _ in 0..<100 { await Task.yield() }

        release.signal()
        await copyTask?.value
        await syncAllTask.value

        // Only the verified run's work happened; the dropped syncAll never touched b.txt.
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/b.txt"] == nil)
        #expect(manager.differences.map(\.relativePath) == ["b.txt"])
        // Exclusion fully released and progress torn down once the run exits.
        #expect(!manager.isBulkSyncRunning)
        #expect(manager.bulkSyncProgress == nil)
        #expect(manager.activeProgress == nil)
        #expect(manager.syncingDifferenceIds.isEmpty)
    }
}
