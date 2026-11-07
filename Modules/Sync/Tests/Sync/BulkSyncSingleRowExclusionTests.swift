import Testing
import Foundation
@testable import Sync

/// Bulk and single-row syncs exclude each other in both directions. `syncFile` must check
/// `isBulkSyncRunning`: a single-row sync can otherwise start between `syncAll`'s latch and its
/// `markSyncing`, which the confirmation prompt's modal run loop separates. Both flows would then
/// handle the same difference, and since `syncingDifferenceIds` is a set, not a refcount, the first
/// `defer` to run releases an id the other still owns.
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
        // The refusal comes before `markSyncing`, so it leaks no in-flight id; a leak would refuse
        // Verify All and pane swaps for the rest of the session.
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

        // A wait, not a permanent refusal: the same call goes through once the bulk run releases
        // its latch.
        manager.isBulkSyncRunning = false
        manager.banner = nil
        let ranAfter = await manager.syncFile(diff, fileManager: mockFM)
        #expect(ranAfter)
        #expect(mockFM.virtualDisk["/dst/f.txt"] != nil)
    }

    /// The other direction: a bulk run refuses while a single row is in flight (possibly parked at
    /// its prompt), both confirmed (Copy Remaining, the review) and unconfirmed, before it asks.
    /// Kept beside its twin so an edit to one has to face both.
    @MainActor
    @Test func bulkRunStillRefusedWhileASingleRowIsInFlight() async throws {
        let (manager, mockFM, diff) = try makeFixture()
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }

        manager.markSyncing(ids: [diff.id])
        await manager.syncAll(direction: .copyToRight, confirmed: true)

        #expect(manager.banner?.message == "Wait for the current operation to finish before syncing")
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)

        manager.banner = nil
        await manager.syncAll(direction: .copyToRight)

        #expect(prompts == 0)
        #expect(manager.banner?.message == "Wait for the current operation to finish before syncing")
        #expect(mockFM.virtualDisk["/dst/f.txt"] == nil)
    }
}
