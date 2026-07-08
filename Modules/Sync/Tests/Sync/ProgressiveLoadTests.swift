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
