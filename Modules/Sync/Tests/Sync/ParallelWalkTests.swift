import Foundation
import Testing
@testable import Sync

/// Pins the parallel deep walk in `buildTree` (sibling subtrees at the top two levels walk
/// concurrently on the real filesystem) and its lean-metadata policy (Finder tags — a
/// per-file xattr fetch that dominated large scans — are read only for the Tags sort).
///
/// Real `FileManager` on temp directories throughout: the fan-out only engages for the real
/// filesystem, and only for levels with more than one entry — so these trees are WIDE, unlike
/// SymlinkCycleTests' single-child chains, which exercise the sequential path.
@Suite struct ParallelWalkTests {

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParallelWalkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = try root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        return URL(fileURLWithPath: canonical ?? root.path)
    }

    /// root/dir_{0..3}/sub_{0..2}/leaf_{0..1}.txt plus files at every level — wide enough
    /// that both fan-out levels take the concurrent branch.
    private func makeWideTree(at root: URL) throws {
        let fm = FileManager.default
        for d in 0..<4 {
            let dir = root.appendingPathComponent("dir_\(d)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "top".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "top".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            for s in 0..<3 {
                let sub = dir.appendingPathComponent("sub_\(s)")
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                for f in 0..<2 {
                    try "leaf".write(to: sub.appendingPathComponent("leaf_\(f).txt"), atomically: true, encoding: .utf8)
                }
            }
        }
    }

    @Test func testParallelWalkBuildsCompleteSortedTree() async throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }
        try makeWideTree(at: root)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        // 4 dirs + 4×(2 files + 3 subs) + 12×2 leaves = 48 nodes, nothing dropped or doubled.
        #expect(FileSyncManager.countItems(in: tree) == 48)
        #expect(tree.map(\.name) == ["dir_0", "dir_1", "dir_2", "dir_3"])
        for dir in tree {
            // Every level is sorted (dirs first, then names) regardless of task completion order.
            #expect(dir.children?.map(\.name) == ["sub_0", "sub_1", "sub_2", "a.txt", "b.txt"])
            for sub in dir.children ?? [] where sub.isDirectory {
                #expect(sub.children?.map(\.name) == ["leaf_0.txt", "leaf_1.txt"])
                for leaf in sub.children ?? [] {
                    // Metadata still populated below the fan-out horizon.
                    #expect(leaf.fileSize == 4)
                    #expect(leaf.modificationDate != nil)
                }
            }
        }
    }

    /// The cycle guard must hold on the concurrent path too: each branch carries its own
    /// ancestor-chain snapshot, so a symlink back to an ancestor is capped exactly once
    /// while its siblings (and an acyclic cousin link) still walk fully.
    @Test func testCycleGuardHoldsThroughParallelBranches() async throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }
        try makeWideTree(at: root)
        // Cycle at depth 2 (inside the fan-out horizon): root/dir_1/sub_1/loop -> root
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("dir_1/sub_1/loop"),
            withDestinationURL: root
        )
        // Acyclic cross-link between branches: root/dir_2/into_dir3 -> root/dir_3 (must expand —
        // dir_3 is NOT an ancestor of dir_2, whatever task walked it first).
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("dir_2/into_dir3"),
            withDestinationURL: root.appendingPathComponent("dir_3")
        )

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        let loop = try #require(
            tree.first { $0.name == "dir_1" }?
                .children?.first { $0.name == "sub_1" }?
                .children?.first { $0.name == "loop" }
        )
        #expect(loop.isDirectory)
        #expect(loop.children == [])
        #expect(loop.isUnexplored == true)

        let crossLink = try #require(tree.first { $0.name == "dir_2" }?.children?.first { $0.name == "into_dir3" })
        #expect(crossLink.isUnexplored != true)
        #expect(crossLink.children?.map(\.name) == ["sub_0", "sub_1", "sub_2", "a.txt", "b.txt"])
    }

    /// Finder tags ride a per-file xattr fetch, so the walk skips them unless the Tags sort
    /// actually reads them (switching to that sort reloads the trees — see sortOption.didSet).
    @Test func testTagsFetchedOnlyForTagsSort() async throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }

        let file = root.appendingPathComponent("tagged.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
        // URLResourceValues.tagNames is settable only on macOS 26+; write the Finder-tags
        // xattr directly (a binary plist of "name\ncolorIndex" strings).
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Red\n6"], format: .binary, options: 0)
        let status = plist.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, $0.count, 0, 0)
        }
        #expect(status == 0)

        let byName = await FileSyncManager.buildTree(url: root, sortOption: .name)
        #expect(byName.first { $0.name == "tagged.txt" }?.tags == nil)
        // Kind stays populated on every walk (the Kind sort re-sorts in memory).
        #expect(byName.first { $0.name == "tagged.txt" }?.kind != nil)

        let byTags = await FileSyncManager.buildTree(url: root, sortOption: .tags)
        #expect(byTags.first { $0.name == "tagged.txt" }?.tags == ["Red"])
    }
}
