import Testing
import Foundation
@testable import Sync

@Suite struct FileSyncManagerTests {

    @MainActor
    @Test func testPruneSelection() async throws {
        let manager = FileSyncManager()
        
        // Setup initial trees
        let node1 = FileNode(id: "/src/file1.txt", name: "file1.txt", isDirectory: false)
        let node2 = FileNode(id: "/src/file2.txt", name: "file2.txt", isDirectory: false)
        manager.leftTree = [node1, node2]
        
        // Select both
        manager.selectedLeftPaths = ["/src/file1.txt", "/src/file2.txt"]
        
        // Simulate removal of file2.txt from tree
        manager.leftTree = [node1]
        
        // Prune
        manager.pruneSelection()
        
        // Verify file2.txt is removed from selection, but file1.txt remains
        #expect(manager.selectedLeftPaths.count == 1)
        #expect(manager.selectedLeftPaths.contains("/src/file1.txt"))
        #expect(!manager.selectedLeftPaths.contains("/src/file2.txt"))
    }
    
    @MainActor
    @Test func testPruneSelectionRecursive() async throws {
        let manager = FileSyncManager()
        
        let subNode = FileNode(id: "/src/folder/sub.txt", name: "sub.txt", isDirectory: false)
        let folderNode = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [subNode])
        manager.leftTree = [folderNode]
        
        manager.selectedLeftPaths = ["/src/folder", "/src/folder/sub.txt"]
        
        // Remove only the subfile
        let emptyFolderNode = FileNode(id: "/src/folder", name: "folder", isDirectory: true, children: [])
        manager.leftTree = [emptyFolderNode]
        
        manager.pruneSelection()
        
        #expect(manager.selectedLeftPaths.count == 1)
        #expect(manager.selectedLeftPaths.contains("/src/folder"))
        #expect(!manager.selectedLeftPaths.contains("/src/folder/sub.txt"))
    }
    
    @MainActor
    @Test func testLoadTreeCancellation() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/file_1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        // The test body runs on the main actor, so `treeTask` cannot start before cancel() below:
        // loadTree begins already-cancelled, and the cancellation must propagate through its
        // inner task and the detached tree walk for the load to be discarded.
        let treeTask = Task { await manager.loadTree(path: "/src", isLeft: true) }

        // Cancel it immediately before it can recursively build
        treeTask.cancel()
        await treeTask.value

        // An uncancelled load of the mock disk would populate file_1.txt; a propagated
        // cancellation discards the (partial) walk and leaves the tree untouched.
        #expect(manager.leftTree.count == 0)
    }

    @MainActor
    @Test func testUndoRegisterTrashItems() async throws {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/delete_me.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        await manager.deleteItems(at: ["/src/delete_me.txt"], fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/src/delete_me.txt"] == nil)
        #expect(mockFM.trashedPaths.count == 1)
        #expect(manager.undoManager?.canUndo == true)
        
        // Execute the registered Undo (restore from trash)
        manager.undoManager?.undo()

        await waitUntil("undo restores the trashed file") { mockFM.virtualDisk["/src/delete_me.txt"] != nil }
        #expect(mockFM.virtualDisk["/src/delete_me.txt"] != nil)
    }
    
    @MainActor
    @Test func testCopyItemUndoStack() async throws {
        let manager = FileSyncManager()
        manager.undoManager = UndoManager()
        let mockFM = MockFileManager()
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/copy_me.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let node = FileNode(id: "/src/copy_me.txt", name: "copy_me.txt", isDirectory: false)
        await manager.copyItems(nodes: [node], toPath: "/dst", fileManager: mockFM)
        
        #expect(mockFM.virtualDisk["/dst/copy_me.txt"] != nil)
        #expect(manager.undoManager?.canUndo == true)
        
        // Perform Undo -> should theoretically move the file to trash (removing it from dst)
        manager.undoManager?.undo()

        await waitUntil("undo removes the copied file") { mockFM.virtualDisk["/dst/copy_me.txt"] == nil }
        // Removed from destination
        #expect(mockFM.virtualDisk["/dst/copy_me.txt"] == nil)
        // Kept in source
        #expect(mockFM.virtualDisk["/src/copy_me.txt"] != nil)

        // Perform Redo -> should put it back
        manager.undoManager?.redo()
        await waitUntil("redo restores the copied file") { mockFM.virtualDisk["/dst/copy_me.txt"] != nil }
        #expect(mockFM.virtualDisk["/dst/copy_me.txt"] != nil)
    }
    
    @MainActor
    @Test func testActiveOperationTracking() async throws {
        let manager = FileSyncManager()
        #expect(manager.activeFileOperationsCount == 0)

        // A long operation that parks until the test has observed it in flight — deterministic,
        // unlike the old sleep pairing that flaked under a loaded parallel test run.
        let release = DispatchSemaphore(value: 0)
        let operationTask = Task {
            await manager.enqueueFileOperation {
                await awaitSignal(release)
            }
        }

        await waitUntil("operation counted in flight") { manager.activeFileOperationsCount == 1 }
        #expect(manager.activeFileOperationsCount == 1)

        release.signal()
        await operationTask.value
        #expect(manager.activeFileOperationsCount == 0)
    }
    
    @MainActor
    @Test func testRetargetPane() async throws {
        let manager = FileSyncManager()
        // Through `focusOn`, not by writing the published paths: a pane's relative path and its
        // history are written together everywhere in production (`focusOn`, `applyTab`,
        // `syncPathsFromHistory`), and `retargetPane` puts both panes' paths back in step with
        // their histories on the way out. A fixture that set only the path would be measuring that
        // re-sync rather than the retarget, and would read as the sibling being re-homed.
        manager.focusOn(relativePath: "some/path", isLeft: true)
        manager.focusOn(relativePath: "other/path", isLeft: false)

        manager.retargetPane(isLeft: true, landing: "")

        #expect(manager.leftRelativePath == "")
        #expect(manager.rightRelativePath == "other/path")
    }
    
    @MainActor
    @Test func testRefreshTreesAndScanCancellation() async throws {
        let manager = FileSyncManager()
        let provider1 = CloudProvider(id: "p1", displayName: "P1", imageName: "", rootPath: "/tmp/p1", type: .iCloud)
        let provider2 = CloudProvider(id: "p2", displayName: "P2", imageName: "", rootPath: "/tmp/p2", type: .iCloud)
        
        // Start a refresh
        let task1 = Task {
            await manager.refreshTreesAndScan(left: provider1, right: provider2)
        }
        
        // Immediately start another one
        let task2 = Task {
            await manager.refreshTreesAndScan(left: provider1, right: provider2)
        }
        
        await task1.value
        await task2.value
        
        // If task1 was correctly cancelled, manager should be in a stable state.
        // We mainly verify it doesn't hang or crash.
        #expect(manager.activeRefreshTask != nil)
    }
    
    /// Every operation handed to `enqueueFileOperation` runs, runs ALONE, and unwinds the active
    /// count — the serialization guarantee every mutation path in the app is built on.
    ///
    /// Deliberately has no timeout. It used to poll for up to 5 real seconds and then assert on
    /// whatever had finished, which made it a race against the wall clock rather than a test of the
    /// queue: the operations need the cooperative pool, so under any CPU load (a concurrent build
    /// is enough) they legitimately do not finish in 5 s and the test reported "1 of 50 completed"
    /// — a starvation symptom dressed up as a correctness failure. Seen twice in one session.
    ///
    /// Awaiting the task handles instead is exact: `enqueueFileOperation` returns only after its
    /// own completion block has decremented the count, so when all 50 handles resolve the final
    /// state is settled and both assertions are deterministic. A genuine deadlock now hangs until
    /// the harness's own timeout, which is the honest signal — the old version turned that same
    /// deadlock into a confusing wrong-number failure.
    @MainActor
    @Test func testConcurrentFileOperationsStress() async throws {
        actor Counter {
            private(set) var completed = 0
            private var inFlight = 0
            /// The most operations ever running at once. `enqueueFileOperation` promises this
            /// never exceeds 1; nothing asserted it before, so the test could pass with the queue
            /// running everything in parallel.
            private(set) var peakInFlight = 0
            func enter() {
                inFlight += 1
                peakInFlight = max(peakInFlight, inFlight)
            }
            func leave() {
                inFlight -= 1
                completed += 1
            }
        }

        let manager = FileSyncManager()
        let operationCount = 50
        let counter = Counter()

        // Spawn all 50 before awaiting any, so they genuinely contend for the queue.
        let tasks = (0..<operationCount).map { _ in
            Task {
                await manager.enqueueFileOperation {
                    await counter.enter()
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms, to widen the overlap window
                    await counter.leave()
                }
            }
        }
        for task in tasks { await task.value }

        let completed = await counter.completed
        let peak = await counter.peakInFlight
        #expect(completed == operationCount)
        #expect(peak == 1, "operations must be serialized; saw \(peak) running at once")
        #expect(manager.activeFileOperationsCount == 0)
    }
    
    @MainActor
    @Test func testCacheInvalidationOnToggle() async throws {
        let manager = FileSyncManager()
        
        // 1. Fill cache
        manager.prefetchedTrees["/src"] = [FileNode(id: "/src/a", name: "a", isDirectory: false)]
        #expect(!manager.prefetchedTrees.isEmpty)
        
        // 2. Toggle hidden files -> should clear cache
        manager.showHiddenFiles = true
        #expect(manager.prefetchedTrees.isEmpty)
        
        // 3. Fill again
        manager.prefetchedTrees["/src"] = [FileNode(id: "/src/a", name: "a", isDirectory: false)]
        #expect(!manager.prefetchedTrees.isEmpty)
        
        // 4. Change sort option -> should clear cache
        manager.sortOption = .size
        #expect(manager.prefetchedTrees.isEmpty)
    }

    @MainActor
    @Test func testScanFailureHandling() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        let provider1 = CloudProvider(id: "p1", displayName: "P1", imageName: "", rootPath: "/tmp/p1", type: .iCloud)
        let provider2 = CloudProvider(id: "p2", displayName: "P2", imageName: "", rootPath: "/tmp/p2", type: .iCloud)
        
        // Simulate a directory that doesn't exist to trigger an error in scanDirectories
        await manager.scanDirectories(left: provider1, leftPath: "/non-existent", right: provider2, rightPath: "/tmp/p2")
        
        #expect(manager.differences.isEmpty)
        #expect(!manager.isScanning)
        #expect(manager.hasScanned) // Successfully completed with []
    }
    
    @MainActor
    @Test(.parksAThread) func testLoadingStateAccuracy() async throws {
        let mockFM = MockFileManager()
        // Deterministic: the walk parks at the gate (no wall-clock delay/sleep pairing to lose
        // under a loaded parallel test run), so "load in flight" stays observable for exactly
        // as long as the test needs.
        let gate = ParkGate()
        mockFM.enumeratorGate = gate
        let manager = FileSyncManager(fileManager: mockFM)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)

        let task = Task { await manager.loadTree(path: "/src", isLeft: true) }

        await awaitSignal(gate.entered)              // the walk is parked inside the load
        #expect(manager.isLoadingLeftTree)

        gate.release.signal()
        await task.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the walk was never actually held in flight")
        #expect(!manager.isLoadingLeftTree)
    }
    
    @MainActor
    @Test func testSyncFileWithCopyAction() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/test.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let diff = FileDifference(
            id: UUID(),
            relativePath: "test.txt",
            leftItemPath: "/src/test.txt",
            rightItemPath: "/dst/test.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing",
            isSyncing: false
        )
        
        // Add to manager so it can find it by ID and mark as syncing
        manager.differences = [diff]
        
        // isMove is false by default
        await manager.syncFile(diff, isMove: false, fileManager: mockFM)
        
        // Should exist in both places (Copied)
        #expect(mockFM.virtualDisk["/src/test.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/test.txt"] != nil)
    }
    
    @MainActor
    @Test func testSyncFileWithMoveAction() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        manager.undoManager = UndoManager()
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        mockFM.virtualDisk["/src/test_move.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let diff = FileDifference(
            id: UUID(),
            relativePath: "test_move.txt",
            leftItemPath: "/src/test_move.txt",
            rightItemPath: "/dst/test_move.txt",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing",
            isSyncing: false
        )
        
        manager.differences = [diff]
        
        // Set isMove to true
        await manager.syncFile(diff, isMove: true, fileManager: mockFM)
        
        // Should exist on right but NOT left (Moved)
        #expect(mockFM.virtualDisk["/src/test_move.txt"] == nil)
        #expect(mockFM.virtualDisk["/dst/test_move.txt"] != nil)

        #expect(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()
        // The undo's file I/O runs on the detached operation queue; poll for its result
        // instead of one fixed sleep, which flaked under a loaded parallel test run.
        for _ in 0..<100 where mockFM.virtualDisk["/src/test_move.txt"] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(mockFM.virtualDisk["/src/test_move.txt"] != nil)
        #expect(mockFM.virtualDisk["/dst/test_move.txt"] == nil)
    }
    
    @MainActor
    @Test func testMockEnumeratorSkipsSubdirectoryDescendants() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/folder"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/folder/child.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        let en = mockFM.enumerator(
            at: URL(fileURLWithPath: "/src"),
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: nil
        )
        
        var paths: [String] = []
        if let en {
            while let next = en.nextObject() as? URL {
                paths.append(next.path)
            }
        }
        
        #expect(paths.contains("/src/folder"))
        #expect(!paths.contains("/src/folder/child.txt"))
    }
}

/// `isHiddenPath` short-circuits on a UTF-8 scan before falling back to the expression it used to
/// be. The scan is only allowed to prove the answer FALSE, so the two must agree everywhere — and
/// the interesting disagreement is not hypothetical: `hasPrefix` compares grapheme clusters under
/// canonical equivalence, so `"." + U+0301` is one cluster that is not `"."`.
@Suite struct HiddenPathScanTests {

    /// The expression `isHiddenPath` carried before the scan was put in front of it. Kept here
    /// rather than referenced so the test still has an independent oracle if the source changes.
    private func originalExpression(_ path: String) -> Bool {
        path.components(separatedBy: "/").contains { $0.hasPrefix(".") }
    }

    /// Every string of length ≤ 5 over the alphabet that can actually distinguish the two —
    /// the separator, the marker, an ordinary scalar, and a combining mark. 1,365 strings, and
    /// the combining mark is the only reason the fallback exists.
    @Test func theScanAgreesWithTheOriginalExpression() {
        let alphabet: [Character] = [".", "/", "a", "\u{0301}"]
        var cases: [String] = []
        func sweep(_ depth: Int, _ prefix: String) {
            cases.append(prefix)
            guard depth > 0 else { return }
            for c in alphabet { sweep(depth - 1, prefix + String(c)) }
        }
        sweep(5, "")
        #expect(cases.count > 1_000, "the sweep collapsed — it is the whole test")

        let disagreeing = cases.filter { FileSyncManager.isHiddenPath($0) != originalExpression($0) }
        #expect(disagreeing.isEmpty,
                "scan and expression disagree on \(disagreeing.count): \(disagreeing.prefix(5))")
    }

    /// The case that makes the fallback load-bearing, stated on its own so a future "simplify"
    /// that deletes the fallback fails HERE with the reason, not only in the sweep above.
    @Test func aDottedComponentCarryingACombiningMarkIsNotHidden() {
        // One grapheme cluster, and it is not "." — so the component does not begin with a dot
        // the way `hasPrefix` counts, even though its first BYTE is one.
        #expect(originalExpression("a/.\u{0301}b") == false)
        #expect(FileSyncManager.isHiddenPath("a/.\u{0301}b") == false,
                "the byte scan answered without deferring to the expression")
    }

    /// The fallback is also what keeps the two hidden-file deciders in one window agreeing.
    /// `filterTree` filters the pane trees on `node.name.hasPrefix(".")` — the same grapheme
    /// comparison the fallback runs — so a byte-only `isHiddenPath` would drop this name from
    /// the difference list while the pane beside it went on listing the file.
    @Test func theDifferenceFilterAndThePaneTreeAgreeOnTheAwkwardName() {
        let awkward = ".\u{0301}b"
        let shown = FileSyncManager.filterTree(
            [FileNode(id: "/l/\(awkward)", name: awkward, isDirectory: false)], showHidden: false)
        #expect(shown.count == 1, "the pane tree shows it")
        #expect(FileSyncManager.isHiddenPath("dir/\(awkward)") == false,
                "so the difference list must not hide it — same window, same name")
    }

    @Test func ordinaryPathsAreClassifiedAsBefore() {
        for (path, expected) in [("", false), (".", true), ("/", false), ("a", false),
                                 (".a", true), ("a/.b", true), ("a/b/.c", true), ("/.a", true),
                                 ("a//b", false), ("a/./b", true), ("a/", false), ("a/.", true),
                                 ("..", true), ("a/..b", true), ("a.b", false),
                                 (".git/config", true), ("Projects/f/file.txt", false)] {
            #expect(FileSyncManager.isHiddenPath(path) == expected, "isHiddenPath(\(path.debugDescription))")
        }
    }
}
