import Testing
import Foundation
@testable import Sync

/// Pure-logic coverage for the two node-tree utilities that back sorting and selection resolution:
/// `FileSyncManager.sort(nodes:by:)` (comparator tie-breakers + recursion) and
/// `Array<FileNode>.findNodes(at:)` (recursive descent). Both are exercised only indirectly today.
@Suite struct NodeTreeTests {

    private func file(_ name: String, size: Int? = nil, date: Date? = nil, kind: String? = nil) -> FileNode {
        FileNode(id: "/\(name)", name: name, isDirectory: false, children: nil,
                 modificationDate: date, fileSize: size, tags: nil, kind: kind)
    }
    private func dir(_ name: String, children: [FileNode]? = nil) -> FileNode {
        FileNode(id: "/\(name)", name: name, isDirectory: true, children: children)
    }

    // MARK: sort

    @Test func testSortFoldersFirstThenNameAscending() {
        let sorted = FileSyncManager.sort(
            nodes: [file("b.txt"), dir("z_dir"), file("a.txt"), dir("a_dir")], by: .name)
        // Directories precede files regardless of name; within each group, name-ascending.
        #expect(sorted.map(\.name) == ["a_dir", "z_dir", "a.txt", "b.txt"])
    }

    @Test func testSortBySizeDescendingWithNilAsZero() {
        let sorted = FileSyncManager.sort(
            nodes: [file("small", size: 50), file("none"), file("big", size: 100)], by: .size)
        // Largest first; missing size coalesces to 0 and sorts last.
        #expect(sorted.map(\.name) == ["big", "small", "none"])
    }

    @Test func testSortByDateDescendingWithNilAsDistantPast() {
        let base = Date(timeIntervalSince1970: 10_000)
        let sorted = FileSyncManager.sort(
            nodes: [file("mid", date: base), file("none"), file("new", date: base.addingTimeInterval(100))],
            by: .dateModified)
        // Newest first; missing date coalesces to distantPast and sorts last.
        #expect(sorted.map(\.name) == ["new", "mid", "none"])
    }

    @Test func testSortByKindTieBreaksByName() {
        let sorted = FileSyncManager.sort(
            nodes: [file("z", kind: "AAA"), file("m", kind: "BBB"), file("a", kind: "AAA")], by: .kind)
        // Kind ascending; equal kinds fall back to name ascending.
        #expect(sorted.map(\.name) == ["a", "z", "m"])
    }

    @Test func testSortRecursesIntoChildren() {
        let sorted = FileSyncManager.sort(
            nodes: [dir("parent", children: [file("b.txt"), file("a.txt")])], by: .name)
        #expect(sorted.first?.children?.map(\.name) == ["a.txt", "b.txt"])
    }

    // MARK: findNodes

    private func nestedTree() -> [FileNode] {
        // /a (dir) -> /a/b (dir) -> /a/b/c.txt ;  /d.txt
        let deep = FileNode(id: "/a/b/c.txt", name: "c.txt", isDirectory: false)
        let mid = FileNode(id: "/a/b", name: "b", isDirectory: true, children: [deep])
        let top = FileNode(id: "/a", name: "a", isDirectory: true, children: [mid])
        let sibling = FileNode(id: "/d.txt", name: "d.txt", isDirectory: false)
        return [top, sibling]
    }

    @Test func testFindNodesRecursesAcrossDepths() {
        let found = nestedTree().findNodes(at: ["/a/b/c.txt", "/d.txt", "/bogus"])
        // The deep child and the top-level sibling match; the bogus id is ignored.
        #expect(Set(found.map(\.id)) == ["/a/b/c.txt", "/d.txt"])
    }

    @Test func testFindNodesReturnsParentAndDescendant() {
        let found = nestedTree().findNodes(at: ["/a", "/a/b/c.txt"])
        #expect(Set(found.map(\.id)) == ["/a", "/a/b/c.txt"])
    }

    @Test func testFindNodesEmptyAndNoMatch() {
        #expect(nestedTree().findNodes(at: []).isEmpty)
        #expect(nestedTree().findNodes(at: ["/nope"]).isEmpty)
    }

    /// The early-exit optimization must not reorder results: matches come back in pre-order
    /// (parent before sibling) regardless of the query set's order, and every requested match is
    /// present even when the last one is found before the walk would otherwise finish.
    @Test func testFindNodesReturnsMatchesInPreOrder() {
        let found = nestedTree().findNodes(at: ["/d.txt", "/a"])
        #expect(found.map(\.id) == ["/a", "/d.txt"])
    }

    /// Once every requested path is matched the walk stops, so a trailing node whose id was
    /// already satisfied is not appended — this is the one observable effect of the early exit.
    @Test func testFindNodesStopsAfterAllRequestedPathsMatched() {
        // Two nodes share id "/x"; asking only for "/x" returns the first and skips the trailing dup.
        let tree = [
            FileNode(id: "/x", name: "x", isDirectory: false),
            FileNode(id: "/y", name: "y", isDirectory: false),
            FileNode(id: "/x", name: "x", isDirectory: false),
        ]
        #expect(tree.findNodes(at: ["/x"]).map(\.id) == ["/x"])
    }

    /// The exit is keyed on distinct requested paths, not the match count, so a duplicate id can't
    /// satisfy it early and skip a still-unmatched path. The dup "/a" sits before "/b"; a
    /// count-based exit would stop at two "/a" matches and drop "/b" — this pins that it does not.
    @Test func testFindNodesDuplicateIdDoesNotDropAnotherRequestedPath() {
        let tree = [
            FileNode(id: "/a", name: "a", isDirectory: false),
            FileNode(id: "/a", name: "a", isDirectory: false),
            FileNode(id: "/b", name: "b", isDirectory: false),
        ]
        let found = tree.findNodes(at: ["/a", "/b"])
        // Both "/a" occurrences (they precede the last-needed match) and "/b" are all present.
        #expect(found.map(\.id) == ["/a", "/a", "/b"])
    }

    // MARK: pruneNestedNodes

    @Test func testPruneNestedNodesKeepsOnlyHighestParents() {
        // Distinct id lengths, so the length-sorted output order is deterministic.
        let parent = FileNode(id: "/a", name: "a", isDirectory: true)
        let child = FileNode(id: "/a/b", name: "b", isDirectory: true)
        let sibling = FileNode(id: "/sibling", name: "sibling", isDirectory: true)
        let grandchild = FileNode(id: "/a/b/c.txt", name: "c.txt", isDirectory: false)

        let pruned = [grandchild, sibling, child, parent].pruneNestedNodes()
        // Descendants of an accepted parent are dropped; survivors come out shortest-path first.
        #expect(pruned.map(\.id) == ["/a", "/sibling"])
    }

    @Test func testPruneNestedNodesKeepsStringPrefixSiblings() {
        // "/a/bc" starts with "/a/b" as a string but is NOT inside the "/a/b" directory.
        let dir = FileNode(id: "/a/b", name: "b", isDirectory: true)
        let lookalike = FileNode(id: "/a/bc", name: "bc", isDirectory: true)

        let pruned = [lookalike, dir].pruneNestedNodes()
        #expect(pruned.map(\.id) == ["/a/b", "/a/bc"])
    }

    @Test func testPruneNestedNodesKeepsDuplicateIds() {
        // A node is not "nested inside" an identical id; duplicates both survive.
        let one = FileNode(id: "/a/dup", name: "dup", isDirectory: false)
        let two = FileNode(id: "/a/dup", name: "dup", isDirectory: false)

        let pruned = [one, two].pruneNestedNodes()
        #expect(pruned.map(\.id) == ["/a/dup", "/a/dup"])
    }

    // MARK: Coding stability

    /// FileNode is Codable; JSON encoded before `isUnexplored` existed must still decode
    /// (the field is optional, nil = walked).
    @Test func testDecodesPayloadWithoutUnexploredField() throws {
        let legacy = Data(#"{"id":"/a/dir","name":"dir","isDirectory":true,"children":[]}"#.utf8)
        let node = try JSONDecoder().decode(FileNode.self, from: legacy)
        #expect(node.id == "/a/dir")
        #expect(node.isDirectory)
        #expect(node.isUnexplored == nil)

        // Round trip: a walked node stays free of the field on the wire.
        let reencoded = try JSONEncoder().encode(node)
        #expect(!String(decoding: reencoded, as: UTF8.self).contains("isUnexplored"))
    }
}
