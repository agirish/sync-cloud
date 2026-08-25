import Testing
import Foundation
import Events
@testable import Sync

/// `PaneChildrenIndex` exists to keep a column stack off a recursive tree walk — the shape that
/// froze the main thread for 17 s before `PaneTree` flattened it. Two properties matter:
///
///   - it answers `children(atPath:)` for *any* directory, including the tree root and empty
///     folders, because a column that can't resolve its folder renders nothing;
///   - it compares by publish stamp, never by contents, so holding one in a view cannot
///     reintroduce a deep compare.
@Suite struct PaneChildrenIndexTests {

    private let root = "/r"

    private func tree(version: Int = 1, side: PaneTree.Side = .left) -> PaneTree {
        let invoices = FileNode(id: "/r/Documents/Invoices", name: "Invoices", isDirectory: true,
                                children: [FileNode(id: "/r/Documents/Invoices/a.pdf", name: "a.pdf", isDirectory: false)])
        let notes = FileNode(id: "/r/Documents/Notes.md", name: "Notes.md", isDirectory: false)
        let documents = FileNode(id: "/r/Documents", name: "Documents", isDirectory: true, children: [invoices, notes])
        let photos = FileNode(id: "/r/Photos", name: "Photos", isDirectory: true, children: [])
        return PaneTree(side: side, version: version, nodes: [documents, photos])
    }

    private func index() -> PaneChildrenIndex {
        PaneChildrenIndex(tree: tree(), treeRoot: root)
    }

    /// The root column: the pane's own top-level rows, reachable by the root's absolute path so
    /// the column code needs no special case for depth 0.
    @Test func testRootPathAnswersWithTheTopLevelRows() throws {
        let rows = try #require(index().children(atPath: root))
        #expect(rows.map(\.info.name) == ["Documents", "Photos"])
    }

    @Test func testNestedDirectoriesResolveByAbsolutePath() throws {
        let documents = try #require(index().children(atPath: "/r/Documents"))
        #expect(documents.map(\.info.name) == ["Invoices", "Notes.md"])

        let invoices = try #require(index().children(atPath: "/r/Documents/Invoices"))
        #expect(invoices.map(\.info.name) == ["a.pdf"])
    }

    /// An empty folder resolves to an empty column, which is different from not resolving at all —
    /// the first shows "Empty", the second means the folder is gone and triggers a prune.
    @Test func testEmptyDirectoryResolvesToAnEmptyColumn() throws {
        let photos = try #require(index().children(atPath: "/r/Photos"))
        #expect(photos.isEmpty)
        #expect(index().isDirectory(atPath: "/r/Photos"))
    }

    @Test func testFilesAndUnknownPathsDoNotResolve() {
        #expect(index().children(atPath: "/r/Documents/Notes.md") == nil)
        #expect(index().isDirectory(atPath: "/r/Documents/Notes.md") == false)
        #expect(index().children(atPath: "/r/Nope") == nil)
        #expect(index().isDirectory(atPath: "/r/Nope") == false)
    }

    @Test func testTrailingSlashesAreToleratedOnLookup() {
        #expect(index().isDirectory(atPath: "/r/Documents/"))
        #expect(index().children(atPath: "/r/")?.count == 2)
    }

    /// A directory whose children arrived as `nil` must still read as a directory. If it didn't,
    /// `PaneBrowsePath.pruned` would treat it as deleted and walk the user out of a real folder.
    @Test func testDirectoryWithNilChildrenStillReadsAsADirectory() {
        let bare = FileNode(id: "/r/Bare", name: "Bare", isDirectory: true, children: nil)
        let idx = PaneChildrenIndex(tree: PaneTree(side: .left, version: 1, nodes: [bare]), treeRoot: root)
        #expect(idx.isDirectory(atPath: "/r/Bare"))
        #expect(idx.children(atPath: "/r/Bare")?.isEmpty == true)
        // And it survives a prune rather than being mistaken for a deleted folder.
        #expect(PaneBrowsePath(components: ["Bare"]).pruned(against: idx, treeRoot: root).components == ["Bare"])
    }

    // MARK: - Equality is the stamp, not the contents

    @Test func testEqualStampAndRootCompareEqual() {
        #expect(PaneChildrenIndex(tree: tree(version: 3), treeRoot: root)
                == PaneChildrenIndex(tree: tree(version: 3), treeRoot: root))
    }

    @Test func testAnyPublishOrRerootMakesItUnequal() {
        let base = PaneChildrenIndex(tree: tree(version: 3), treeRoot: root)
        #expect(base != PaneChildrenIndex(tree: tree(version: 4), treeRoot: root))
        #expect(base != PaneChildrenIndex(tree: tree(version: 3, side: .right), treeRoot: root))
        // Re-rooting the pane changes what the index means even at the same stamp.
        #expect(base != PaneChildrenIndex(tree: tree(version: 3), treeRoot: "/r/Documents"))
    }

    /// The root is normalised at build time as well as at lookup, so two spellings of the same
    /// root don't produce two indexes that compare unequal and re-render the pane forever.
    @Test func testRootIsNormalisedForEquality() {
        #expect(PaneChildrenIndex(tree: tree(), treeRoot: "/r")
                == PaneChildrenIndex(tree: tree(), treeRoot: "/r/"))
    }
}

/// **The fact the children map cannot express.**
///
/// `childrenByPath` gives `[]` both for a folder with nothing in it and for one the walk reported
/// without reading — so a column reading only that map has to guess, and it guessed "Empty". That
/// is a claim the walk never made: `FileSyncManager` logs the same distinction from the other side
/// ("shown as unexplored, not empty").
@Suite struct PaneChildrenIndexUnexploredTests {

    private func node(_ path: String, isDirectory: Bool = true,
                      children: [FileNode]? = [], unexplored: Bool? = nil) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory,
                 children: children, isUnexplored: unexplored)
    }

    private func index(_ nodes: [FileNode], root: String = "/r") -> PaneChildrenIndex {
        PaneChildrenIndex(tree: PaneTree(side: .left, version: 1, nodes: nodes), treeRoot: root)
    }

    /// A directory the walk reported but did not read is flagged.
    @Test func anUnexploredDirectoryIsFlagged() {
        let idx = index([node("/r/held", unexplored: true)])
        #expect(idx.isUnexplored(atPath: "/r/held"))
    }

    /// **And one that is genuinely empty is not** — the whole point of keeping the two apart. Both
    /// answer `[]` from the children map, which is why that map could not be the source of truth.
    @Test func aGenuinelyEmptyDirectoryIsNotFlagged() {
        let idx = index([node("/r/empty", children: [])])
        #expect(!idx.isUnexplored(atPath: "/r/empty"))
        #expect(idx.children(atPath: "/r/empty")?.isEmpty == true,
                "the two states must still be indistinguishable in the children map — otherwise this flag is not what fixes it")
    }

    /// A populated directory is not flagged either.
    @Test func aPopulatedDirectoryIsNotFlagged() {
        let idx = index([node("/r/full", children: [node("/r/full/a", isDirectory: false, children: nil)])])
        #expect(!idx.isUnexplored(atPath: "/r/full"))
    }

    /// The flag is found at any depth, not only among the top-level rows — a column can be opened
    /// several levels down, which is exactly where the caption shows.
    @Test func anUnexploredDirectoryIsFoundAtDepth() {
        let deep = node("/r/a/b/c", unexplored: true)
        let idx = index([node("/r/a", children: [node("/r/a/b", children: [deep])])])
        #expect(idx.isUnexplored(atPath: "/r/a/b/c"))
        #expect(!idx.isUnexplored(atPath: "/r/a/b"))
    }

    /// **A path this index has never heard of is not a claim that a folder went unread.** False is
    /// the safe direction: the caption falls back to whatever the rows say.
    @Test func anUnknownPathIsNotFlagged() {
        #expect(!index([node("/r/a")]).isUnexplored(atPath: "/r/nowhere"))
        #expect(!index([node("/r/a")]).isUnexplored(atPath: ""))
    }

    /// Paths are normalised on the way in and on the way out, so a trailing slash asks the same
    /// question — the same rule `children(atPath:)` already follows.
    @Test func theLookupNormalisesItsPath() {
        let idx = index([node("/r/held", unexplored: true)])
        #expect(idx.isUnexplored(atPath: "/r/held/"))
    }
}
