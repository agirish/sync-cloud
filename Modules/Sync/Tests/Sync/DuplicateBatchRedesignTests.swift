import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// The duplicate batch apply: one `deleteItems` call for the whole batch, no `NSUndoManager` group
/// held open across suspension points, one permanent-delete confirmation, and a removal gate that
/// re-verifies every group at the two points where user-paced time can stale a verdict: when the
/// serialized operation starts (the queue can hold it behind a long operation) and after a
/// confirmed permanent delete (the dialog stays open as long as the user leaves it).
@Suite @MainActor struct DuplicateBatchRedesignTests {
    /// Per test (see `LogCapture`): `batchRefusalsAreLoggedPerGroupWithKeeperAndCopyPaths` fails
    /// on CI when it reads the shared buffer directly.
    private let log = LogCapture()


    @MainActor
    private func makeManager(_ fm: MockFileManager) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fm)
        manager.undoManager = UndoManager()
        return manager
    }

    private func stub(size: Int, modified: Date? = Date(timeIntervalSince1970: 1_000)) -> MockFileManager.FileStub {
        var attrs: [FileAttributeKey: Any] = [.size: size]
        if let modified { attrs[.modificationDate] = modified }
        return MockFileManager.FileStub(isDirectory: false, attributes: attrs, contents: nil)
    }

    private func group(keeper: String, redundant: String, reclaim: Int = 1000) -> DuplicateGroup {
        let when = Date(timeIntervalSince1970: 1_000)
        let k = DuplicateCopy(id: keeper, name: (keeper as NSString).lastPathComponent, isDirectory: false,
                              size: 1000, itemCount: 1, modificationDate: when,
                              uniqueItemCount: 0, depth: 1, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant, name: (redundant as NSString).lastPathComponent, isDirectory: false,
                              size: 1000, itemCount: 1, modificationDate: when,
                              uniqueItemCount: 0, depth: 1, isRecommendedKeeper: false)
        return DuplicateGroup(matchType: .identical, name: k.name, isDirectory: false,
                              copies: [k, r], reclaimableBytes: reclaim)
    }

    /// The shared logger's most recent line containing `fragment`, awaiting a flush marker first
    /// so everything enqueued before it is visible (`Logger` appends asynchronously).
    @MainActor
    private func loggedLine(containing fragment: String) async -> String? {
        await log.line(containing: fragment)
    }

    /// A continuation-backed latch for parking an enqueued file operation WITHOUT blocking a
    /// cooperative-pool thread (see docs/flaky-tests.md, "Every gate parks at once, on the pool
    /// their releases need").
    private actor Latch {
        private var opened = false
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func open() {
            opened = true
            for c in continuations { c.resume() }
            continuations.removeAll()
        }
    }

    // MARK: One undo step for the whole batch — and only the batch

    /// The batch is one ⌘Z, and that ⌘Z touches nothing else: a multi-group batch comes back whole
    /// from one undo, and an unrelated operation that finished before the batch does not come back
    /// with it.
    @MainActor
    @Test func aMultiGroupBatchIsReversedWholeByOneUndoAndNothingMore() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        // An unrelated delete first: its undo registration sits below the batch's on the stack.
        mockFM.virtualDisk["/c/unrelated.txt"] = stub(size: 77)
        await manager.deleteItems(at: ["/c/unrelated.txt"], fileManager: mockFM)
        try #require(mockFM.virtualDisk["/c/unrelated.txt"] == nil)
        // Close the unrelated delete's undo event group before the batch registers.
        await closeTheUndoEventGroup(manager.undoManager)

        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        mockFM.virtualDisk["/a/y"] = stub(size: 1000)
        mockFM.virtualDisk["/b/y"] = stub(size: 1000)
        let g1 = group(keeper: "/a/x", redundant: "/b/x")
        let g2 = group(keeper: "/a/y", redundant: "/b/y")
        manager.duplicateGroups = [g1, g2]

        await manager.applyRecommendedDuplicates([g1, g2])
        try #require(mockFM.virtualDisk["/b/x"] == nil)
        try #require(mockFM.virtualDisk["/b/y"] == nil)
        #expect(manager.banner?.isUndoable == true)
        await closeTheUndoEventGroup(manager.undoManager)

        // One undo brings the whole batch back…
        manager.undoManager?.undo()
        await waitUntil("one undo restores every copy the batch trashed") {
            mockFM.virtualDisk["/b/x"] != nil && mockFM.virtualDisk["/b/y"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        // …and only the batch: the unrelated delete can still be undone but isn't.
        #expect(mockFM.virtualDisk["/c/unrelated.txt"] == nil,
                "one ⌘Z after the batch also reversed an unrelated earlier delete — the batch's undo step leaked beyond the batch")
        #expect(manager.undoManager?.canUndo == true,
                "the unrelated delete's own undo step disappeared with the batch's")
        // The stack really held them apart: the second undo restores the unrelated file.
        manager.undoManager?.undo()
        await waitUntil("the second undo restores the unrelated file") {
            mockFM.virtualDisk["/c/unrelated.txt"] != nil
        }
        await waitUntil("second undo op drains") { manager.activeFileOperationsCount == 0 }
    }

    // MARK: One confirmation dialog for the whole batch

    /// On a Trash-less volume the batch asks once, for everything, not one permanent-delete dialog
    /// per group.
    @MainActor
    @Test func aTrashlessBatchRaisesOneConfirmationForAllGroups() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true
        let manager = makeManager(mockFM)
        let asked = LockedBox<[[String]]>([])
        manager.permanentDeleteConfirmer = { paths in
            asked.withLock { $0.append(paths) }
            return true
        }
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        mockFM.virtualDisk["/a/y"] = stub(size: 1000)
        mockFM.virtualDisk["/b/y"] = stub(size: 1000)
        let g1 = group(keeper: "/a/x", redundant: "/b/x")
        let g2 = group(keeper: "/a/y", redundant: "/b/y")
        manager.duplicateGroups = [g1, g2]

        await manager.applyRecommendedDuplicates([g1, g2])

        let invocations = asked.withLock { $0 }
        #expect(invocations.count == 1,
                "the batch asked \(invocations.count) times — one dialog per group is the shape the redesign removed")
        // This checks the argument only: the confirmer is handed every full path, so the alert can
        // tell same-named copies apart. That the alert shows them is the app's half, pinned by
        // `SyncOperationAlertsTests.permanentDeleteBodyNamesEveryItemByPath`.
        #expect(Set(invocations.first ?? []) == ["/b/x", "/b/y"],
                "the engine did not hand the confirmer the full paths of everything it is about to destroy")
        #expect(mockFM.virtualDisk["/b/x"] == nil)
        #expect(mockFM.virtualDisk["/b/y"] == nil)
        // Permanent deletes poison the undo offer.
        #expect(manager.banner?.message.contains("⌘Z") != true)
        #expect(manager.banner?.isUndoable != true)
    }

    /// A declined confirmation destroys nothing anywhere in the batch: the decline covers every
    /// path the dialog named, nothing is removed before or after it, and every group stays listed.
    @MainActor
    @Test func aDeclinedConfirmationRemovesNothingAndKeepsEveryGroupListed() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true
        let manager = makeManager(mockFM)
        let asked = LockedBox<Int>(0)
        manager.permanentDeleteConfirmer = { _ in
            asked.withLock { $0 += 1 }
            return false
        }
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        mockFM.virtualDisk["/a/y"] = stub(size: 1000)
        mockFM.virtualDisk["/b/y"] = stub(size: 1000)
        let g1 = group(keeper: "/a/x", redundant: "/b/x")
        let g2 = group(keeper: "/a/y", redundant: "/b/y")
        manager.duplicateGroups = [g1, g2]

        await manager.applyRecommendedDuplicates([g1, g2])

        #expect(asked.withLock { $0 } == 1)
        for path in ["/a/x", "/b/x", "/a/y", "/b/y"] {
            #expect(mockFM.virtualDisk[path] != nil, "\(path) was removed despite the decline")
        }
        #expect(mockFM.attemptedRemovePaths.isEmpty,
                "a decline must reach removeItem for nothing")
        #expect(manager.duplicateGroups.count == 2, "both groups stay listed for a retry")
        // The batch stopping short is a log line, not silence.
        #expect(await loggedLine(containing: "the batch removed nothing") != nil)
    }

    // MARK: Verify-then-trash ordering, and the two user-paced windows

    /// A group that drifts while the batch's delete waits in the serialized queue is refused at the
    /// last check: the phase-1 verdict can be minutes old by then, and acting on it is the blind
    /// batch the checks exist to prevent.
    @MainActor
    @Test func aGroupThatDriftsDuringTheQueueWaitIsRefusedAtTheLastCheck() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        mockFM.virtualDisk["/a/y"] = stub(size: 1000)
        mockFM.virtualDisk["/b/y"] = stub(size: 1000)
        let g1 = group(keeper: "/a/x", redundant: "/b/x")
        let g2 = group(keeper: "/a/y", redundant: "/b/y")
        manager.duplicateGroups = [g1, g2]

        // A long operation is already on the queue when the batch starts.
        let latch = Latch()
        let blockerRunning = LockedBox<Bool>(false)
        let blocker = Task { await manager.enqueueFileOperation { @Sendable in
            blockerRunning.withLock { $0 = true }
            await latch.wait()
        } }
        await waitUntil("the blocking operation holds the queue") { blockerRunning.withLock { $0 } }

        let batch = Task { await manager.applyRecommendedDuplicates([g1, g2]) }
        // Phase 1 verifies both groups, then the batch's one delete parks behind the blocker.
        await waitUntil("the batch's delete is queued behind the blocker") {
            manager.activeFileOperationsCount == 2
        }
        // Group 2's copy is rewritten in the queue-wait window, after phase 1's verdict.
        mockFM.virtualDisk["/b/y"] = stub(size: 2000)
        await latch.open()
        await batch.value
        _ = await blocker.value

        #expect(mockFM.virtualDisk["/b/x"] == nil, "the clean group still resolves")
        #expect(mockFM.virtualDisk["/b/y"] != nil,
                "a copy rewritten during the queue wait was trashed on a verdict from before the rewrite")
        #expect(manager.duplicateGroups.contains { $0.id == g2.id }, "the refused group stays listed")
        #expect(manager.duplicateGroups.contains { $0.id == g1.id } == false)
        let message = try #require(manager.banner?.message)
        #expect(message.contains("changed since the scan"),
                "the mixed banner must say a group was refused for drift: “\(message)”")
        #expect(await loggedLine(containing: "at the last check before removal") != nil,
                "a last-moment refusal must reach the log he audits")
    }

    /// A copy rewritten while the permanent-delete dialog is open is not destroyed on the
    /// pre-dialog verdict. The dialog is user-paced and what follows is unrecoverable, so the gate
    /// re-runs after the confirmation, right before `removeItem`.
    @MainActor
    @Test func aCopyThatDriftsWhileTheConfirmationDialogIsOpenIsNotPermanentlyDeleted() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true
        let manager = makeManager(mockFM)
        // The dialog is the drift window: the confirmer rewrites the copy, then confirms.
        manager.permanentDeleteConfirmer = { _ in
            mockFM.virtualDisk["/b/x"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [.size: 2000, .modificationDate: Date(timeIntervalSince1970: 9_999)],
                contents: nil)
            return true
        }
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        let g = group(keeper: "/a/x", redundant: "/b/x")
        manager.duplicateGroups = [g]

        await manager.applyRecommendedDuplicates([g])

        #expect(mockFM.virtualDisk["/b/x"] != nil,
                "a copy rewritten during the confirmation dialog was permanently deleted on the stale verdict")
        #expect(mockFM.attemptedRemovePaths.contains("/b/x") == false,
                "removeItem ran for the drifted copy — the post-confirm gate never fired")
        #expect(manager.duplicateGroups.count == 1, "the refused group stays listed")
        #expect(manager.banner?.message.contains("changed since they were scanned") == true)
    }

    /// The same window on the single-group path: `resolveDuplicateGroup` must refuse too.
    @MainActor
    @Test func resolveRefusesACopyThatDriftedWhileTheConfirmationDialogWasOpen() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true
        let manager = makeManager(mockFM)
        manager.permanentDeleteConfirmer = { _ in
            mockFM.virtualDisk["/b/x"] = MockFileManager.FileStub(
                isDirectory: false,
                attributes: [.size: 2000, .modificationDate: Date(timeIntervalSince1970: 9_999)],
                contents: nil)
            return true
        }
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        let g = group(keeper: "/a/x", redundant: "/b/x")
        manager.duplicateGroups = [g]

        let ok = await manager.resolveDuplicateGroup(g)

        #expect(ok == false)
        #expect(mockFM.virtualDisk["/b/x"] != nil,
                "the drifted copy was destroyed permanently on a verdict from before the dialog")
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("changed since it was scanned") == true)
    }

    // MARK: The keeper's verdict is the freshest one

    /// The keeper is re-walked last, so its "unchanged" reading is the newest when the caller acts;
    /// each candidate walk would age it. Pinned on the walk order itself, because the removal
    /// gate's second pass would hide a wrong order from a purely behavioural fixture.
    @MainActor
    @Test func theFolderDriftCheckWalksTheKeeperAfterTheCandidates() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        FileSyncManagerDuplicatesTests.plantFolder(mockFM, at: "/a/Photos", files: 2, bytesEach: 100)
        FileSyncManagerDuplicatesTests.plantFolder(mockFM, at: "/b/Photos", files: 2, bytesEach: 100)
        let snapshot = FileSyncManagerDuplicatesTests.mockFolderSnapshot(files: 2)
        let g = FileSyncManagerDuplicatesTests.folderGroup(
            keeper: "/a/Photos", redundant: "/b/Photos", size: 200, itemCount: 2, snapshot: snapshot)
        manager.duplicateGroups = [g]
        let walked = LockedBox<[String]>([])
        mockFM.onEnumerate = { url in
            if url.path == "/a/Photos" || url.path == "/b/Photos" {
                walked.withLock { $0.append(url.path) }
            }
        }

        #expect(await manager.resolveDuplicateGroup(g) == true)

        let order = walked.withLock { $0 }
        let keeperFirstWalk = try #require(order.firstIndex(of: "/a/Photos"),
                                           "the keeper was never re-walked at all")
        let candidateFirstWalk = try #require(order.firstIndex(of: "/b/Photos"))
        #expect(candidateFirstWalk < keeperFirstWalk,
                "the keeper was walked before the candidates (order: \(order)) — every candidate walk after it stales its verdict")
    }

    /// The behavioural half: content that lands in the keeper while a candidate is walked is seen,
    /// because the keeper's walk comes after. The gate's second pass would catch this too, so the
    /// test above is the one that holds the order.
    @MainActor
    @Test func aKeeperEditDuringACandidateWalkIsRefused() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        FileSyncManagerDuplicatesTests.plantFolder(mockFM, at: "/a/Photos", files: 2, bytesEach: 100)
        FileSyncManagerDuplicatesTests.plantFolder(mockFM, at: "/b/Photos", files: 2, bytesEach: 100)
        let snapshot = FileSyncManagerDuplicatesTests.mockFolderSnapshot(files: 2)
        let g = FileSyncManagerDuplicatesTests.folderGroup(
            keeper: "/a/Photos", redundant: "/b/Photos", size: 200, itemCount: 2, snapshot: snapshot)
        manager.duplicateGroups = [g]
        let planted = LockedBox<Bool>(false)
        mockFM.onEnumerate = { url in
            // A file lands in the keeper while the candidate is being verified.
            guard url.path == "/b/Photos", planted.withLock({ let was = $0; $0 = true; return !was }) else { return }
            mockFM.virtualDisk["/a/Photos/landed-mid-walk.jpg"] = MockFileManager.FileStub(
                isDirectory: false, attributes: [.size: 100], contents: nil)
        }

        let ok = await manager.resolveDuplicateGroup(g)

        #expect(ok == false, "the keeper changed mid-verification and the copies were trashed anyway")
        #expect(mockFM.virtualDisk["/b/Photos"] != nil)
        #expect(manager.banner?.severity == .warning)
    }

    // MARK: Refusal accounting — the log and the mixed banner

    /// Every phase-1 refusal writes a per-group line naming the keeper and the refused copy, worded
    /// by cause (drifted or no baseline), so refusals show in the log he audits.
    @MainActor
    @Test func batchRefusalsAreLoggedPerGroupWithKeeperAndCopyPaths() async throws {
        let token = String(UUID().uuidString.prefix(8))
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        // Group 1: file copy rewritten since the scan (drifted wording).
        mockFM.virtualDisk["/\(token)/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/\(token)/b/x"] = stub(size: 2000)
        let drifted = group(keeper: "/\(token)/a/x", redundant: "/\(token)/b/x")
        // Group 2: folder copies with no baseline (no-baseline wording).
        FileSyncManagerDuplicatesTests.plantFolder(mockFM, at: "/\(token)/a/Photos", files: 2, bytesEach: 100)
        FileSyncManagerDuplicatesTests.plantFolder(mockFM, at: "/\(token)/b/Photos", files: 2, bytesEach: 100)
        let baselineless = FileSyncManagerDuplicatesTests.folderGroup(
            keeper: "/\(token)/a/Photos", redundant: "/\(token)/b/Photos",
            size: 200, itemCount: 2, snapshot: nil)
        manager.duplicateGroups = [drifted, baselineless]

        await manager.applyRecommendedDuplicates([drifted, baselineless])

        let driftLine = try #require(await loggedLine(containing: "/\(token)/b/x"),
                                     "the drifted group's refusal wrote nothing to the log")
        #expect(driftLine.contains("changed after the scan"))
        #expect(driftLine.contains("/\(token)/a/x"), "the line must name the keeper as well as the copy")
        let baselineLine = try #require(await loggedLine(containing: "/\(token)/b/Photos"),
                                        "the no-baseline group's refusal wrote nothing to the log")
        #expect(baselineLine.contains("no scan baseline"))
        #expect(baselineLine.contains("/\(token)/a/Photos"))
        // And nothing was trashed on the way to those lines.
        #expect(mockFM.virtualDisk["/\(token)/b/x"] != nil)
        #expect(mockFM.virtualDisk["/\(token)/b/Photos"] != nil)
    }

    /// The mixed arm of the all-refused banner (`refused != refusedForMissingBaseline`): with one
    /// drifted group and one baseline-less group, the banner says "changed since they were
    /// scanned" (a change was measured), not "couldn't be fully checked".
    @MainActor
    @Test func aMixedRefusalBatchSaysChangedNotUnchecked() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 2000)   // rewritten since the scan
        let drifted = group(keeper: "/a/x", redundant: "/b/x")
        FileSyncManagerDuplicatesTests.plantFolder(mockFM, at: "/a/Photos", files: 2, bytesEach: 100)
        FileSyncManagerDuplicatesTests.plantFolder(mockFM, at: "/b/Photos", files: 2, bytesEach: 100)
        let baselineless = FileSyncManagerDuplicatesTests.folderGroup(
            keeper: "/a/Photos", redundant: "/b/Photos", size: 200, itemCount: 2, snapshot: nil)
        manager.duplicateGroups = [drifted, baselineless]

        await manager.applyRecommendedDuplicates([drifted, baselineless])

        let message = try #require(manager.banner?.message)
        #expect(message.contains("changed since they were scanned"),
                "a batch where a change WAS measured must say so: “\(message)”")
        #expect(!message.contains("couldn’t be fully checked"),
                "the all-baseline-less wording leaked into the mixed case: “\(message)”")
        #expect(mockFM.virtualDisk["/b/x"] != nil)
        #expect(mockFM.virtualDisk["/b/Photos"] != nil)
    }

    /// A partial batch's banner names the refused groups instead of burying them in "the rest
    /// stay listed".
    @MainActor
    @Test func aPartialBatchBannerNamesTheRefusals() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/a/x"] = stub(size: 1000)
        mockFM.virtualDisk["/b/x"] = stub(size: 1000)
        mockFM.virtualDisk["/a/y"] = stub(size: 1000)
        mockFM.virtualDisk["/b/y"] = stub(size: 2000)   // rewritten since the scan
        let clean = group(keeper: "/a/x", redundant: "/b/x")
        let drifted = group(keeper: "/a/y", redundant: "/b/y")
        manager.duplicateGroups = [clean, drifted]

        await manager.applyRecommendedDuplicates([clean, drifted])

        #expect(mockFM.virtualDisk["/b/x"] == nil)
        #expect(mockFM.virtualDisk["/b/y"] != nil)
        let message = try #require(manager.banner?.message)
        #expect(message.contains("1 of 2 groups"))
        #expect(message.contains("changed since the scan"),
                "the refusal is invisible in the mixed banner: “\(message)”")
        #expect(message.contains("left alone"), "the banner must say the refused group was not touched: “\(message)”")
    }

    // MARK: The `deleteItems` gate itself

    /// The gate is consulted when the serialized operation starts, with the pruned path list; a
    /// refused path is left on disk and counted while the others proceed.
    @MainActor
    @Test func theRemovalGateRunsAtOperationStartAndRefusedPathsStay() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/d/keep.txt"] = stub(size: 10)
        mockFM.virtualDisk["/d/go.txt"] = stub(size: 10)
        let consulted = LockedBox<[[String]]>([])

        let outcome = await manager.deleteItems(at: ["/d/keep.txt", "/d/go.txt"], fileManager: mockFM,
                                                removalGate: { paths in
            consulted.withLock { $0.append(paths) }
            return ["/d/keep.txt"]
        })

        // One invocation, holding exactly the pruned batch. Order is the pruner's own (it sorts
        // by path length for the nested-path pass), so compare as a set.
        let invocations = consulted.withLock { $0 }
        #expect(invocations.count == 1, "the gate must run exactly once when nothing escalates")
        #expect(Set(invocations.first ?? []) == ["/d/keep.txt", "/d/go.txt"],
                "the gate must see exactly the pruned batch at operation start")
        #expect(mockFM.virtualDisk["/d/keep.txt"] != nil, "a refused path was removed anyway")
        #expect(mockFM.virtualDisk["/d/go.txt"] == nil, "a refusal of one path must not block the others")
        #expect(outcome == DeleteOutcome(trashed: 1, refusedByGate: 1))
    }

    /// After a confirmed permanent delete the gate runs again, over just the paths about to be
    /// destroyed, and a second-pass refusal reaches `removeItem` for nothing.
    @MainActor
    @Test func theRemovalGateRunsAgainAfterAConfirmedPermanentDelete() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true
        let manager = makeManager(mockFM)
        manager.permanentDeleteConfirmer = { _ in true }
        mockFM.virtualDisk["/d/x.txt"] = stub(size: 10)
        let consulted = LockedBox<[[String]]>([])
        let calls = LockedBox<Int>(0)

        let outcome = await manager.deleteItems(at: ["/d/x.txt"], fileManager: mockFM,
                                                removalGate: { paths in
            consulted.withLock { $0.append(paths) }
            // Allow the first pass (pre-trash), refuse the second (post-confirm).
            return calls.withLock { $0 += 1; return $0 } == 1 ? [] : ["/d/x.txt"]
        })

        #expect(consulted.withLock { $0 }.count == 2,
                "the gate must run once at start and once after the confirmation")
        #expect(mockFM.virtualDisk["/d/x.txt"] != nil, "the post-confirm refusal did not hold")
        #expect(mockFM.attemptedRemovePaths.isEmpty, "removeItem ran despite the refusal")
        #expect(outcome == DeleteOutcome(refusedByGate: 1))
    }

    /// A wholesale gate refusal is the opposite of "already gone" (the items are on disk, kept on
    /// purpose), so the direct-gesture banner must not claim they vanished.
    @MainActor
    @Test func aGateRefusedBatchIsNotReportedAsAlreadyGone() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        mockFM.virtualDisk["/d/x.txt"] = stub(size: 10)

        _ = await manager.deleteItems(at: ["/d/x.txt"], fileManager: mockFM,
                                      reportsNothingToDo: true,
                                      removalGate: { _ in ["/d/x.txt"] })

        #expect(mockFM.virtualDisk["/d/x.txt"] != nil)
        #expect(manager.banner?.message.contains("already gone") != true,
                "a kept file was reported as already gone: “\(manager.banner?.message ?? "nil")”")
    }

    /// A batch the gate refused outright still leaves a `deleteItems`-level log line, as every
    /// other exit does. `removalGate` is a caller-supplied closure that need not log, and a quiet
    /// gate would make the delete gesture read as ignored. The gate here logs nothing, so the line
    /// must come from `deleteItems`.
    @MainActor
    @Test func aWhollyGateRefusedDeleteIsLoggedAtTheDeleteLevel() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        let tag = UUID().uuidString          // process-global logger: only this run can match
        mockFM.virtualDisk["/d/\(tag)-a.txt"] = stub(size: 10)
        mockFM.virtualDisk["/d/\(tag)-b.txt"] = stub(size: 10)

        // Markers before and after, so only this delete's lines are read from a process-wide
        // logger. Read from the on-disk log: the in-memory `entries` is capped at 1000 and evicts
        // the opening marker in a parallel run. See `logLines(tag:during:)`.
        let mine = try await logLines(tag: tag) {
            _ = await manager.deleteItems(at: ["/d/\(tag)-a.txt", "/d/\(tag)-b.txt"], fileManager: mockFM,
                                          removalGate: { paths in Set(paths) })
        }

        #expect(mockFM.virtualDisk["/d/\(tag)-a.txt"] != nil && mockFM.virtualDisk["/d/\(tag)-b.txt"] != nil,
                "the fixture did not actually refuse — the assertions below would be about nothing")
        let line = mine.last { $0.contains("removal gate kept") }
        #expect(line != nil,
                "a delete whose every path the gate refused left no line at the deleteItems level — the gesture is invisible in the log unless the gate itself happens to talk: \(mine)")
        #expect(line?.contains("kept 2 of 2") == true,
                "the line must say how many of how many were kept: “\(line ?? "nil")”")
    }

    // MARK: The snapshot comparison sees kind, not just size

    /// A file that becomes a directory at the same relative path (or the reverse) is drift even
    /// when sizes line up. The mock walk records every file at size 0, so a size-only comparison
    /// would call these equal.
    @MainActor
    @Test func aKindChangeAtTheSamePathIsDrift() async throws {
        let mockFM = MockFileManager()
        mockFM.virtualDisk["/r"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: nil)
        mockFM.virtualDisk["/r/a"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: nil)
        let snapshot = FolderContentSnapshot(entries: ["a": .file(size: 0, modificationDate: nil)],
                                             ignoredNames: [])

        let matches = await FileSyncManager.folderContentsMatchScan(
            path: "/r", snapshot: snapshot, fileManager: mockFM)

        #expect(matches == false,
                "an entry that changed KIND at the same path compared equal — a size-only comparison shipped")

        // The control, so the test can't pass by refusing everything: the same snapshot against a
        // disk that still holds the file matches.
        mockFM.virtualDisk["/r/a"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let control = await FileSyncManager.folderContentsMatchScan(
            path: "/r", snapshot: snapshot, fileManager: mockFM)
        #expect(control == true, "the fixture refuses even the unchanged case, so the assertion above is vacuous")
    }
}
