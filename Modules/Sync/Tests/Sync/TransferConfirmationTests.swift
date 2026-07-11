import Testing
import Foundation
@testable import Sync

/// Coverage for the `transferConfirmer` seam (every copy/move entry point must ask it once
/// before any I/O, and a declined confirmation must leave the disk untouched) and for the
/// context the collision seams receive (source and destination paths, so the prompt can say
/// which copy of a file is replacing which).
@Suite struct TransferConfirmationTests {

    /// A mock disk with `/src/a.txt`, `/src/b.txt`, and empty `/dst`.
    @MainActor
    private func makeTransferFixture() throws -> (FileSyncManager, MockFileManager) {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let manager = FileSyncManager(fileManager: mockFM)
        return (manager, mockFM)
    }

    /// A single-difference fixture for the syncFile/syncAll entry points.
    @MainActor
    private func makeDifferenceFixture() throws -> (FileSyncManager, MockFileManager, FileDifference) {
        let (manager, mockFM) = try makeTransferFixture()
        let diff = FileDifference(
            relativePath: "a.txt",
            leftItemPath: "/src/a.txt",
            rightItemPath: "/dst/a.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right"
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        return (manager, mockFM, diff)
    }

    // MARK: - Declined confirmations leave the disk untouched

    /// A declined copy transfers nothing, runs no primitive, and reports no error — cancelling
    /// is a user choice, not a failure.
    @MainActor
    @Test func testDeclinedCopyItemsTransfersNothing() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        manager.transferConfirmer = { _ in false }

        let copied = await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(copied.isEmpty)
        #expect(mockFM.calledCopyItem == false)
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.currentError == nil)
    }

    /// A declined move leaves the sources in place.
    @MainActor
    @Test func testDeclinedMoveItemsLeavesSourcesInPlace() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        manager.transferConfirmer = { _ in false }

        let moved = await manager.moveItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(moved.isEmpty)
        #expect(mockFM.virtualDisk["/src/a.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.currentError == nil)
    }

    /// A declined single-row sync returns false, copies nothing, and leaves the row's
    /// in-flight flag clear (it is asked BEFORE the row is marked syncing).
    @MainActor
    @Test func testDeclinedSyncFileReturnsFalseAndCopiesNothing() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        manager.transferConfirmer = { _ in false }

        let ran = await manager.syncFile(diff, isMove: false, fileManager: mockFM)

        #expect(ran == false)
        #expect(mockFM.calledCopyItem == false)
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.syncingDifferenceIds.isEmpty)
        #expect(manager.differences.count == 1)
    }

    /// A declined bulk sync runs nothing and releases the bulk-sync flag so a later
    /// (confirmed) run can start.
    @MainActor
    @Test func testDeclinedSyncAllRunsNothingAndAllowsLaterRun() async throws {
        let (manager, mockFM, _) = try makeDifferenceFixture()
        manager.transferConfirmer = { _ in false }

        await manager.syncAll(direction: .copyToRight)

        #expect(mockFM.calledCopyItem == false)
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.differences.count == 1)

        // The declined run must not have latched isBulkSyncRunning.
        manager.transferConfirmer = { _ in true }
        await manager.syncAll(direction: .copyToRight)
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
    }

    // MARK: - The confirmer is asked once, with an accurate summary

    /// copyItems describes the pruned batch: count, first item, its parent folder, and the
    /// destination directory — and asks exactly once per user action.
    @MainActor
    @Test func testCopyItemsSummaryDescribesBatch() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        var summaries: [TransferSummary] = []
        manager.transferConfirmer = { summary in
            summaries.append(summary)
            return true
        }

        let copied = await manager.copyItems(
            nodes: [
                FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false),
                FileNode(id: "/src/b.txt", name: "b.txt", isDirectory: false),
            ],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(copied.count == 2)
        #expect(summaries.count == 1)
        #expect(summaries.first?.isMove == false)
        #expect(summaries.first?.itemCount == 2)
        #expect(summaries.first?.firstItemName == "a.txt")
        #expect(summaries.first?.sourceDirectory == "/src")
        #expect(summaries.first?.destinationDirectory == "/dst")
    }

    /// syncFile describes the one item with the parent folders of its transfer direction.
    @MainActor
    @Test func testSyncFileSummaryDescribesSingleItem() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        var summaries: [TransferSummary] = []
        manager.transferConfirmer = { summary in
            summaries.append(summary)
            return true
        }

        let ran = await manager.syncFile(diff, isMove: true, fileManager: mockFM)

        #expect(ran == true)
        #expect(summaries.count == 1)
        #expect(summaries.first?.isMove == true)
        #expect(summaries.first?.itemCount == 1)
        #expect(summaries.first?.firstItemName == "a.txt")
        #expect(summaries.first?.sourceDirectory == "/src")
        #expect(summaries.first?.destinationDirectory == "/dst")
    }

    /// syncAll asks once for the whole run with the direction-filtered count and the two
    /// compared folders (not the first item's possibly-deep parent).
    @MainActor
    @Test func testSyncAllSummaryUsesComparedFoldersAndDirectionCount() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/sub"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/sub/deep.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let deep = FileDifference(
            relativePath: "sub/deep.txt",
            leftItemPath: "/src/sub/deep.txt",
            rightItemPath: "/dst/sub/deep.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right"
        )
        let flat = FileDifference(
            relativePath: "b.txt",
            leftItemPath: "/src/b.txt",
            rightItemPath: "/dst/b.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right"
        )
        // Opposite direction: must not count toward (or block) a copyToRight run.
        let other = FileDifference(
            relativePath: "c.txt",
            leftItemPath: "/src/c.txt",
            rightItemPath: "/dst/c.txt",
            type: .missingOnLeft,
            action: .copyToLeft,
            description: "Missing on left"
        )
        manager.rawDifferences = [deep, flat, other]
        manager.differences = [deep, flat, other]

        var summaries: [TransferSummary] = []
        manager.transferConfirmer = { summary in
            summaries.append(summary)
            return true
        }

        await manager.syncAll(direction: .copyToRight)

        #expect(summaries.count == 1)
        #expect(summaries.first?.itemCount == 2)
        #expect(summaries.first?.sourceDirectory == "/src")
        #expect(summaries.first?.destinationDirectory == "/dst")
    }

    // MARK: - Prompts run behind the exclusion latches (not before them)

    /// While the syncAll confirmation prompt is up, `isBulkSyncRunning` must already be
    /// latched: the prompt's modal spins the run loop, so a queued second syncAll (or a
    /// Verify All, whose guard reads the flag) would otherwise pass its exclusion check
    /// mid-prompt. A decline must release the latch.
    @MainActor
    @Test func testBulkSyncFlagIsLatchedDuringConfirmPromptAndReleasedOnDecline() async throws {
        let (manager, _, _) = try makeDifferenceFixture()
        var flagDuringPrompt: Bool?
        manager.transferConfirmer = { [weak manager] _ in
            flagDuringPrompt = manager?.isBulkSyncRunning
            return false
        }

        await manager.syncAll(direction: .copyToRight)

        #expect(flagDuringPrompt == true)
        #expect(manager.isBulkSyncRunning == false)
    }

    /// While the syncFile confirmation prompt is up, the row must already be marked syncing:
    /// Verify All's guard documents that `syncingDifferenceIds` covers a syncFile parked at
    /// a prompt. A decline must clear the mark.
    @MainActor
    @Test func testRowIsMarkedSyncingDuringConfirmPromptAndClearedOnDecline() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        var markedDuringPrompt: Bool?
        manager.transferConfirmer = { [weak manager] _ in
            markedDuringPrompt = manager?.syncingDifferenceIds.contains(diff.id)
            return false
        }

        let ran = await manager.syncFile(diff, isMove: false, fileManager: mockFM)

        #expect(ran == false)
        #expect(markedDuringPrompt == true)
        #expect(manager.syncingDifferenceIds.isEmpty)
    }

    // MARK: - Pre-confirmed callers skip the prompt (one gesture never asks twice)

    /// `confirmed: true` skips the transferConfirmer entirely — for callers whose UI already
    /// embodies the confirmation (review-card accepts, "Copy Remaining N…").
    @MainActor
    @Test func testConfirmedSyncFileAndSyncAllSkipTheConfirmer() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }

        let ran = await manager.syncFile(diff, isMove: false, fileManager: mockFM, confirmed: true)
        #expect(ran == true)
        #expect(prompts == 0)

        // Re-seed a second difference for the bulk entry point.
        let diff2 = FileDifference(
            relativePath: "b.txt",
            leftItemPath: "/src/b.txt",
            rightItemPath: "/dst/b.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right"
        )
        manager.rawDifferences = [diff2]
        manager.differences = [diff2]

        await manager.syncAll(direction: .copyToRight, confirmed: true)
        #expect(prompts == 0)
        #expect(mockFM.virtualDisk["/dst/b.txt"] != nil)
    }

    /// Retry on a failed single-row sync must NOT re-ask the confirmer: the Retry click is
    /// itself the confirmation, and re-prompting made an Escape reflex silently swallow the
    /// retry. One prompt for the original attempt, zero for the retry.
    @MainActor
    @Test func testRetryAfterFailureDoesNotReconfirm() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }
        mockFM.shouldFailCopy = true // one-shot: the retry's copy succeeds

        let ran = await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        #expect(ran == false)
        #expect(prompts == 1)
        #expect(manager.currentError != nil)

        let retry = try #require(manager.currentErrorRetry)
        retry()
        // The retry closure spawns a Task; wait for the move to land.
        for _ in 0..<100 where mockFM.virtualDisk["/dst/a.txt"] == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        #expect(prompts == 1)
    }

    // MARK: - Collision context carries both paths

    /// The single-item resolver sees the full source and destination paths of the collision,
    /// so the prompt can say which copy is replacing which.
    @MainActor
    @Test func testCollisionResolverReceivesSourceAndDestinationPaths() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        var seen: FileCollision?
        manager.collisionResolver = { collision in
            seen = collision
            return .skip
        }

        await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(seen?.fileName == "a.txt")
        #expect(seen?.sourcePath == "/src/a.txt")
        #expect(seen?.destinationPath == "/dst/a.txt")
        #expect(seen?.isMove == false)
        #expect(seen?.isDirectory == false)
    }

    /// The bulk resolver sees the same context per conflicting item.
    @MainActor
    @Test func testBulkCollisionResolverReceivesSourceAndDestinationPaths() async throws {
        let (manager, mockFM, _) = try makeDifferenceFixture()
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        var seen: FileCollision?
        manager.bulkCollisionResolver = { collision in
            seen = collision
            return (.skip, false)
        }

        await manager.syncAll(direction: .copyToRight)

        #expect(seen?.fileName == "a.txt")
        #expect(seen?.sourcePath == "/src/a.txt")
        #expect(seen?.destinationPath == "/dst/a.txt")
    }

    // MARK: - Container derivation

    /// `transferContainers` strips the shared root-relative suffix from both sides, in the
    /// action's direction, so a deep item still names the two compared folders.
    @Test func testTransferContainersStripRelativePath() {
        let diff = FileDifference(
            relativePath: "sub/deep.txt",
            leftItemPath: "/left/root/sub/deep.txt",
            rightItemPath: "/right/root/sub/deep.txt",
            type: .missingOnLeft,
            action: .copyToLeft,
            description: "Missing on left"
        )
        let containers = diff.transferContainers
        #expect(containers.from == "/right/root")
        #expect(containers.to == "/left/root")
    }
}
