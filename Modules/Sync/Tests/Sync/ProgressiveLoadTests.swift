import Foundation
import Testing
@testable import Sync

/// Pins the progressive-loading behavior: the shallow first-paint pass of `buildTree`
/// and the pruneSelection guard that protects selections while a shallow tree is published.
@Suite struct ProgressiveLoadTests {

    private func makeDisk() throws -> MockFileManager {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/subDir"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/file1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/subDir/file2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        if var subDir = mockFM.virtualDisk["/src/subDir"] {
            subDir.contents = ["file2.txt"]
            mockFM.virtualDisk["/src/subDir"] = subDir
        }
        if var root = mockFM.virtualDisk["/src"] {
            root.contents = ["file1.txt", "subDir"]
            mockFM.virtualDisk["/src"] = root
        }
        return mockFM
    }

    @Test func testDepthCappedBuildReportsDirectoriesWithoutWalkingIntoThem() async throws {
        let mockFM = try makeDisk()

        let shallow = await FileSyncManager.buildTree(
            url: URL(fileURLWithPath: "/src"), sortOption: .name, fileManager: mockFM, maxDepth: 1)

        #expect(shallow.map(\.name).sorted() == ["file1.txt", "subDir"])
        let subDir = try #require(shallow.first { $0.name == "subDir" })
        #expect(subDir.isDirectory)
        // Capped directories are present but unexplored: empty children, not nil.
        #expect(subDir.children == [])
    }

    @Test func testUncappedBuildStillWalksTheWholeTree() async throws {
        let mockFM = try makeDisk()

        let deep = await FileSyncManager.buildTree(
            url: URL(fileURLWithPath: "/src"), sortOption: .name, fileManager: mockFM)

        let subDir = try #require(deep.first { $0.name == "subDir" })
        #expect(subDir.children?.map(\.name) == ["file2.txt"])
    }

    // MARK: Cache-served navigation

    @Test func testSubtreeSlicesTheCachedTreeByPath() {
        let file = FileNode(id: "/src/a/b/file.txt", name: "file.txt", isDirectory: false)
        let b = FileNode(id: "/src/a/b", name: "b", isDirectory: true, children: [file])
        let a = FileNode(id: "/src/a", name: "a", isDirectory: true, children: [b])
        let tree = [a]

        #expect(FileSyncManager.subtree(atPath: "/src/a", in: tree) == [b])
        #expect(FileSyncManager.subtree(atPath: "/src/a/b", in: tree) == [file])
        // Not in the tree, a file, or no tree at all -> no slice.
        #expect(FileSyncManager.subtree(atPath: "/src/missing", in: tree) == nil)
        #expect(FileSyncManager.subtree(atPath: "/src/a/b/file.txt", in: tree) == nil)
        #expect(FileSyncManager.subtree(atPath: "/src/a", in: nil) == nil)
    }

    @MainActor
    @Test func testDrillDownIsServedFromTheCachedRootTree() async throws {
        let mockFM = try makeDisk()
        let manager = FileSyncManager(fileManager: mockFM)

        // Deep load at the root populates the cache.
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftTree.map(\.name).sorted() == ["file1.txt", "subDir"])

        // Mutate the virtual disk: if the drill-down re-walked the disk it would see the
        // change; the cached slice (valid until an operation invalidates it) still has it.
        mockFM.virtualDisk.removeValue(forKey: "/src/subDir/file2.txt")

        manager.leftRelativePath = "subDir"
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftTree.map(\.name) == ["file2.txt"])
        #expect(!manager.isLoadingLeftTree)
    }

    // MARK: Refresh dedup (launch-race empty-pane guard)

    /// The launch bootstrap fires two identical refreshes (the explicit initial one plus the
    /// provider-id onChange that resets navigation). The second must be deduped, not
    /// cancel-and-restart the first — that race could strand a pane's load, leaving it blank
    /// until the user re-navigated.
    @MainActor
    @Test func testConcurrentIdenticalRefreshIsDedupedSoNeitherPaneIsStranded() async throws {
        let mockFM = MockFileManager()
        mockFM.enumeratorDelay = 0.05
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/left"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/right"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/left/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/right/b.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        if var l = mockFM.virtualDisk["/left"] { l.contents = ["a.txt"]; mockFM.virtualDisk["/left"] = l }
        if var r = mockFM.virtualDisk["/right"] { r.contents = ["b.txt"]; mockFM.virtualDisk["/right"] = r }

        let manager = FileSyncManager(fileManager: mockFM)
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder", path: "/left", type: .iCloud)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder", path: "/right", type: .iCloud)

        async let first: Void = manager.refreshTreesAndScan(left: left, right: right)
        try await Task.sleep(nanoseconds: 10_000_000)   // let the first register its key and start loading
        async let second: Void = manager.refreshTreesAndScan(left: left, right: right)
        _ = await (first, second)

        // Deduped: each pane loaded exactly once (the first refresh only, not restarted).
        #expect(manager.leftLoadGeneration == 1)
        #expect(manager.rightLoadGeneration == 1)
        // Neither pane stranded: both populated, spinners down, key released.
        #expect(manager.leftTree.map(\.name) == ["a.txt"])
        #expect(manager.rightTree.map(\.name) == ["b.txt"])
        #expect(!manager.isLoadingLeftTree)
        #expect(!manager.isLoadingRightTree)
        #expect(manager.activeRefreshKey == nil)
    }

    /// Regression: the cleanup at the end of `refreshTreesAndScan` matched on key alone, so a
    /// STALE refresh unwinding late could clear a NEWER same-key refresh's dedupe key while it
    /// still ran — a following duplicate then wasn't deduped and cancel-restarted it, reopening
    /// the strand race the dedupe exists to close. Sequence: A(K1) superseded by B(K2), C(K1)
    /// registers K1 again, A finally unwinds; A must not release C's key.
    @MainActor
    @Test func testStaleRefreshUnwindKeepsNewerSameKeyRefreshDeduped() async throws {
        final class CompletionFlag { var done = false }

        let mockFM = MockFileManager()
        mockFM.enumeratorDelay = 0.1
        // Give K1's left root a subdirectory so C's deep walk takes several enumerator passes —
        // C must still be mid-flight when the stale A unwinds.
        for dir in ["/left", "/left/sub", "/right", "/left2", "/right2"] {
            try mockFM.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
        }
        mockFM.virtualDisk["/left/a.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        if var l = mockFM.virtualDisk["/left"] { l.contents = ["a.txt", "sub"]; mockFM.virtualDisk["/left"] = l }

        let manager = FileSyncManager(fileManager: mockFM)
        let l1 = CloudProvider(id: "L1", displayName: "L1", imageName: "folder", path: "/left", type: .iCloud)
        let r1 = CloudProvider(id: "R1", displayName: "R1", imageName: "folder", path: "/right", type: .iCloud)
        let l2 = CloudProvider(id: "L2", displayName: "L2", imageName: "folder", path: "/left2", type: .iCloud)
        let r2 = CloudProvider(id: "R2", displayName: "R2", imageName: "folder", path: "/right2", type: .iCloud)

        // A (K1) — superseded below while its detached walks are still sleeping.
        let a = Task { await manager.refreshTreesAndScan(left: l1, right: r1) }
        await waitUntil("first refresh becomes active") { manager.activeRefreshKey != nil }

        // B (K2) cancels A; C (K1) cancels B and re-registers A's key.
        let b = Task { await manager.refreshTreesAndScan(left: l2, right: r2) }
        await waitUntil("L2 refresh supersedes") { manager.activeRefreshKey?.leftId == "L2" }
        let flag = CompletionFlag()
        let c = Task {
            await manager.refreshTreesAndScan(left: l1, right: r1)
            flag.done = true
        }
        await waitUntil("L1 refresh re-runs") { manager.activeRefreshKey?.leftId == "L1" }

        // The stale refreshes unwind while C still runs; neither may release C's dedupe key.
        await a.value
        await b.value
        try #require(!flag.done) // C must still be mid-flight for the pin below to mean anything
        #expect(manager.activeRefreshKey != nil)

        // The consequence being pinned: a duplicate-K1 refresh is deduped (returns without
        // loading) instead of cancel-restarting C.
        let generationBefore = manager.leftLoadGeneration
        await manager.refreshTreesAndScan(left: l1, right: r1)
        #expect(manager.leftLoadGeneration == generationBefore)

        await c.value
        #expect(flag.done)
        #expect(manager.activeRefreshKey == nil)
    }

    // MARK: Scan-from-tree equivalence

    @Test func testFilesInfoFromTreeMatchesTheDiskWalk() async throws {
        let mockFM = try makeDisk()
        let url = URL(fileURLWithPath: "/src")

        let walked = try FileDiffEngine.getFilesInDirectory(url, fileManager: mockFM)
        let tree = await FileSyncManager.buildTree(url: url, sortOption: .name, fileManager: mockFM)
        let derived = FileDiffEngine.filesInfo(fromTree: tree, basePath: url.path)

        #expect(Set(derived.keys) == Set(walked.keys))
        for (key, info) in derived {
            #expect(info.isDirectory == walked[key]?.isDirectory, "isDirectory mismatch for \(key)")
        }
    }

    @MainActor
    @Test func testPruneSkipsPanesWhoseTreeIsStillLoading() async throws {
        let manager = FileSyncManager()
        // Mid-load state: published tree is shallow/empty while the deep walk runs.
        manager.leftTree = []
        manager.selectedLeftPaths = ["/src/deep/file.txt"]
        manager.isLoadingLeftTree = true

        manager.pruneSelection()
        // The selection survives — the mid-load tree is not authoritative.
        #expect(manager.selectedLeftPaths == ["/src/deep/file.txt"])

        manager.isLoadingLeftTree = false
        manager.pruneSelection()
        // Once the load settles, pruning applies as before.
        #expect(manager.selectedLeftPaths.isEmpty)
    }
}
