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

    /// A declined single-row sync returns false, copies nothing, and leaves no in-flight
    /// mark behind. (The row IS marked during the prompt — see
    /// testRowIsMarkedSyncingDuringConfirmPromptAndClearedOnDecline, which pins that
    /// ordering — but a decline must always clear it.)
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

    /// While the transferItems confirmation prompt is up, the pending operation must already
    /// be counted: the scan-time auto-verify pass is not click-gated (a modal doesn't block
    /// it) and its guard reads `activeFileOperationsCount` — an unlatched prompt would let it
    /// hash the very files this transfer overwrites. A decline reverts the count.
    @MainActor
    @Test func testOperationIsCountedDuringTransferPromptAndUncountedOnDecline() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        var countDuringPrompt: Int?
        manager.transferConfirmer = { [weak manager] _ in
            countDuringPrompt = manager?.activeFileOperationsCount
            return false
        }

        await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(countDuringPrompt == 1)
        #expect(manager.activeFileOperationsCount == 0)
    }

    /// A confirmed transfer must not be double-counted: the pre-count is handed to
    /// `enqueueFileOperation(alreadyCounted:)`, whose completion decrements exactly once.
    @MainActor
    @Test func testConfirmedTransferCountReturnsToZeroAfterCompletion() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        manager.transferConfirmer = { _ in true }

        let copied = await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(copied.count == 1)
        #expect(manager.activeFileOperationsCount == 0)
    }

    /// A row already marked in-flight refuses a second syncFile outright: a queued twin call
    /// running during the first's prompt would otherwise stack a second prompt, and its exit
    /// would clear the shared syncing mark the first call still owns.
    @MainActor
    @Test func testSyncFileRefusesRowAlreadyMarkedSyncing() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }
        manager.markSyncing(ids: [diff.id])

        let ran = await manager.syncFile(diff, isMove: false, fileManager: mockFM)

        #expect(ran == false)
        #expect(prompts == 0)
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        // The refused call must NOT have cleared the owner's mark.
        #expect(manager.syncingDifferenceIds.contains(diff.id))
    }

    /// A bulk sync refuses to start while any single-row sync is in flight (possibly parked
    /// at its prompt): both flows could target the same difference. Mirrors Verify All.
    @MainActor
    @Test func testSyncAllRefusesWhileARowIsMarkedSyncing() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }
        manager.markSyncing(ids: [diff.id])

        await manager.syncAll(direction: .copyToRight)

        #expect(prompts == 0)
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.banner != nil)
    }

    /// The Verify-copy bulk path refuses under the same condition — its defer clears syncing
    /// ids wholesale and would strip a parked syncFile's mark out from under it.
    @MainActor
    @Test func testVerifiedCopyRefusesWhileARowIsMarkedSyncing() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        manager.markSyncing(ids: [diff.id])

        manager.verifiedIdenticalForCopy = [diff]
        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)
        #expect(manager.banner != nil)
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

    /// `confirmed: true` skips ONLY the transfer confirmation — the collision prompt is a
    /// data-safety boundary and must still run when the destination exists. A "skip all
    /// prompts when pre-confirmed" misreading would make review accepts and Retry clicks
    /// replace existing files unprompted.
    @MainActor
    @Test func testConfirmedSyncFileStillRunsTheCollisionPrompt() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        var transferPrompts = 0
        manager.transferConfirmer = { _ in
            transferPrompts += 1
            return true
        }
        var collisionPrompts = 0
        manager.collisionResolver = { _ in
            collisionPrompts += 1
            return .skip
        }

        let ran = await manager.syncFile(diff, isMove: false, fileManager: mockFM, confirmed: true)

        #expect(ran == false) // skipped at the collision prompt
        #expect(transferPrompts == 0)
        #expect(collisionPrompts == 1)
        #expect(mockFM.trashedPaths.isEmpty) // nothing replaced
    }

    /// The "Copy Remaining" engine contract: two sequential confirmed syncAll runs over a
    /// mixed-direction subset transfer BOTH directions with zero prompts — the first run's
    /// bulk-sync latch must be released by the time the awaited second run starts, or the
    /// second direction's items are silently dropped after the review session is torn down.
    @MainActor
    @Test func testSequentialConfirmedSyncAllRunsCoverBothDirections() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        mockFM.virtualDisk["/dst/pull.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let toRight = FileDifference(
            relativePath: "a.txt",
            leftItemPath: "/src/a.txt",
            rightItemPath: "/dst/a.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right"
        )
        let toLeft = FileDifference(
            relativePath: "pull.txt",
            leftItemPath: "/src/pull.txt",
            rightItemPath: "/dst/pull.txt",
            type: .missingOnLeft,
            action: .copyToLeft,
            description: "Missing on left"
        )
        let remaining = [toRight, toLeft]
        manager.rawDifferences = remaining
        manager.differences = remaining
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }

        await manager.syncAll(direction: .copyToRight, subset: remaining, confirmed: true)
        await manager.syncAll(direction: .copyToLeft, subset: remaining, confirmed: true)

        #expect(prompts == 0)
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        #expect(mockFM.virtualDisk["/src/pull.txt"] != nil)
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
        // The retry closure spawns a Task; wait for the copy to land.
        await waitUntil("retry lands the copy") { mockFM.virtualDisk["/dst/a.txt"] != nil }

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

    // MARK: - Direction handling (.copyToLeft summaries and collisions)

    /// A right-to-left sync must describe the transfer in its own direction: From the right
    /// pane's folder, To the left's. All other summary tests use .copyToRight, so this is the
    /// pin against a direction flip describing every right-to-left sync backwards.
    @MainActor
    @Test func testCopyToLeftSyncFileSummaryAndCollisionAreDirectionCorrect() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        // Item lives on the RIGHT (/dst); the difference copies it left into /src, where a
        // same-named file already sits (collision).
        mockFM.virtualDisk["/dst/pull.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/pull.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let diff = FileDifference(
            relativePath: "pull.txt",
            leftItemPath: "/src/pull.txt",
            rightItemPath: "/dst/pull.txt",
            type: .missingOnLeft,
            action: .copyToLeft,
            description: "Missing on left"
        )
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        var summary: TransferSummary?
        manager.transferConfirmer = { s in
            summary = s
            return true
        }
        var collision: FileCollision?
        manager.collisionResolver = { c in
            collision = c
            return .skip
        }

        await manager.syncFile(diff, isMove: false, fileManager: mockFM)

        #expect(summary?.sourceDirectory == "/dst")
        #expect(summary?.destinationDirectory == "/src")
        #expect(collision?.sourcePath == "/dst/pull.txt")
        #expect(collision?.destinationPath == "/src/pull.txt")
    }

    /// The re-stat prompt (destination appears externally after the initial stat — the
    /// single-file TOCTOU window) must carry the same full-path context as the first prompt.
    @MainActor
    @Test func testSyncFileRestatCollisionCarriesFullPaths() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        // Absent at syncFile's initial stat; planted right after that check, so only the
        // pre-enqueue re-stat sees it and runs the collision flow.
        mockFM.onFileExists = { path in
            guard path == "/dst/a.txt" else { return }
            mockFM.onFileExists = nil
            mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        }

        var collision: FileCollision?
        manager.collisionResolver = { c in
            collision = c
            return .skip
        }

        let ran = await manager.syncFile(diff, isMove: false, fileManager: mockFM)

        #expect(ran == false)
        #expect(collision?.sourcePath == "/src/a.txt")
        #expect(collision?.destinationPath == "/dst/a.txt")
    }

    // MARK: - Summary accuracy under pruning and for moves

    /// The prompt's item count reflects the PRUNED selection: selecting a folder plus its own
    /// child transfers one top-level item, and the confirmation must say 1, not 2.
    @MainActor
    @Test func testCopyItemsSummaryCountsPrunedNodes() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/folder"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/folder/inner.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        var summary: TransferSummary?
        manager.transferConfirmer = { s in
            summary = s
            return true
        }

        await manager.copyItems(
            nodes: [
                FileNode(id: "/src/folder", name: "folder", isDirectory: true),
                FileNode(id: "/src/folder/inner.txt", name: "inner.txt", isDirectory: false),
            ],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(summary?.itemCount == 1)
        #expect(summary?.firstItemName == "folder")
    }

    /// The move verb reaches the summary through the transferItems path: a drag-move whose
    /// prompt read "Copy…" would remove sources the user believed were being duplicated.
    @MainActor
    @Test func testMoveItemsSummaryCarriesMoveVerb() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        var summary: TransferSummary?
        manager.transferConfirmer = { s in
            summary = s
            return true
        }

        let moved = await manager.moveItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(moved.count == 1)
        #expect(summary?.isMove == true)
    }

    // MARK: - Deliberate exemptions never consult the confirmer

    /// Undo and redo of a copy run through the undo primitives, not the confirmed transfer
    /// entry points — a refactor routing them through syncFile/transferItems would make Undo
    /// silently do nothing under a declining confirmer.
    @MainActor
    @Test func testUndoRedoNeverConsultTheConfirmer() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        manager.undoManager = UndoManager()
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }

        await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )
        #expect(prompts == 1)
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)

        // Undo (removes the copy) and redo (re-copies) must not prompt again. Both are
        // asynchronous under the hood; poll for their observable effect.
        manager.undoManager?.undo()
        await waitUntil("undo removes the copy") { mockFM.virtualDisk["/dst/a.txt"] == nil }
        #expect(mockFM.virtualDisk["/dst/a.txt"] == nil)

        manager.undoManager?.redo()
        await waitUntil("redo restores the copy") { mockFM.virtualDisk["/dst/a.txt"] != nil }
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        #expect(prompts == 1)
    }

    /// The Verify-All "copy to match dates" bulk path has its own confirmation dialog
    /// upstream (confirmVerifiedCopy); routing it through the transferConfirmer too would
    /// double-prompt. Pin the exemption.
    @MainActor
    @Test func testVerifiedCopyBulkPathNeverConsultsTheConfirmer() async throws {
        let (manager, mockFM, diff) = try makeDifferenceFixture()
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        manager.bulkCollisionResolver = { _ in (.replace, true) }
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }

        manager.verifiedIdenticalForCopy = [diff]
        let copyTask = manager.confirmVerifiedCopy()
        await copyTask?.value

        #expect(prompts == 0)
        #expect(mockFM.trashedPaths.count == 1) // the replace actually ran
    }

    /// A vanished destination root (provider dropped from settings mid-session) must not
    /// prompt at all: confirming `Copy "x" to ""?` and then failing anyway helps nobody.
    /// The operation still fails with its normal destination-unavailable error.
    @MainActor
    @Test func testEmptyDestinationRootFailsWithoutPrompting() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        var prompts = 0
        manager.transferConfirmer = { _ in
            prompts += 1
            return true
        }

        let copied = await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "",
            fileManager: mockFM
        )

        #expect(prompts == 0)
        #expect(copied.isEmpty)
        #expect(manager.currentError != nil)
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

    /// A pane rooted at the filesystem root must yield "/" — the naive suffix strip of
    /// "/a.txt" minus "a.txt" would leave "" and render blank From/To lines in the prompt.
    @Test func testTransferContainersAtFilesystemRootYieldSlash() {
        let diff = FileDifference(
            relativePath: "a.txt",
            leftItemPath: "/a.txt",
            rightItemPath: "/backup/a.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right"
        )
        let containers = diff.transferContainers
        #expect(containers.from == "/")
        #expect(containers.to == "/backup")
    }

    /// An item path that does not end in relativePath (never true for engine-built
    /// differences, but constructible by hand) falls back to the immediate parent instead
    /// of producing garbage from the suffix arithmetic.
    @Test func testTransferContainersFallBackToImmediateParent() {
        let diff = FileDifference(
            relativePath: "unrelated/suffix.txt",
            leftItemPath: "/left/root/deep/item.txt",
            rightItemPath: "/right/root/deep/item.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right"
        )
        let containers = diff.transferContainers
        #expect(containers.from == "/left/root/deep")
        #expect(containers.to == "/right/root/deep")
    }

    // MARK: - The prompt names the landing folder, not the destination root

    /// A cross-pane transfer of a NESTED item must name the folder it lands in. The summary used
    /// to carry the destination root, so copying `Reports/2025/Q3.xlsx` told the user `To: /dst`
    /// while the file went to `/dst/Reports/2025` — wrong for every item below the root, which is
    /// most of them.
    @MainActor
    @Test func testCrossPaneSummaryNamesTheDerivedTargetDirectory() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/Reports/2025"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/Reports/2025/Q3.xlsx"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        var summary: TransferSummary?
        manager.transferConfirmer = { s in
            summary = s
            return true
        }

        await manager.copyItems(
            nodes: [FileNode(id: "/src/Reports/2025/Q3.xlsx", name: "Q3.xlsx", isDirectory: false)],
            fromLeft: true, leftRoot: "/src", rightRoot: "/dst",
            fileManager: mockFM
        )

        #expect(summary?.sourceDirectory == "/src/Reports/2025")
        #expect(summary?.destinationDirectory == "/dst/Reports/2025")
        // The landing path itself is unchanged by the wording fix — that is the whole point.
        #expect(mockFM.virtualDisk["/dst/Reports/2025/Q3.xlsx"] != nil)
    }

    /// An item at the pane root still names the root, so the shallow case reads exactly as before.
    @MainActor
    @Test func testCrossPaneSummaryAtRootStillNamesTheRoot() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        var summary: TransferSummary?
        manager.transferConfirmer = { s in
            summary = s
            return true
        }

        await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            fromLeft: true, leftRoot: "/src", rightRoot: "/dst",
            fileManager: mockFM
        )

        #expect(summary?.destinationDirectory == "/dst")
    }

    /// The drop and paste routes derive `<dir>/<name>`, whose parent IS the directory they were
    /// handed — so this fix must leave them reporting exactly what they reported before.
    @MainActor
    @Test func testToPathSummaryStillNamesTheGivenDirectory() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        var summary: TransferSummary?
        manager.transferConfirmer = { s in
            summary = s
            return true
        }

        await manager.copyItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            toPath: "/dst",
            fileManager: mockFM
        )

        #expect(summary?.destinationDirectory == "/dst")
    }

    // MARK: - A batch that moves nothing says so

    /// Both panes on one provider at the same relative path: every derived target equals its
    /// source, every item is skipped, and the window used to say nothing at all — no banner, no
    /// alert, one debug line. Confirming the prompt and seeing no change was indistinguishable
    /// from a dropped click, which is exactly how this was reported.
    @MainActor
    @Test func testMoveWhereEveryItemIsAlreadyThereReportsIt() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        manager.transferConfirmer = { _ in true }

        let moved = await manager.moveItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            fromLeft: true, leftRoot: "/src", rightRoot: "/src",
            fileManager: mockFM
        )

        #expect(moved.isEmpty)
        #expect(manager.currentError == nil)
        let banner = try #require(manager.banner)
        #expect(banner.severity == .warning)
        #expect(banner.message.contains("a.txt"))
        #expect(banner.message.contains("already in"))
        #expect(banner.message.contains("src"))
    }

    /// Plural wording, and the count comes from the pruned selection.
    @MainActor
    @Test func testMultipleItemsAlreadyThereReportsTheCount() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        manager.transferConfirmer = { _ in true }

        await manager.moveItems(
            nodes: [
                FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false),
                FileNode(id: "/src/b.txt", name: "b.txt", isDirectory: false),
            ],
            fromLeft: true, leftRoot: "/src", rightRoot: "/src",
            fileManager: mockFM
        )

        let banner = try #require(manager.banner)
        #expect(banner.severity == .warning)
        #expect(banner.message.contains("All 2 items"))
    }

    /// Skipping at a COLLISION prompt also transfers nothing, but that is a choice the user just
    /// made and needs no restatement. Without this the new banner would fire on every declined
    /// overwrite — a nag on the app's most common prompt.
    @MainActor
    @Test func testCollisionSkipDoesNotReportNothingToMove() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        mockFM.virtualDisk["/dst/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        manager.transferConfirmer = { _ in true }
        manager.collisionResolver = { _ in .skip }

        let moved = await manager.moveItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            fromLeft: true, leftRoot: "/src", rightRoot: "/dst",
            fileManager: mockFM
        )

        #expect(moved.isEmpty)
        #expect(manager.banner == nil)
    }

    /// A move that actually happened must NOT raise the "already there" warning. The success
    /// banner belongs to `FileActionHandler` (which skips it on an empty result, so the warning
    /// set here survives) — the invariant this layer owns is that a real transfer stays quiet.
    @MainActor
    @Test func testARealMoveDoesNotReportNothingToMove() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        manager.transferConfirmer = { _ in true }

        let moved = await manager.moveItems(
            nodes: [FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false)],
            fromLeft: true, leftRoot: "/src", rightRoot: "/dst",
            fileManager: mockFM
        )

        #expect(moved.count == 1)
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        #expect(manager.banner == nil)
    }

    /// A batch mixing one already-placed item with one that genuinely moves stays quiet: the
    /// warning is for a batch that did nothing at all, not for any batch containing a skip.
    ///
    /// Uses the `toPath:` route deliberately — with a single pair of pane roots every item's
    /// target is derived the same way, so a cross-pane batch either skips wholly or not at all.
    /// An explicit destination is the only route that can produce a genuine partial.
    @MainActor
    @Test func testPartiallyAlreadyThereDoesNotReportNothingToMove() async throws {
        let (manager, mockFM) = try makeTransferFixture()
        mockFM.virtualDisk["/dst/settled.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        manager.transferConfirmer = { _ in true }

        let moved = await manager.moveItems(
            nodes: [
                FileNode(id: "/dst/settled.txt", name: "settled.txt", isDirectory: false),
                FileNode(id: "/src/a.txt", name: "a.txt", isDirectory: false),
            ],
            toPath: "/dst",
            fileManager: mockFM
        )

        // settled.txt is already at its target and skips; a.txt genuinely moves.
        #expect(moved.count == 1)
        #expect(mockFM.virtualDisk["/dst/a.txt"] != nil)
        #expect(manager.banner == nil)
    }
}
