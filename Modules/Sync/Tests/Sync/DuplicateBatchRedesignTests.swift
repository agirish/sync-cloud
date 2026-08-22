import Testing
import Foundation
import Events
@testable import Sync

/// The batch-apply redesign: one `deleteItems` call for the whole batch instead of one per group,
/// no `NSUndoManager` group held open across suspension points, one permanent-delete confirmation
/// instead of N, and a last-moment removal gate re-verifying every group at the two points where
/// user-paced time can stale a verdict — when the serialized operation starts (the op queue can
/// hold the delete behind a long operation) and after a confirmed permanent delete (the dialog is
/// open for as long as the user leaves it).
///
/// These are the pins an adversarial review found missing: emptying the old undo grouping passed
/// the ENTIRE package, deleting the mid-batch stop passed the duplicates suite, and nothing
/// observed verify-then-trash ordering at all.
@Suite struct DuplicateBatchRedesignTests {

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
        await Logger.shared.debug("batch-redesign flush marker").value
        return Logger.shared.entries.last { $0.message.contains(fragment) }?.message
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

    /// **The batch is ONE ⌘Z, and that ⌘Z touches nothing else.** The old shape held an
    /// NSUndoManager group open across the whole loop (including awaits that can hold a modal
    /// dialog); emptying that grouping passed all 2538 package tests, which is exactly the pin
    /// this adds: a multi-group batch must come back WHOLE from one undo, and an unrelated
    /// operation that completed before the batch must NOT come back with it.
    @MainActor
    @Test func aMultiGroupBatchIsReversedWholeByOneUndoAndNothingMore() async throws {
        let mockFM = MockFileManager()
        let manager = makeManager(mockFM)
        // An unrelated delete FIRST — its undo registration sits below the batch's on the stack.
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
        #expect(manager.banner?.message.contains("⌘Z") == true)
        await closeTheUndoEventGroup(manager.undoManager)

        // ONE undo brings the WHOLE batch back…
        manager.undoManager?.undo()
        await waitUntil("one undo restores every copy the batch trashed") {
            mockFM.virtualDisk["/b/x"] != nil && mockFM.virtualDisk["/b/y"] != nil
        }
        await waitUntil("undo op drains") { manager.activeFileOperationsCount == 0 }
        // …and ONLY the batch: the unrelated delete is still undone-able but not undone.
        #expect(mockFM.virtualDisk["/c/unrelated.txt"] == nil,
                "one ⌘Z after the batch also reversed an unrelated earlier delete — the batch's undo step leaked beyond the batch")
        #expect(manager.undoManager?.canUndo == true,
                "the unrelated delete's own undo step disappeared with the batch's")
        // The proof the stack really held them apart: the SECOND undo restores the unrelated file.
        manager.undoManager?.undo()
        await waitUntil("the second undo restores the unrelated file") {
            mockFM.virtualDisk["/c/unrelated.txt"] != nil
        }
        await waitUntil("second undo op drains") { manager.activeFileOperationsCount == 0 }
    }

    // MARK: One confirmation dialog for the whole batch

    /// On a Trash-less volume the per-group loop raised one permanent-delete dialog PER GROUP;
    /// the batch must ask once, for everything.
    @MainActor
    @Test func aTrashlessBatchRaisesOneConfirmationForAllGroups() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true
        let manager = makeManager(mockFM)
        let asked = LockedBox<[[String]]>([])
        manager.permanentDeleteConfirmer = { names in
            asked.withLock { $0.append(names) }
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
        #expect(Set(invocations.first ?? []) == ["x", "y"],
                "the one dialog must name everything it is about to destroy")
        #expect(mockFM.virtualDisk["/b/x"] == nil)
        #expect(mockFM.virtualDisk["/b/y"] == nil)
        // Permanent deletes poison the undo offer, exactly as before.
        #expect(manager.banner?.message.contains("⌘Z") != true)
        #expect(manager.banner?.isUndoable != true)
    }

    /// **A declined confirmation destroys nothing, anywhere in the batch.** The old code's pin was
    /// a mid-batch `break` (whose deletion passed the suite); the one-call shape's equivalent is
    /// that the decline covers every path the dialog named — nothing is removed after it, nothing
    /// was removed before it, and every group stays listed.
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

    /// A group that drifts while the batch's delete waits in the serialized op queue is refused
    /// at the last check — the phase-1 verdict is minutes old by the time a long queued operation
    /// finishes, and acting on it anyway is exactly the blind batch the checks exist to prevent.
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
        // Group 2's copy is rewritten IN the queue-wait window — after phase 1's verdict.
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

    /// A copy rewritten while the permanent-delete dialog sits open is NOT destroyed on the
    /// pre-dialog verdict. The dialog is user-paced — minutes can pass — and what follows it is
    /// unrecoverable, so the gate re-runs after the confirmation, right before `removeItem`.
    @MainActor
    @Test func aCopyThatDriftsWhileTheConfirmationDialogIsOpenIsNotPermanentlyDeleted() async throws {
        let mockFM = MockFileManager()
        mockFM.shouldFailTrash = true
        let manager = makeManager(mockFM)
        // The dialog IS the drift window: the confirmer rewrites the copy, then confirms.
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

    /// **The keeper is re-walked LAST.** Each candidate walk ages the keeper's verdict; walking
    /// the copy being KEPT last means its "unchanged" reading is the newest at the moment the
    /// caller acts. Pinned structurally — the walk order is the mechanism — because the removal
    /// gate's second pass would mask an order regression from any purely behavioral fixture.
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

    /// The behavioral half of the same rule: content that lands in the keeper while a CANDIDATE
    /// is being walked is seen, because the keeper's walk comes after. (The removal gate's second
    /// pass would also catch this, so the structural pin above is the one that holds the order.)
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
            // A file lands in the KEEPER while the candidate is being verified.
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

    /// Every phase-1 refusal writes a per-group line naming the keeper AND the refused copy's
    /// path, split by wording (drifted vs no-baseline) — refusals used to bump counters and write
    /// nothing, invisible in the log he audits.
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

    /// The mixed-count arm of the all-refused banner — `refused != refusedForMissingBaseline` —
    /// was untested: with one drifted group and one baseline-less group the banner must take the
    /// "changed since they were scanned" wording (a change WAS measured somewhere), not the
    /// "couldn't be fully checked" one.
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
        #expect(!message.contains("couldn't be fully checked"),
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

    /// The gate is consulted when the serialized operation STARTS, with the pruned path list,
    /// and a refused path is left on disk and counted — while the others proceed.
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

    /// After a CONFIRMED permanent delete the gate runs again, over just the paths about to be
    /// destroyed unrecoverably — and a second-pass refusal reaches `removeItem` for nothing.
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

    /// A wholesale gate refusal is the OPPOSITE of "already gone" — the items are on disk,
    /// deliberately kept — so the direct-gesture banner must not claim they had vanished.
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

    // MARK: The snapshot comparison sees kind, not just size

    /// A file that becomes a DIRECTORY at the same relative path (or vice versa) is drift, even
    /// when the sizes line up — the mock walk records every file at size 0, so a comparison
    /// refactored down to sizes alone would call these equal and ship green.
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

        // The control, so the pin cannot pass by refusing everything: the same snapshot against
        // a disk that still holds the FILE matches.
        mockFM.virtualDisk["/r/a"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let control = await FileSyncManager.folderContentsMatchScan(
            path: "/r", snapshot: snapshot, fileManager: mockFM)
        #expect(control == true, "the fixture refuses even the unchanged case, so the assertion above is vacuous")
    }
}
