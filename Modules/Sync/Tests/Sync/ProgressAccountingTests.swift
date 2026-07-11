import Testing
import Foundation
import Combine
@testable import Sync

/// Regression coverage for `activeProgress` / bulk progress accounting:
/// - an operation queued behind a running one must not clobber (or blank out) the running
///   operation's `activeProgress`; each operation publishes its progress only when it starts,
/// - `syncAll` must count collision-skipped items as completed so the progress reaches 100%
///   instead of stalling at (total - skipped).
@Suite struct ProgressAccountingTests {

    /// Wraps `MockFileManager` and blocks copy/move calls on a semaphore, so a test can hold an
    /// operation "in flight" at a deterministic point. Gates time out (rather than hang the
    /// suite) if a test forgets to signal.
    private final class GatedFileManager: FileManaging, @unchecked Sendable {
        private let inner: MockFileManager
        var copyGate: DispatchSemaphore?
        var moveGate: DispatchSemaphore?

        init(inner: MockFileManager) { self.inner = inner }

        func copyItem(at srcURL: URL, to dstURL: URL) throws {
            _ = copyGate?.wait(timeout: .now() + 10)
            try inner.copyItem(at: srcURL, to: dstURL)
        }
        func moveItem(at srcURL: URL, to dstURL: URL) throws {
            _ = moveGate?.wait(timeout: .now() + 10)
            try inner.moveItem(at: srcURL, to: dstURL)
        }
        func fileExists(atPath path: String) -> Bool {
            inner.fileExists(atPath: path)
        }
        func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: path, isDirectory: isDirectory)
        }
        func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            try inner.attributesOfItem(atPath: path)
        }
        func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }
        func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: url, resultingItemURL: outResultingURL)
        }
        func removeItem(at URL: URL) throws {
            try inner.removeItem(at: URL)
        }
        func replaceItem(at destinationURL: URL, withItemAt stagedURL: URL, backupItemName: String) throws -> URL? {
            try inner.replaceItem(at: destinationURL, withItemAt: stagedURL, backupItemName: backupItemName)
        }
        func enumerator(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions, errorHandler handler: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: url, includingPropertiesForKeys: keys, options: mask, errorHandler: handler)
        }
    }

    /// Polls a main-actor condition until it holds or the timeout expires (recording a failure).
    @MainActor
    private func waitUntil(_ what: Comment, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), what)
    }

    @MainActor
    @Test func testQueuedOperationDoesNotClobberRunningProgress() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/srcA"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dstA"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/srcB"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dstB"), withIntermediateDirectories: true)
        inner.virtualDisk["/srcA/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        inner.virtualDisk["/srcB/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let manager = FileSyncManager()
        // No collisions expected, but the seams stay mocked so no NSAlert can ever appear.
        manager.collisionResolver = { _, _, _ in .replace }
        manager.bulkCollisionResolver = { _, _, _ in (.replace, true) }
        manager.permanentDeleteConfirmer = { _ in false }

        let copyFM = GatedFileManager(inner: inner)
        copyFM.copyGate = DispatchSemaphore(value: 0)
        let moveFM = GatedFileManager(inner: inner)
        moveFM.moveGate = DispatchSemaphore(value: 0)

        let nodeA = FileNode(id: "/srcA/a.txt", name: "a.txt", isDirectory: false)
        let nodeB = FileNode(id: "/srcB/b.txt", name: "b.txt", isDirectory: false)

        // Start a copy and hold it in flight.
        let opA = Task {
            await manager.copyItems(nodes: [nodeA], fromLeft: true, leftRoot: "/srcA", rightRoot: "/dstA", fileManager: copyFM)
        }
        await waitUntil("copy progress becomes visible") {
            manager.activeProgress?.localizedDescription == "Copying 1 Items"
        }

        // Queue a move behind it.
        let opB = Task {
            await manager.moveItems(nodes: [nodeB], fromLeft: true, leftRoot: "/srcB", rightRoot: "/dstB", fileManager: moveFM)
        }
        await waitUntil("move operation is enqueued") { manager.activeFileOperationsCount == 2 }

        // The queued move must not replace the running copy's progress.
        #expect(manager.activeProgress?.localizedDescription == "Copying 1 Items")

        // Finish the copy; its completion must not blank out the move's progress once the move starts.
        copyFM.copyGate?.signal()
        _ = await opA.value
        await waitUntil("move progress becomes visible") {
            manager.activeProgress?.localizedDescription == "Moving 1 Items"
        }

        moveFM.moveGate?.signal()
        _ = await opB.value
        await waitUntil("progress is cleared when all operations finish") { manager.activeProgress == nil }

        #expect(inner.virtualDisk["/dstA/a.txt"] != nil)
        #expect(inner.virtualDisk["/dstB/b.txt"] != nil)
        #expect(inner.virtualDisk["/srcB/b.txt"] == nil)
    }

    @MainActor
    @Test func testSyncAllCountsSkippedItemsTowardCompletion() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/collides.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/collides.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/fresh.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        // The user answers "Skip" to the collision dialog (mocked seam — no NSAlert).
        manager.collisionResolver = { _, _, _ in .skip }
        manager.bulkCollisionResolver = { _, _, _ in (.skip, true) }

        let collides = FileDifference(
            relativePath: "collides.txt",
            leftItemPath: "/src/collides.txt",
            rightItemPath: "/dst/collides.txt",
            type: .differentDates,
            action: .copyToRight,
            description: "Different dates"
        )
        let fresh = FileDifference(
            relativePath: "fresh.txt",
            leftItemPath: "/src/fresh.txt",
            rightItemPath: "/dst/fresh.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing"
        )
        manager.rawDifferences = [collides, fresh]
        manager.differences = [collides, fresh]

        var observed: [(completed: Int, total: Int)] = []
        let subscription = manager.$bulkSyncProgress.sink { value in
            if let value { observed.append(value) }
        }
        await manager.syncAll(direction: .copyToRight)
        subscription.cancel()

        // The non-colliding file synced; the colliding one was skipped, not replaced.
        #expect(mockFM.virtualDisk["/dst/fresh.txt"] != nil)
        #expect(mockFM.trashedPaths.isEmpty)

        // The skipped item still counts toward completion: progress ends at 2/2, not stuck at 1/2.
        #expect(observed.last?.completed == 2)
        #expect(observed.last?.total == 2)
        #expect(manager.bulkSyncProgress == nil)
    }

    /// transferItems: a collision answered with Skip on the LAST item must still advance the
    /// overlay to N/N. The skip `continue`d past the per-item progress bump, so a trailing skip
    /// left the bar stuck at N-1 of N until the operation returned (a mid-list skip self-healed
    /// because the next item writes index+1 absolutely).
    @MainActor
    @Test func testTrailingCollisionSkipCompletesTransferProgress() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // The longer id sorts last in pruneNestedNodes, guaranteeing the skip is the trailing item.
        mockFM.virtualDisk["/src/trailing-collision.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/dst/trailing-collision.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let manager = FileSyncManager()
        var captured: Progress?
        manager.collisionResolver = { [weak manager] _, _, _ in
            captured = manager?.activeProgress
            return .skip
        }
        manager.bulkCollisionResolver = { _, _, _ in (.skip, true) }
        manager.permanentDeleteConfirmer = { _ in false }

        await manager.copyItems(
            nodes: [
                FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false),
                FileNode(id: "/src/trailing-collision.txt", name: "trailing-collision.txt", isDirectory: false),
            ],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        let progress = try #require(captured)
        #expect(progress.totalUnitCount == 2)
        #expect(progress.completedUnitCount == 2)
    }

    /// Same accounting hole on the move-onto-itself skip: a trailing "source == destination"
    /// item must count as completed, not leave the bar one short of full.
    @MainActor
    @Test func testTrailingMoveOntoItselfSkipCompletesTransferProgress() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        inner.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        // Already at the destination, so its target equals its source: the move skips it.
        // The longer id sorts last in pruneNestedNodes, making it the trailing item.
        inner.virtualDisk["/dst/trailing-self.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let manager = FileSyncManager()
        manager.collisionResolver = { _, _, _ in .replace }
        manager.bulkCollisionResolver = { _, _, _ in (.replace, true) }
        manager.permanentDeleteConfirmer = { _ in false }

        // Gate the first item's move so the operation is reliably in flight when the
        // progress reference is captured.
        let moveFM = GatedFileManager(inner: inner)
        moveFM.moveGate = DispatchSemaphore(value: 0)

        let op = Task {
            await manager.moveItems(
                nodes: [
                    FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false),
                    FileNode(id: "/dst/trailing-self.txt", name: "trailing-self.txt", isDirectory: false),
                ],
                toPath: "/dst",
                fileManager: moveFM
            )
        }
        await waitUntil("move progress becomes visible") {
            manager.activeProgress?.localizedDescription == "Moving 2 Items"
        }
        let progress = try #require(manager.activeProgress)

        moveFM.moveGate?.signal()
        _ = await op.value

        #expect(inner.virtualDisk["/dst/a.txt"] != nil)
        #expect(inner.virtualDisk["/dst/trailing-self.txt"] != nil)
        #expect(progress.totalUnitCount == 2)
        #expect(progress.completedUnitCount == 2)
    }
}
