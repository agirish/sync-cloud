import Testing
import Foundation
@testable import Sync

/// Holds the serial file-operation queue closed until `open()` so a bulk run can be caught
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
    @MainActor
    @Test func testVerifiedCopyRefusedWhileAnotherBulkRunIsInFlight() async throws {
        let (manager, mockFM, diffs) = try makeFixture(names: ["a.txt"])

        manager.isBulkSyncRunning = true
        manager.verifiedIdenticalForCopy = diffs
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
        manager.verifiedIdenticalForCopy = diffs
        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(refused(manager))
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.isVerifyAllRunning)
        manager.isVerifyAllRunning = false

        // With the verify run finished, the identical offer goes through.
        manager.banner = nil
        manager.verifiedIdenticalForCopy = diffs
        await manager.confirmVerifiedCopy()?.value
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        #expect(!refused(manager))
    }

    /// Pin (both directions, against a real in-flight run): while a verified copy is parked
    /// behind the gated operation queue it holds `isBulkSyncRunning`, so a concurrent `syncAll`
    /// is dropped before touching any file, and a second verified copy refuses with the banner.
    /// The run's exit releases the flag and tears down only its own progress.
    @MainActor
    @Test func testVerifiedCopyExcludesConcurrentBulkRuns() async throws {
        let (manager, mockFM, diffs) = try makeFixture(names: ["a.txt", "b.txt"])
        let verifiedDiff = diffs[0]
        let bulkDiff = diffs[1]

        // Park the operation queue so the verified-copy run stays mid-flight.
        let gate = Gate()
        Task { await manager.enqueueFileOperation { await gate.wait() } }
        await waitUntil("the gated operation occupies the queue") { manager.activeFileOperationsCount > 0 }

        manager.verifiedIdenticalForCopy = [verifiedDiff]
        let copyTask = manager.confirmVerifiedCopy()
        await waitUntil("the verified copy publishes bulk progress") { manager.bulkSyncProgress != nil }
        #expect(manager.isBulkSyncRunning)

        // A bulk sync started now must be dropped, not queued behind the gate.
        let syncAllTask = Task { await manager.syncAll(direction: .copyToRight, subset: [bulkDiff]) }
        // And a second verified copy must refuse visibly instead of joining the queue.
        // (Awaited only after the gate opens, so a regression fails assertions, not hangs.)
        manager.verifiedIdenticalForCopy = [bulkDiff]
        let secondCopyTask = manager.confirmVerifiedCopy()
        for _ in 0..<100 { await Task.yield() }
        #expect(refused(manager))

        await gate.open()
        await copyTask?.value
        await secondCopyTask?.value
        await syncAllTask.value

        // Only the first run's work happened; the refused runs never touched b.txt.
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
