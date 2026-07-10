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

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SymlinkCycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func occurrences(named target: String, in nodes: [FileNode]) -> Int {
        nodes.reduce(0) { count, node in
            count + (node.name == target ? 1 : 0) + occurrences(named: target, in: node.children ?? [])
        }
    }

    @Test func testBuildTreeTerminatesOnSymlinkCycle() async throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
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
        let root = try makeTempRoot()
        defer { try? fm.removeItem(at: root) }

        let dir = root.appendingPathComponent("dir")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Cycle to an ancestor below the root: root/dir/loop -> root/dir
        try fm.createSymbolicLink(at: dir.appendingPathComponent("loop"), withDestinationURL: dir)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)

        #expect(occurrences(named: "loop", in: tree) == 1)
        #expect(FileSyncManager.countItems(in: tree) == 2)
    }

    @Test func testAcyclicSymlinkedDirectoryIsStillFollowed() async throws {
        let fm = FileManager.default
        let root = try makeTempRoot()
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
