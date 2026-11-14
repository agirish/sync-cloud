import Testing
import Foundation
@testable import Sync

@Suite struct FileSyncManagerTests {

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

        manager.undoManager?.undo()

        await waitUntil("undo restores the trashed file") { mockFM.virtualDisk["/src/delete_me.txt"] != nil }
        #expect(mockFM.virtualDisk["/src/delete_me.txt"] != nil)
    }

    @MainActor
    @Test func testActiveOperationTracking() async throws {
        let manager = FileSyncManager()
        #expect(manager.activeFileOperationsCount == 0)

        // A long operation that parks until the test has observed it in flight, so there is no
        // sleep to lose under a loaded run.
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

    /// Every operation handed to `enqueueFileOperation` runs, runs alone, and unwinds the active
    /// count. No timeout, on purpose: under CPU load a wall-clock poll would report a starved
    /// cooperative pool as a wrong count. Awaiting the task handles is exact, since the enqueue
    /// returns only after the count is decremented; a real deadlock hangs to the harness's timeout.
    @MainActor
    @Test func testConcurrentFileOperationsStress() async throws {
        actor Counter {
            private(set) var completed = 0
            private var inFlight = 0
            /// The most operations ever running at once. `enqueueFileOperation` promises this never
            /// exceeds 1, so a queue running everything in parallel fails here.
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

        manager.prefetchedTrees["/src"] = [FileNode(id: "/src/a", name: "a", isDirectory: false)]
        #expect(!manager.prefetchedTrees.isEmpty)

        // Showing hidden files clears the cache, and so does a sort change.
        manager.showHiddenFiles = true
        #expect(manager.prefetchedTrees.isEmpty)

        manager.prefetchedTrees["/src"] = [FileNode(id: "/src/a", name: "a", isDirectory: false)]
        #expect(!manager.prefetchedTrees.isEmpty)

        manager.sortOption = .size
        #expect(manager.prefetchedTrees.isEmpty)
    }

    @MainActor
    @Test func testScanFailureHandling() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)

        let provider1 = CloudProvider(id: "p1", displayName: "P1", imageName: "", rootPath: "/tmp/p1", type: .iCloud)
        let provider2 = CloudProvider(id: "p2", displayName: "P2", imageName: "", rootPath: "/tmp/p2", type: .iCloud)

        // A left path that doesn't exist.
        await manager.scanDirectories(left: provider1, leftPath: "/non-existent", right: provider2, rightPath: "/tmp/p2")

        #expect(manager.differences.isEmpty)
        #expect(!manager.isScanning)
        #expect(manager.hasScanned) // Successfully completed with []
    }

    @MainActor
    @Test(.parksAThread) func testLoadingStateAccuracy() async throws {
        let mockFM = MockFileManager()
        // Deterministic: the walk parks at the gate, so "load in flight" stays observable for as
        // long as the test needs, with no sleep to lose under a loaded run.
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

        await manager.syncFile(diff, isMove: true, fileManager: mockFM)

        #expect(mockFM.virtualDisk["/src/test_move.txt"] == nil)
        #expect(mockFM.virtualDisk["/dst/test_move.txt"] != nil)

        #expect(manager.undoManager?.canUndo == true)
        manager.undoManager?.undo()
        // The undo's file I/O runs on the detached operation queue.
        await waitUntil("undo moves the file back") { mockFM.virtualDisk["/src/test_move.txt"] != nil }

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

/// `isHiddenPath` short-circuits on a UTF-8 scan before falling back to a `hasPrefix` expression.
/// The scan may only prove the answer false, so the two must agree everywhere, and they can
/// differ: `hasPrefix` compares grapheme clusters under canonical equivalence, so `"." + U+0301`
/// is one cluster that is not `"."`.
@Suite struct HiddenPathScanTests {

    /// The expression the scan short-circuits, copied here rather than referenced so the test
    /// keeps an independent oracle if the source changes.
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

    /// The fallback also keeps the two hidden-file deciders agreeing: `filterTree` uses the same
    /// grapheme `hasPrefix(".")`, so a byte-only `isHiddenPath` would drop this name from the
    /// difference list while the pane beside it went on listing the file.
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
