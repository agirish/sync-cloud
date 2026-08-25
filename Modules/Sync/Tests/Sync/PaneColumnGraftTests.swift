import Foundation
import Testing
@testable import Sync

/// **Filling in one budgeted-out directory**, which is the half of the node budget that keeps a
/// pane navigable rather than merely fast.
///
/// The budget stops the walk and marks everything past it unexplored; without the graft a column
/// opened on one of those folders would be blank for as long as the pane stayed on that root. These
/// pin the pure half — the replacement itself — because that is where a partial tree can be
/// corrupted rather than merely incomplete.
@Suite struct PaneColumnGraftTests {

    private func dir(_ path: String, children: [FileNode]?, unexplored: Bool = false) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: true,
                 children: children, isUnexplored: unexplored ? true : nil)
    }

    private func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent, isDirectory: false, children: nil)
    }

    private var tree: [FileNode] {
        [dir("/r/a", children: [
            dir("/r/a/deep", children: [], unexplored: true),
            file("/r/a/f.txt")]),
         dir("/r/b", children: [], unexplored: true),
         dir("/r/bc", children: [file("/r/bc/x.txt")]),
         file("/r/top.txt")]
    }

    // MARK: - The replacement

    @Test func theGraftedNodeCarriesItsChildrenAndLosesTheMark() throws {
        let filled = try #require(FileSyncManager.grafting(
            children: [file("/r/b/one.txt")], atPath: "/r/b", into: tree))
        let b = try #require(filled.first { $0.id == "/r/b" })
        #expect(b.children?.map(\.id) == ["/r/b/one.txt"])
        #expect(b.isUnexplored == nil,
                "the grafted node still reads as unexplored, so the column would ask for it again forever")
    }

    /// `nil`, not `false`. The field's own documentation defines nil as "walked", and it is what a
    /// node built by the walk carries — writing `false` would be a second spelling of one fact, and
    /// `isUnexplored == true` checks all over the codebase would pass either way, which is exactly
    /// what makes the drift survivable and therefore likely.
    @Test func theClearedMarkMatchesWhatAWalkedNodeCarries() throws {
        let filled = try #require(FileSyncManager.grafting(children: [], atPath: "/r/b", into: tree))
        let b = try #require(filled.first { $0.id == "/r/b" })
        #expect(b.isUnexplored == nil)
    }

    @Test func aNestedTargetIsFound() throws {
        let filled = try #require(FileSyncManager.grafting(
            children: [file("/r/a/deep/y.txt")], atPath: "/r/a/deep", into: tree))
        let deep = try #require(filled.first { $0.id == "/r/a" }?.children?.first { $0.id == "/r/a/deep" })
        #expect(deep.children?.count == 1)
        #expect(deep.isUnexplored == nil)
    }

    /// Everything the graft did not touch must come back identical — a replacement that rebuilt
    /// siblings would churn `FileNode` identity and make SwiftUI redraw the whole pane.
    @Test func nothingElseInTheTreeChanges() throws {
        let filled = try #require(FileSyncManager.grafting(
            children: [file("/r/b/one.txt")], atPath: "/r/b", into: tree))
        #expect(filled.map(\.id) == tree.map(\.id), "the top level was reordered")
        #expect(filled.first { $0.id == "/r/bc" } == tree.first { $0.id == "/r/bc" })
        #expect(filled.first { $0.id == "/r/a" } == tree.first { $0.id == "/r/a" })
        #expect(filled.first { $0.id == "/r/top.txt" } == tree.first { $0.id == "/r/top.txt" })
    }

    // MARK: - The misses, which are normal rather than exceptional

    /// A `nil` is the race, not a failure: the request is made on the main actor, the listing runs
    /// off it, and the pane can re-root before the answer lands. The caller drops it.
    @Test func aPathThatIsNotInTheTreeReturnsNil() {
        #expect(FileSyncManager.grafting(children: [], atPath: "/r/gone", into: tree) == nil)
        #expect(FileSyncManager.grafting(children: [], atPath: "/elsewhere", into: tree) == nil)
    }

    /// A sibling sharing a name prefix still grafts correctly.
    ///
    /// **This passes with or without the trailing separator on the descent's prefix test**, which
    /// is worth stating because the comment on that separator claimed otherwise until this suite
    /// was mutation-checked. The match is an exact `id ==`, so entering the wrong branch finds
    /// nothing and the right node is reached anyway. Kept as a plain regression test of the
    /// outcome; the separator's actual value is measured below.
    @Test func aSiblingSharingANamePrefixStillGrafts() throws {
        let filled = try #require(FileSyncManager.grafting(
            children: [file("/r/bc/new.txt")], atPath: "/r/bc", into: tree),
            "/r/bc was not found")
        #expect(filled.first { $0.id == "/r/bc" }?.children?.map(\.id) == ["/r/bc/new.txt"])
        #expect(filled.first { $0.id == "/r/b" }?.isUnexplored == true, "the wrong node was grafted")
    }

    /// **What the separator is actually for: not entering the branch at all.**
    ///
    /// `visit` rebuilds every node it walks, so a descent into a prefix-sharing sibling copies that
    /// sibling's entire subtree to find nothing. On the trees this runs against — the ones large
    /// enough to have been budgeted out — that is the per-column-open cost the prefix prune exists
    /// to avoid.
    ///
    /// Measured by buffer identity rather than by a clock, because a timing assertion on a shared
    /// machine is a flake. An untouched node is `return node`, which keeps its children array's
    /// existing storage; a rebuilt one is `.map`, which allocates. The original tree is still alive
    /// in `subject` throughout, so its buffer cannot have been freed and handed back at the same
    /// address — the comparison means what it says.
    @Test func theDescentSkipsSiblingsSharingANamePrefix() throws {
        func storage(_ node: FileNode?) -> UInt? {
            guard let children = node?.children else { return nil }
            return children.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        let subject = [dir("/r/b", children: [file("/r/b/1"), file("/r/b/2"), file("/r/b/3")]),
                       dir("/r/bc", children: [], unexplored: true)]
        let before = storage(subject.first { $0.id == "/r/b" })
        try #require(before != nil, "the sibling has no children array to compare — this measures nothing")

        let filled = try #require(FileSyncManager.grafting(
            children: [file("/r/bc/new")], atPath: "/r/bc", into: subject))

        #expect(storage(filled.first { $0.id == "/r/b" }) == before,
                "/r/b's subtree was rebuilt — the descent entered a sibling that only shares a name prefix")
        #expect(filled.first { $0.id == "/r/bc" }?.children?.count == 1, "the target was not grafted")
    }

    /// A file at the target path is not a directory to fill. This cannot happen from the real call
    /// site — the request comes from a column, which only exists over a directory — but the
    /// function is public and the answer should not be "corrupt the node".
    @Test func aFileAtTheTargetPathIsNotGrafted() {
        #expect(FileSyncManager.grafting(children: [], atPath: "/r/top.txt", into: tree) == nil)
    }

    // MARK: - The guard that decides whether to ask at all

    @Test func onlyAnUnwalkedDirectoryReadsAsUnexplored() {
        #expect(FileSyncManager.isUnexplored(atPath: "/r/b", in: tree))
        #expect(FileSyncManager.isUnexplored(atPath: "/r/a/deep", in: tree))
        #expect(!FileSyncManager.isUnexplored(atPath: "/r/a", in: tree))
        #expect(!FileSyncManager.isUnexplored(atPath: "/r/bc", in: tree),
                "a sibling sharing a name prefix answered for /r/b")
    }

    /// **A genuinely empty folder is not an unread one**, and this is the distinction the whole
    /// budget rests on: `/r/bc` has children and `/r/b` has none, but so would an empty directory
    /// that was walked. Only the mark separates them, and a request for an empty walked folder
    /// would relist it on every render forever.
    @Test func anEmptyWalkedDirectoryIsNotAskedFor() {
        let walkedEmpty = [dir("/r/empty", children: [])]
        #expect(!FileSyncManager.isUnexplored(atPath: "/r/empty", in: walkedEmpty))
    }

    @Test func anAbsentPathIsNotUnexplored() {
        #expect(!FileSyncManager.isUnexplored(atPath: "/r/gone", in: tree))
        #expect(!FileSyncManager.isUnexplored(atPath: "/r/top.txt", in: tree))
    }
}

/// **A deferred listing is identified by the pane that asked, not by the folder alone.**
///
/// Keyed by path only — which is how it shipped — two panes on the SAME source suppress each
/// other. Comparing a folder against itself is an ordinary thing to do here (the log carries
/// "comparing Dropbox and Dropbox"), and in that state the left pane's request made the right's
/// look like a duplicate. The right column then never filled: its `onAppear` had already fired,
/// `isLoading` never changed again, and nothing re-asks.
@Suite struct ColumnGraftKeyTests {

    /// **`makeCanonicalTempRoot`, and nothing else will do.** `buildTree` canonicalises through
    /// `canonicalPathKey`, which gives `/private/var/folders/…`; the temporary directory answers
    /// `/var/folders/…`, and `resolvingSymlinksInPath()` does NOT fix it — that call deliberately
    /// strips `/private`, as `FileDiffEngine`'s own note records. A fixture that gets this wrong
    /// builds a tree whose node ids never match the paths the test asks about, and every assertion
    /// fails for a reason that has nothing to do with the subject. Production is unaffected: the
    /// paths a column asks about come out of the tree itself.
    @MainActor
    private func fixture() throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "graftkey")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("deep/f.txt"))
        return root
    }

    /// The same folder, asked for by both panes, is two requests — and both are honoured.
    @MainActor
    @Test func bothPanesCanAskForTheSameFolder() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("deep").path

        let manager = FileSyncManager()
        // Both panes hold the same shallow tree: `deep` present, unwalked.
        let shallow = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: 1)
        manager.rawLeftTree = shallow
        manager.rawRightTree = shallow
        try #require(FileSyncManager.isUnexplored(atPath: deep, in: manager.rawLeftTree),
                     "the fixture is already walked — this measures nothing")

        manager.loadColumnChildren(atPath: deep, isLeft: true)
        manager.loadColumnChildren(atPath: deep, isLeft: false)
        #expect(manager.columnGraftsInFlightPaths(isLeft: true).contains(deep))
        #expect(manager.columnGraftsInFlightPaths(isLeft: false).contains(deep),
                "the right pane's request was dropped as a duplicate of the left's — its column would never fill")
    }

    /// And a pane's own repeat request is still deduped, which is what the guard is for.
    @MainActor
    @Test func onePaneAskingTwiceIsStillOneRequest() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("deep").path

        let manager = FileSyncManager()
        manager.rawLeftTree = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: 1)
        manager.loadColumnChildren(atPath: deep, isLeft: true)
        manager.loadColumnChildren(atPath: deep, isLeft: true)
        #expect(manager.columnGraftsInFlightPaths(isLeft: true) == [deep])
    }

    /// One pane's in-flight listing is not reported to the other, or the wrong column draws a
    /// spinner over a folder nobody is reading for it.
    @MainActor
    @Test func aPanesInFlightSetIsItsOwn() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("deep").path

        let manager = FileSyncManager()
        manager.rawLeftTree = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: 1)
        manager.loadColumnChildren(atPath: deep, isLeft: true)
        #expect(manager.columnGraftsInFlightPaths(isLeft: false).isEmpty,
                "the right pane sees the left's request and would spin a column it never asked about")
    }
}

/// **That the graft actually lands**, which the pure `grafting` above cannot say.
///
/// `ColumnGraftKeyTests` checks what a request STARTS; this checks what it finishes. Between the
/// two sits everything the pure function is not: the unexplored guard against the raw tree, the
/// re-read after the await, the generation bump that makes the index compare unequal, and the write
/// back into `prefetchedTrees`. Each is a line that can be deleted with every other test still
/// green — the cache write especially, whose whole symptom is that walking out of a folder and back
/// re-blanks the column, one navigation later than anyone is looking.
@Suite struct ColumnGraftLandingTests {

    @MainActor
    private func fixture() throws -> URL {
        let root = try makeCanonicalTempRoot(prefix: "graftland")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("deep"),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("deep/f.txt"))
        return root
    }

    private func node(_ path: String, in tree: [FileNode]) -> FileNode? {
        for node in tree {
            if node.id == path { return node }
            if let hit = self.node(path, in: node.children ?? []) { return hit }
        }
        return nil
    }

    /// The listing lands in the pane's raw tree and clears the mark, so the column can draw it.
    @MainActor
    @Test func theListingReachesThePanesTree() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("deep").path

        let manager = FileSyncManager()
        manager.rawLeftTree = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: 1)
        try #require(FileSyncManager.isUnexplored(atPath: deep, in: manager.rawLeftTree),
                     "the fixture arrived already walked — this measures nothing")
        let generationBefore = manager.rawTreeGeneration

        manager.loadColumnChildren(atPath: deep, isLeft: true)
        await waitUntil("the listing grafts into the pane's tree") {
            self.node(deep, in: manager.rawLeftTree)?.children?.isEmpty == false
        }

        let grafted = try #require(node(deep, in: manager.rawLeftTree))
        #expect(grafted.children?.map(\.name) == ["f.txt"])
        #expect(grafted.isUnexplored == nil, "the folder still reads as unread, so the column says “Can’t be read” over rows it now has")
        #expect(manager.rawTreeGeneration > generationBefore,
                "the index's stamp did not move, so `PaneChildrenIndex` compares equal and the column never re-resolves")
        #expect(manager.columnGraftsInFlightPaths(isLeft: true).isEmpty,
                "the request never cleared — the column spins forever over a folder that is filled")
    }

    /// **And into the cache the next navigation serves from.** `loadTree`'s fast path returns
    /// `prefetchedTrees[focusPath]` without touching disk, so an ungrafted entry there un-does this
    /// the moment the user walks out of the folder and back — silently, and only on the second
    /// visit.
    @MainActor
    @Test func theListingReachesTheCachedTreeToo() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("deep").path

        let manager = FileSyncManager()
        let shallow = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: 1)
        manager.rawLeftTree = shallow
        manager.lastLoadedLeftFocusPath = root.path
        manager.prefetchedTrees[root.path] = shallow

        manager.loadColumnChildren(atPath: deep, isLeft: true)
        await waitUntil("the listing grafts into the pane's tree") {
            self.node(deep, in: manager.rawLeftTree)?.children?.isEmpty == false
        }

        let cached = try #require(manager.prefetchedTrees[root.path],
                                  "the cache entry was dropped rather than updated")
        #expect(node(deep, in: cached)?.children?.map(\.name) == ["f.txt"],
                "the cached tree is still the ungrafted one — walking away and back re-blanks the column")
    }

    /// A folder the walk already read is not re-listed. The call site is a view modifier that fires
    /// for reasons a view cannot see, so this guard is what stops an ordinary column from asking
    /// for its own contents on every appearance.
    @MainActor
    @Test func aWalkedFolderIsNotRelisted() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("deep").path

        let manager = FileSyncManager()
        manager.rawLeftTree = await FileSyncManager.buildTree(url: root, sortOption: .name)
        try #require(!FileSyncManager.isUnexplored(atPath: deep, in: manager.rawLeftTree),
                     "the fixture is unwalked — the guard under test would be right to fire")

        manager.loadColumnChildren(atPath: deep, isLeft: true)
        #expect(manager.columnGraftsInFlightPaths(isLeft: true).isEmpty,
                "a directory the walk already read was queued for a second listing")
    }
}
