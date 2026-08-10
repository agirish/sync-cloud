import Foundation
import Testing
@testable import Sync

/// **`buildTree` must never report a directory as empty because one listing API said so.**
///
/// `contentsOfDirectory(at:includingPropertiesForKeys:)` is used to list a directory because it
/// prefetches every child's metadata in one call. It also, on this filesystem, returns an **empty
/// array with no error** for certain ordinary downloaded iCloud directories — measured at 82 of
/// 5,060 directories on a real tree, hiding 401 entries directly and every descendant with them.
/// The path-based call returns their true contents in the same process.
///
/// Nothing about that is visible from inside the walk: no error, no permission failure, just a
/// subtree that quietly is not there. The consumers do notice, eventually and expensively — a
/// folder-memory survey treats a document missing from the tree as deleted and drops its corpus
/// entry for good.
@Suite struct TreeWalkDirectoryListingTests {

    private static func tempRoot(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeWalkListing-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func names(_ nodes: [FileNode]) -> Set<String> { Set(nodes.map(\.name)) }

    private static func find(_ name: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.name == name { return node }
            if let hit = find(name, in: node.children ?? []) { return hit }
        }
        return nil
    }

    /// A genuinely empty directory is still reported as empty — the fallback listing must not
    /// invent children or mark a readable directory unreadable. This is the case the old shortcut
    /// existed to make cheap, and it has to keep working now that every empty listing is confirmed.
    @Test func aGenuinelyEmptyDirectoryStaysEmpty() async throws {
        let root = try Self.tempRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("hollow"),
                                                withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("beside.txt"), atomically: true, encoding: .utf8)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
        let hollow = try #require(Self.find("hollow", in: tree))
        #expect(hollow.isDirectory)
        #expect((hollow.children ?? []).isEmpty)
        // Non-vacuity: the walk really did run and see the sibling.
        #expect(Self.names(tree).contains("beside.txt"))
    }

    /// The case the fallback was originally added for, kept honest: a symlinked directory's
    /// children are still walked. (Here the URL-based call *throws* rather than returning empty,
    /// so this exercises the other way into the same fallback.)
    @Test func aSymlinkedDirectoryStillYieldsItsChildren() async throws {
        let root = try Self.tempRoot("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try "x".write(to: real.appendingPathComponent("sub/deep.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                                   withDestinationURL: real)

        let tree = await FileSyncManager.buildTree(url: root, sortOption: .name)
        let link = try #require(Self.find("link", in: tree))
        #expect(!(link.children ?? []).isEmpty, "the symlinked directory came back with no children")
        #expect(Self.find("deep.txt", in: [link]) != nil, "the walk did not descend through the link")
    }
}
