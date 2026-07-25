import Testing
import Foundation
@testable import Sync

/// `FileSyncManager.leftNodes(for:)` / `rightNodes(for:)` — the cached path→node index the pane
/// action bar resolves its selection through.
///
/// This is not a cosmetic cache. The nodes it returns are what Delete, Copy and Move are handed, so
/// a stale entry means a destructive action running against a file that is no longer at that path.
/// The invalidation rides `publishedLeftTreeVersion`, bumped in `leftTree`'s `didSet` — these tests
/// pin that contract from the outside, so a future tree-writing path that forgets to go through the
/// published property fails here rather than in someone's Dropbox.
@MainActor
@Suite struct SelectionNodeIndexTests {

    private func file(_ path: String, size: Int = 10) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false, fileSize: size)
    }

    private func dir(_ path: String, _ children: [FileNode]) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true, children: children)
    }

    /// /a/b/c.txt, /a/d.txt, /e.txt — nesting deep enough that a flat scan would miss the leaves.
    private func tree() -> [FileNode] {
        [dir("/a", [dir("/a/b", [file("/a/b/c.txt")]), file("/a/d.txt")]), file("/e.txt")]
    }

    // MARK: Resolution

    @Test func testResolvesNestedPathsAtEveryDepth() {
        let m = FileSyncManager()
        m.leftTree = tree()
        let ids = Set(m.leftNodes(for: ["/a/b/c.txt", "/a/d.txt", "/e.txt", "/a"]).map(\.id))
        #expect(ids == ["/a/b/c.txt", "/a/d.txt", "/e.txt", "/a"])
    }

    /// The documented contract: a path no longer in the tree is DROPPED, matching `findNodes`. The
    /// action bar must never be handed a fabricated node for a file that has gone away.
    @Test func testStalePathIsDroppedNotFabricated() {
        let m = FileSyncManager()
        m.leftTree = tree()
        #expect(m.leftNodes(for: ["/e.txt", "/gone.txt"]).map(\.id) == ["/e.txt"])
        #expect(m.leftNodes(for: ["/gone.txt"]).isEmpty)
        #expect(m.leftNodes(for: []).isEmpty)
    }

    /// Agreement with the tree walk it replaced — the whole premise of swapping in the index.
    @Test func testMatchesFindNodesForTheSameSelection() {
        let m = FileSyncManager()
        m.leftTree = tree()
        let paths: Set<String> = ["/a/b/c.txt", "/e.txt", "/nope"]
        #expect(Set(m.leftNodes(for: paths).map(\.id)) == Set(m.leftTree.findNodes(at: paths).map(\.id)))
    }

    // MARK: Invalidation — the part that matters

    /// THE regression this suite exists for. Resolve once (populating the cache), replace the tree,
    /// then resolve again: the second answer must come from the NEW tree. A cache keyed on
    /// something that stops changing would keep returning the old node here.
    @Test func testCacheInvalidatesWhenTheTreeIsReplaced() {
        let m = FileSyncManager()
        m.leftTree = [file("/old.txt", size: 1)]
        #expect(m.leftNodes(for: ["/old.txt"]).map(\.id) == ["/old.txt"])

        m.leftTree = [file("/new.txt", size: 2)]
        #expect(m.leftNodes(for: ["/old.txt"]).isEmpty, "stale path resolved after the tree changed")
        #expect(m.leftNodes(for: ["/new.txt"]).map(\.id) == ["/new.txt"])
    }

    /// Same path, different node: a rescan that changes a file's metadata in place must not keep
    /// serving the pre-scan node. Size stands in for "everything the action bar reads off the node".
    @Test func testSamePathPicksUpTheRebuiltNode() {
        let m = FileSyncManager()
        m.leftTree = [file("/f.txt", size: 100)]
        #expect(m.leftNodes(for: ["/f.txt"]).first?.fileSize == 100)

        m.leftTree = [file("/f.txt", size: 999)]
        #expect(m.leftNodes(for: ["/f.txt"]).first?.fileSize == 999)
    }

    /// Mutating a nested child re-assigns the tree (FileNode is a value type), so the version bumps
    /// and the index rebuilds — pinned because it is exactly the assumption that would break if
    /// `FileNode` ever became a reference type.
    @Test func testNestedMutationInvalidatesTheIndex() {
        let m = FileSyncManager()
        m.leftTree = tree()
        #expect(m.leftNodes(for: ["/a/b/c.txt"]).count == 1)

        m.leftTree = [dir("/a", [dir("/a/b", [])]), file("/e.txt")]
        #expect(m.leftNodes(for: ["/a/b/c.txt"]).isEmpty)
    }

    /// The two panes keep independent caches: rebuilding one must not serve the other's nodes, and
    /// a left-tree change must not silently invalidate (or preserve) the right.
    @Test func testLeftAndRightIndexesAreIndependent() {
        let m = FileSyncManager()
        m.leftTree = [file("/left.txt")]
        m.rightTree = [file("/right.txt")]

        #expect(m.leftNodes(for: ["/left.txt"]).map(\.id) == ["/left.txt"])
        #expect(m.leftNodes(for: ["/right.txt"]).isEmpty)
        #expect(m.rightNodes(for: ["/right.txt"]).map(\.id) == ["/right.txt"])
        #expect(m.rightNodes(for: ["/left.txt"]).isEmpty)

        m.leftTree = [file("/left2.txt")]
        #expect(m.rightNodes(for: ["/right.txt"]).map(\.id) == ["/right.txt"],
                "a left-tree change disturbed the right index")
    }

    /// Repeated resolution is stable (the cache is a cache, not a one-shot).
    @Test func testRepeatedResolutionIsStable() {
        let m = FileSyncManager()
        m.leftTree = tree()
        let first = Set(m.leftNodes(for: ["/a/d.txt", "/e.txt"]).map(\.id))
        for _ in 0..<5 {
            #expect(Set(m.leftNodes(for: ["/a/d.txt", "/e.txt"]).map(\.id)) == first)
        }
    }
}
