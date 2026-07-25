import Testing
import Foundation
@testable import Sync

/// Pins the second half of the bulk-vs-single exclusion, which was written in one direction only.
///
/// `syncAll` refuses to start while `syncingDifferenceIds` is non-empty — its own comment calls
/// that guard a mirror of Verify All's. The mirror image was missing: `syncFile` read
/// `syncingDifferenceIds` and `isVerifyAllRunning` but never `isBulkSyncRunning`, so a single-row
/// sync queued behind a Sync All could start inside the window between syncAll's latch and its
/// `markSyncing` — the two are separated by the confirmation prompt, whose modal spins the run
/// loop by design. Both flows would then handle the same difference, and because
/// `syncingDifferenceIds` is a set rather than a refcount, whichever `defer` ran first would
/// release an id the other still owned.
@Suite struct BulkSyncSingleRowExclusionTests {

    @MainActor
    private func makeFixture() throws -> (FileSyncManager, MockFileManager, FileDifference) {
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
        return (manager, mockFM, diff)
    }

    @MainActor
    @Test func singleRowSyncRefusedWhileABulkRunIsInFlight() async throws {
        let (manager, mockFM, diff) = try makeFixture()

        manager.isBulkSyncRunning = true
        let ran = await manager.syncFile(diff, fileManager: mockFM)

        #expect(ran == false)
        #expect(manager.banner?.message == "Wait for the current operation to finish before syncing")
        #expect(manager.banner?.severity == .warning)
        // Nothing was written: the refusal must land before any I/O.
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
        // The refusal happens before `markSyncing`, so it must not leak an in-flight id — a leak
        // would refuse Verify All and pane swaps for the rest of the session.
        #expect(manager.syncingDifferenceIds.isEmpty)
        // And it must not clear the flag belonging to the run that is still going.
        #expect(manager.isBulkSyncRunning)
    }

    @MainActor
    @Test func theSameRowSyncsOnceTheBulkRunHasFinished() async throws {
        let (manager, mockFM, diff) = try makeFixture()

        manager.isBulkSyncRunning = true
        _ = await manager.syncFile(diff, fileManager: mockFM)
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)

        // The guard is a wait, not a permanent refusal: the identical call goes through the
        // moment the bulk run releases its latch.
        manager.isBulkSyncRunning = false
        manager.banner = nil
        let ranAfter = await manager.syncFile(diff, fileManager: mockFM)
        #expect(ranAfter)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
    }

    /// The direction that already worked, kept alongside its twin so a future edit that
    /// "simplifies" one of them has to confront both.
    @MainActor
    @Test func bulkRunStillRefusedWhileASingleRowIsInFlight() async throws {
        let (manager, mockFM, diff) = try makeFixture()
        manager.differences = [diff]

        manager.markSyncing(ids: [diff.id])
        await manager.syncAll(direction: .copyToRight, confirmed: true)

        #expect(manager.banner?.message == "Wait for the current operation to finish before syncing")
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }
}
