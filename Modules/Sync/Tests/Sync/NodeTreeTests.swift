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
}
