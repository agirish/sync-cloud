import Testing
import Foundation
@testable import Sync

@Suite struct StatsAccuracyTests {
    
    @MainActor
    @Test func testItemCountsWithNesting() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        // /src/file1.txt, /src/subDir and /src/subDir/file2.txt.
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/file1.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src/subDir"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/subDir/file2.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        await manager.loadTree(path: "/src", isLeft: true)
        
        // file1.txt, subDir and subDir/file2.txt: 3 items, not counting the root.
        
        #expect(manager.leftItemCount == 3)
    }
    
    @MainActor
    @Test func testDifferenceCountAccuracy() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", rootPath: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", rootPath: "/dst", type: .iCloud)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        
        // 1 missing in destination
        mockFM.virtualDisk["/src/only_in_src.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // 1 different (modification date)
        let now = Date()
        let later = now.addingTimeInterval(3600)
        mockFM.virtualDisk["/src/diff_date.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now], contents: nil)
        mockFM.virtualDisk["/dst/diff_date.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: later], contents: nil)
        
        // 1 same
        mockFM.virtualDisk["/src/same.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now], contents: nil)
        mockFM.virtualDisk["/dst/same.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: [.modificationDate: now], contents: nil)
        
        await manager.scanDirectories(left: srcProvider, leftPath: "/src", right: dstProvider, rightPath: "/dst")
        
        // Two differences: the missing file and the date difference.
        #expect(manager.differences.count == 2)
    }
    
    @MainActor
    @Test func testHiddenFilesStatsToggle() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/.hidden"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        mockFM.virtualDisk["/src/visible.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        
        // 1. Default (Hidden files skipped)
        manager.showHiddenFiles = false
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftItemCount == 1)
        
        // 2. Show Hidden enabled
        manager.showHiddenFiles = true
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftItemCount == 2)
    }
    
    @MainActor
    @Test func testEmptyDirectoryStats() async throws {
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)
        
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        
        await manager.loadTree(path: "/src", isLeft: true)

        #expect(manager.leftItemCount == 0)
        #expect(manager.leftTree.isEmpty)
    }

    @MainActor
    @Test func testRealFilesystemTreeBuild() async throws {
        // The real-FileManager `buildNode` path (existence and type from resource values), which
        // the mock-based tests don't cover. Mirrors testItemCountsWithNesting on disk.
        let manager = FileSyncManager() // real FileManager
        let fm = FileManager.default

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncCloudTreeTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // /root/file1.txt, /root/subDir, /root/subDir/file2.txt -> 3 items
        try Data("hello".utf8).write(to: root.appendingPathComponent("file1.txt"))
        let subDir = root.appendingPathComponent("subDir")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("world".utf8).write(to: subDir.appendingPathComponent("file2.txt"))

        await manager.loadTree(path: root.path, isLeft: true)

        #expect(manager.leftItemCount == 3)

        // isDirectory must come from the resource values.
        let byName = Dictionary(uniqueKeysWithValues: manager.rawLeftTree.map { ($0.name, $0.isDirectory) })
        #expect(byName["file1.txt"] == false)
        #expect(byName["subDir"] == true)
    }

    @MainActor
    @Test func testRealFilesystemSymlinkHandling() async throws {
        // On the real filesystem a symlink to a directory is treated as a directory and recursed
        // into, while a broken symlink is dropped.
        let manager = FileSyncManager() // real FileManager
        let fm = FileManager.default

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncCloudSymlinkTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let realDir = root.appendingPathComponent("realDir")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: realDir.appendingPathComponent("inner.txt"))

        // Symlink -> directory, and a broken symlink -> nonexistent target.
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkToDir"), withDestinationURL: realDir)
        try fm.createSymbolicLink(at: root.appendingPathComponent("broken"),
                                  withDestinationURL: root.appendingPathComponent("does-not-exist"))

        await manager.loadTree(path: root.path, isLeft: true)

        let top = Dictionary(uniqueKeysWithValues: manager.rawLeftTree.map { ($0.name, $0) })
        // Symlinked directory is treated as a directory and recurses into the target's contents.
        #expect(top["linkToDir"]?.isDirectory == true)
        #expect(top["linkToDir"]?.children?.contains { $0.name == "inner.txt" } == true)
        // Broken symlink is dropped.
        #expect(top["broken"] == nil)
    }

    @MainActor
    @Test func testRealFilesystemSymlinkToFile() async throws {
        // Complements testRealFilesystemSymlinkHandling: a symlink to a regular file survives as a
        // non-directory leaf through the symlink fallback.
        let manager = FileSyncManager() // real FileManager
        let fm = FileManager.default

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncCloudSymlinkFileTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("payload".utf8).write(to: root.appendingPathComponent("realFile.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkToFile"),
                                  withDestinationURL: root.appendingPathComponent("realFile.txt"))

        await manager.loadTree(path: root.path, isLeft: true)

        let top = Dictionary(uniqueKeysWithValues: manager.rawLeftTree.map { ($0.name, $0) })
        // Symlink to a file is present and treated as a leaf, not a directory.
        #expect(top["linkToFile"] != nil)
        #expect(top["linkToFile"]?.isDirectory == false)
        #expect(top["linkToFile"]?.children == nil)
    }

    @MainActor
    @Test func testRealFilesystemEmptyAndSymlinkedEmptyDirectories() async throws {
        // The empty-listing fallback in childURLs re-lists only when the entry is a symlink, so an
        // empty directory and a symlink to one must both come back as directories with no children.
        let manager = FileSyncManager() // real FileManager
        let fm = FileManager.default

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncCloudEmptyDirTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let emptyDir = root.appendingPathComponent("emptyDir")
        try fm.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkToEmptyDir"),
                                  withDestinationURL: emptyDir)

        await manager.loadTree(path: root.path, isLeft: true)

        let top = Dictionary(uniqueKeysWithValues: manager.rawLeftTree.map { ($0.name, $0) })
        #expect(top["emptyDir"]?.isDirectory == true)
        #expect(top["emptyDir"]?.children?.isEmpty == true)
        #expect(top["linkToEmptyDir"]?.isDirectory == true)
        #expect(top["linkToEmptyDir"]?.children?.isEmpty == true)
    }

    @MainActor
    @Test func testRealFilesystemMetadataPopulated() async throws {
        // Size and date come from the same resource-values stat as existence and type.
        // testRealFilesystemTreeBuild checks only count and isDirectory, so this pins that fileSize
        // and modificationDate are populated on the real-filesystem path.
        let manager = FileSyncManager() // real FileManager
        let fm = FileManager.default

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SyncCloudMetaTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let payload = Data("hello world".utf8) // 11 bytes
        try payload.write(to: root.appendingPathComponent("sized.txt"))

        await manager.loadTree(path: root.path, isLeft: true)

        let node = manager.rawLeftTree.first { $0.name == "sized.txt" }
        #expect(node?.fileSize == payload.count)
        #expect(node?.modificationDate != nil)
    }

    @MainActor
    @Test func testDiffReflectsFreshDiskState() async throws {
        // A file added after the left tree was loaded still surfaces in the next scan. Only the
        // left side is cached here, so the scan walks the disk rather than the stale tree (a warm
        // scan needs both sides cached).
        let mockFM = MockFileManager()
        let manager = FileSyncManager(fileManager: mockFM)

        let srcProvider = CloudProvider(id: "src", displayName: "Source", imageName: "folder", rootPath: "/src", type: .iCloud)
        let dstProvider = CloudProvider(id: "dst", displayName: "Dest", imageName: "folder", rootPath: "/dst", type: .iCloud)

        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)

        // Cache an (empty) tree for /src.
        await manager.loadTree(path: "/src", isLeft: true)
        #expect(manager.leftItemCount == 0)

        // Add a file only after the tree cache was populated — the cache is now stale.
        mockFM.virtualDisk["/src/added_after_cache.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        await manager.scanDirectories(left: srcProvider, leftPath: "/src", right: dstProvider, rightPath: "/dst")

        // The scan reads fresh disk state, so the post-cache file is detected as a difference even
        // though the cached tree (leftItemCount) still shows zero.
        #expect(manager.differences.count == 1)
        #expect(manager.leftItemCount == 0)
    }
}
