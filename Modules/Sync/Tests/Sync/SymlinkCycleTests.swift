import Foundation
import Testing
@testable import Sync

/// Pins the symlink-cycle guard in `buildTree`: symlinked directories are still followed
/// (the panes deliberately display linked content), but a link back into a directory on
/// the current path must not recurse forever (`A/loop -> A` grew the path unboundedly —
/// the pane load never finished and could end in a stack overflow).
///
/// These tests use the real `FileManager` on a temp directory because mock disks cannot
/// contain symlinks — the cycle guard's real-filesystem identity path is what's under test.
@Suite struct SymlinkCycleTests {

    private func occurrences(named target: String, in nodes: [FileNode]) -> Int {
        nodes.reduce(0) { count, node in
            count + (node.name == target ? 1 : 0) + occurrences(named: target, in: node.children ?? [])
        }
    }

    @Test func testBuildTreeTerminatesOnSymlinkCycle() async throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "SymlinkCycleTests")
        defer { try? fm.removeItem(at: root) }

        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "hello".write(to: sub.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        // Cycle back to the walk root: root/sub/loop -> root
        try fm.createSymbolicLink(at: sub.appendingPathComponent("loop"), withDestinationURL: root)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        // The walk terminated (or this test would hang) and each entry appears a bounded
        // number of times: sub, file.txt, and the loop link itself — shown once, unexplored.
        #expect(FileSyncManager.countItems(in: tree) == 3)
        #expect(occurrences(named: "file.txt", in: tree) == 1)
        let loop = try #require(tree.first { $0.name == "sub" }?.children?.first { $0.name == "loop" })
        #expect(loop.isDirectory)
        #expect(loop.children == [])
    }

    @Test func testBuildTreeTerminatesOnSelfLoop() async throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "SymlinkCycleTests")
        defer { try? fm.removeItem(at: root) }

        let dir = root.appendingPathComponent("dir")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Cycle to an ancestor below the root: root/dir/loop -> root/dir
        try fm.createSymbolicLink(at: dir.appendingPathComponent("loop"), withDestinationURL: dir)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        #expect(occurrences(named: "loop", in: tree) == 1)
        #expect(FileSyncManager.countItems(in: tree) == 2)
    }

    /// A cycle-capped directory has empty children by construction, not by observation — the
    /// cache must treat it as a miss (forcing a fresh walk from that path), while a genuinely
    /// empty directory is still served.
    @Test func testSubtreeMissesCycleCappedDirectoryButServesEmptyOnes() async throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "SymlinkCycleTests")
        defer { try? fm.removeItem(at: root) }

        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "hello".write(to: sub.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: sub.appendingPathComponent("loop"), withDestinationURL: root)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        // The capped node still renders as a folder in the pane…
        let loop = try #require(tree.first { $0.name == "sub" }?.children?.first { $0.name == "loop" })
        #expect(loop.isDirectory)
        // …but is a cache MISS, never an authoritative empty deep tree.
        #expect(FileSyncManager.subtree(atPath: sub.appendingPathComponent("loop").path, in: tree) == nil)
        // Genuinely empty and genuinely walked directories are served as before.
        #expect(FileSyncManager.subtree(atPath: root.appendingPathComponent("empty").path, in: tree) == [])
        #expect(FileSyncManager.subtree(atPath: sub.path, in: tree)?.count == 2)
    }

    /// Regression: drilling into a cycle-capped directory served the capped `[]` from the cached
    /// root tree as that folder's deep tree, and the in-memory diff then reported the entire
    /// other side as "Missing" — phantom rows inviting a destructive bulk copy. The drill-down
    /// must fall back to a fresh disk walk (correct from that root: fresh visited set and depth
    /// budget), and the diff must see the real contents.
    @MainActor
    @Test func testDrillIntoCycleCappedDirectoryShowsRealContentsAndNoPhantomRows() async throws {
        let fm = FileManager.default
        let leftRoot = try makeCanonicalTempRoot(prefix: "SymlinkCycleTests")
        let rightRoot = try makeCanonicalTempRoot(prefix: "SymlinkCycleTests")
        defer {
            try? fm.removeItem(at: leftRoot)
            try? fm.removeItem(at: rightRoot)
        }

        // left/sub/{file.txt, loop -> left/sub}; right mirrors what left/sub/loop resolves to.
        let sub = leftRoot.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try "same content".write(to: sub.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: sub.appendingPathComponent("loop"), withDestinationURL: sub)
        try "same content".write(to: rightRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: rightRoot.appendingPathComponent("loop"), withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: sub.appendingPathComponent("file.txt").path)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: rightRoot.appendingPathComponent("file.txt").path)

        let manager = FileSyncManager()
        // Deep-load both panes at their roots (populates the prefetch cache).
        await manager.loadTree(path: leftRoot.path, isLeft: true)
        await manager.loadTree(path: rightRoot.path, isLeft: false)

        // Drill the left pane into the capped directory.
        manager.leftRelativePath = "sub/loop"
        await manager.loadTree(path: leftRoot.path, isLeft: true)

        // The pane shows the linked folder's real contents, not a phantom empty slice.
        #expect(manager.leftTree.map(\.name).contains("file.txt"))

        let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", path: leftRoot.path, type: .iCloud)
        let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", path: rightRoot.path, type: .iCloud)
        await manager.scanDirectories(
            left: left, leftPath: sub.appendingPathComponent("loop").path,
            right: right, rightPath: rightRoot.path
        )

        // Identical content on both sides: no phantom "missing" rows.
        #expect(manager.differences.isEmpty)
    }

    @Test func testAcyclicSymlinkedDirectoryIsStillFollowed() async throws {
        let fm = FileManager.default
        let root = try makeCanonicalTempRoot(prefix: "SymlinkCycleTests")
        defer { try? fm.removeItem(at: root) }

        let data = root.appendingPathComponent("data")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try "x".write(to: data.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        // A sibling link into `data` is not a cycle — its contents must still display.
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: data)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        // Both the real directory and the link expand: inner.txt appears under each.
        #expect(occurrences(named: "inner.txt", in: tree) == 2)
        let link = try #require(tree.first { $0.name == "link" })
        #expect(link.children?.map(\.name) == ["inner.txt"])
    }
}
