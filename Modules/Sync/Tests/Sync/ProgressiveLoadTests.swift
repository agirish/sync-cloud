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
