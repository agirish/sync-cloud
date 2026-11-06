import Foundation
import Testing
@testable import Sync

/// Columns below a folder link, under a root spelled through one, and above iCloud Drive's
/// container. A column's directory is composed from the tree root and the names clicked
/// (`PaneBrowsePath.columnDirectories`), but `contentsOfDirectory(at:)` returns symlink-resolved
/// URLs: ids go real two levels below a folder link, everywhere under a root spelled through one
/// (`/var/…` lists `/private/var/…`), and above the container. Looked up by composed path, such a
/// column misses, and the next republish prunes the stack back to the last column that answered.
///
/// Real temp-dir fixtures and the manager's own walk: the spellings are the filesystem's, and a
/// hand-built tree would only restate the assumption under test.
@Suite struct ColumnsBelowALinkTests {

    /// `R` holds an ordinary branch and `link → Target`, with `Target` outside `R`; `other` is the
    /// right pane, empty.
    ///
    ///     R/plain/a/b/file.txt
    ///     R/link → Target
    ///     Target/sub/d.txt
    ///     Target/sub/deeper/e.txt
    ///     Target/sub/deeper/deepest/f.txt
    ///
    /// `Target/sub` is exactly as long as `R/link/sub`, so a resolved id and its composed path
    /// differ in bytes but not in anything a length check can see.
    private static func makeFixture() throws -> (base: URL, root: URL, target: URL, other: URL) {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "ColumnsBelowALink")
        let root = base.appendingPathComponent("R", isDirectory: true)
        let target = base.appendingPathComponent("Target", isDirectory: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        for dir in [root.appendingPathComponent("plain/a/b"),
                    target.appendingPathComponent("sub/deeper/deepest"), other] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for file in [root.appendingPathComponent("plain/a/b/file.txt"),
                     target.appendingPathComponent("sub/d.txt"),
                     target.appendingPathComponent("sub/deeper/e.txt"),
                     target.appendingPathComponent("sub/deeper/deepest/f.txt")] {
            try Data(file.lastPathComponent.utf8).write(to: file)
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        return (base, root, target, other)
    }

    private static func source(_ id: String, _ path: String) -> CloudProvider {
        CloudProvider(id: id, displayName: id, imageName: "folder", rootPath: path, type: .localFolder)
    }

    /// The node reached from `nodes` by these names, each matched against the last component of an
    /// id: the tree's shape, whatever spelling the walk gave the ids.
    private static func node(at names: [String], in nodes: [FileNode]) -> FileNode? {
        guard let first = names.first,
              let hit = nodes.first(where: { ($0.id as NSString).lastPathComponent == first }) else { return nil }
        return names.count == 1 ? hit : node(at: Array(names.dropFirst()), in: hit.children ?? [])
    }

    /// Every column of `stack` lists something, the deepest lists `deepest`, and a republish's prune
    /// keeps the whole stack: "open a folder below a link and stay there".
    @MainActor
    private static func expectEveryColumnResolves(_ stack: PaneBrowsePath, treeRoot: String,
                                                  index: PaneChildrenIndex,
                                                  links: PathBoundary.LinkedFolders,
                                                  deepest: [String],
                                                  sourceLocation: SourceLocation = #_sourceLocation) {
        let directories = stack.columnDirectories(treeRoot: treeRoot, links: links)
        let missing = directories.filter { !index.isDirectory(atPath: $0) }
        #expect(missing.isEmpty, "columns that read nothing: \(missing)", sourceLocation: sourceLocation)
        #expect(index.children(atPath: directories.last ?? "")?.map(\.node.name) == deepest,
                "the deepest column lists \(index.children(atPath: directories.last ?? "")?.map(\.node.name) ?? [])",
                sourceLocation: sourceLocation)
        #expect(stack.pruned(against: index, treeRoot: treeRoot, links: links).components == stack.components,
                "a republish prunes the stack back to \(stack.pruned(against: index, treeRoot: treeRoot, links: links).components)",
                sourceLocation: sourceLocation)
    }

    // MARK: - The children index

    /// Two levels below a folder link. The link and its child keep the link's spelling (the URL API
    /// lists nothing at a symlink, so the path-based fallback does), and below that the ids are
    /// where the link leads. Composed as `R/link/sub/deeper`, that column must still resolve.
    @MainActor
    @Test func aStackTwoLevelsBelowAFolderLinkKeepsEveryColumn() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = [:]
        await m.refreshTreesAndScan(left: Self.source("L", f.root.path), right: Self.source("R", f.other.path),
                                    comparing: false)

        let deeper = try #require(Self.node(at: ["link", "sub", "deeper"], in: m.leftTree),
                                  "premise: the walk does not list the linked folder's grandchild")
        try #require(deeper.id == f.target.appendingPathComponent("sub/deeper").path,
                     "premise: the walk spelled it \(deeper.id) — the hazard this pins needs the RESOLVED spelling")
        let index = m.leftChildrenIndex(treeRoot: f.root.path)
        Self.expectEveryColumnResolves(PaneBrowsePath(components: ["link", "sub", "deeper", "deepest"]),
                                       treeRoot: f.root.path, index: index, links: [:], deepest: ["f.txt"])

        // Through the manager's own republish prune, which is what would move the user.
        m.setBrowsePath(isLeft: true, PaneBrowsePath(components: ["link", "sub", "deeper"]))
        m.pruneBrowsePath(isLeft: true, against: index, treeRoot: f.root.path)
        #expect(m.leftBrowsePath.components == ["link", "sub", "deeper"])
    }

    /// A root spelled through a link: `/var/folders/…` lists `/private/var/…` from its first level,
    /// so every column past the root is at stake, on an ordinary branch as much as below the link.
    /// `makeCanonicalTempRoot` hides this spelling on purpose; it is undone here.
    @MainActor
    @Test func aRootSpelledThroughALinkKeepsEveryColumn() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try #require(f.root.path.hasPrefix("/private/var/"), "premise: the temp root is not under /private/var")
        let root = String(f.root.path.dropFirst("/private".count))
        let m = FileSyncManager()
        m.linkedFolders = [:]
        await m.refreshTreesAndScan(left: Self.source("L", root), right: Self.source("R", f.other.path),
                                    comparing: false)

        let plain = try #require(Self.node(at: ["plain"], in: m.leftTree), "premise: the walk listed nothing")
        try #require(plain.id.hasPrefix("/private/var/"),
                     "premise: the walk spelled the root's child \(plain.id) — the hazard this pins needs /private")
        let index = m.leftChildrenIndex(treeRoot: root)
        Self.expectEveryColumnResolves(PaneBrowsePath(components: ["plain", "a", "b"]),
                                       treeRoot: root, index: index, links: [:], deepest: ["file.txt"])
        Self.expectEveryColumnResolves(PaneBrowsePath(components: ["link", "sub", "deeper", "deepest"]),
                                       treeRoot: root, index: index, links: [:], deepest: ["f.txt"])
    }

    /// A pane focused below a link lists resolved ids from its first level, and Columns must still
    /// open folders there. Reached through a breadcrumb, a tab, or "Compare only this folder".
    @MainActor
    @Test func aPaneFocusedBelowALinkKeepsEveryColumn() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = [:]
        m.leftRelativePath = "link/sub"
        await m.refreshTreesAndScan(left: Self.source("L", f.root.path), right: Self.source("R", f.other.path),
                                    comparing: false)

        let treeRoot = PathBoundary.join(root: f.root.path, relative: "link/sub", links: [:])
        try #require(m.paneTreeFolder(isLeft: true) == treeRoot, "premise: the pane walked \(m.paneTreeFolder(isLeft: true) ?? "nothing")")
        let deeper = try #require(Self.node(at: ["deeper"], in: m.leftTree), "premise: the focused walk listed nothing")
        try #require(deeper.id == f.target.appendingPathComponent("sub/deeper").path,
                     "premise: the focused walk spelled \(deeper.id) — the hazard this pins needs the RESOLVED spelling")
        Self.expectEveryColumnResolves(PaneBrowsePath(components: ["deeper", "deepest"]),
                                       treeRoot: treeRoot, index: m.leftChildrenIndex(treeRoot: treeRoot),
                                       links: [:], deepest: ["f.txt"])
    }

    /// iCloud Drive's shape on the fixture's own table: the container links `Documents` to
    /// `home/Documents`, outside it, and inside that `dlink` is an ordinary folder link to
    /// `elsewhere`. `Pictures/Documents` is an ordinary folder that only shares the linked one's name.
    private static func makeLinkedFixture() throws
        -> (base: URL, above: URL, container: URL, real: URL, elsewhere: URL, other: URL,
            links: PathBoundary.LinkedFolders) {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "ColumnsBelowALink-linked")
        let above = base.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let container = above.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        let real = base.appendingPathComponent("home/Documents", isDirectory: true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        for dir in [container.appendingPathComponent("Pictures/Documents"), real.appendingPathComponent("Finance/IN"),
                    elsewhere.appendingPathComponent("sub/deeper"), other] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("p".utf8).write(to: container.appendingPathComponent("Pictures/Documents/p.md"))
        try Data("x".utf8).write(to: real.appendingPathComponent("Finance/IN/x.md"))
        try Data("z".utf8).write(to: elsewhere.appendingPathComponent("sub/deeper/z.md"))
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: real)
        try fm.createSymbolicLink(at: real.appendingPathComponent("dlink"), withDestinationURL: elsewhere)
        return (base, above, container, real, elsewhere, other, [container.path: ["Documents": real.path]])
    }

    /// Above iCloud Drive's container the walk lists the linked `Documents` as `~/Documents` while
    /// the column composes `…/com~apple~CloudDocs/Documents`. At the container itself
    /// `PaneBrowsePath.step` resolves a first component through the table, but a folder link inside
    /// `Documents` is at stake in both cases two levels down: the second stack here.
    ///
    /// Also through the manager's own prune and a mirrored drill, which must compose with the
    /// manager's table, not the machine's, or `Documents` composes lexically and the stack is cut.
    @MainActor
    @Test(arguments: [true, false])
    func aStackThroughTheLinkedFolderKeepsEveryColumn(rootedAboveTheContainer: Bool) async throws {
        let f = try Self.makeLinkedFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = f.links
        let root = rootedAboveTheContainer ? f.above.path : f.container.path
        await m.refreshTreesAndScan(left: Self.source("L", root), right: Self.source("R", f.other.path),
                                    comparing: false)

        let documents = (rootedAboveTheContainer ? ["com~apple~CloudDocs"] : []) + ["Documents"]
        let linked = try #require(Self.node(at: documents, in: m.leftTree), "premise: the walk did not list the linked folder")
        try #require(linked.id == f.real.path,
                     "premise: the walk spelled the linked folder \(linked.id), not where it leads")
        let deeper = try #require(Self.node(at: documents + ["dlink", "sub", "deeper"], in: m.leftTree))
        try #require(deeper.id == f.elsewhere.appendingPathComponent("sub/deeper").path,
                     "premise: the walk spelled \(deeper.id) — the hazard this pins needs the RESOLVED spelling")
        let index = m.leftChildrenIndex(treeRoot: root)
        Self.expectEveryColumnResolves(PaneBrowsePath(components: documents + ["Finance", "IN"]), treeRoot: root,
                                       index: index, links: f.links, deepest: ["x.md"])
        let stack = PaneBrowsePath(components: documents + ["dlink", "sub", "deeper"])
        Self.expectEveryColumnResolves(stack, treeRoot: root, index: index, links: f.links, deepest: ["z.md"])
        // Only a first component goes through the table: a deeper `Documents` is the folder it is.
        Self.expectEveryColumnResolves(
            PaneBrowsePath(components: Array(documents.dropLast()) + ["Pictures", "Documents"]),
            treeRoot: root, index: index, links: f.links, deepest: ["p.md"])

        m.setBrowsePath(isLeft: true, stack)
        m.pruneBrowsePath(isLeft: true, against: index, treeRoot: root)
        #expect(m.leftBrowsePath.components == stack.components, "the republish pruned it to \(m.leftBrowsePath.components)")
        m.setBrowsePath(isLeft: true, PaneBrowsePath())
        m.applyColumnNavigation(stack, isLeft: false, mirror: true, otherIndex: index, otherTreeRoot: root)
        #expect(m.leftBrowsePath.components == stack.components, "the mirrored drill pruned it to \(m.leftBrowsePath.components)")
    }

    /// A folder the tree holds twice is two columns. Home holds `~/Dropbox` and the folder it leads
    /// to, and below the link both routes carry one id, while the budget can walk one route and stop
    /// the other. Keyed by id, the walked column would list the stopped copy and read as unread (see
    /// `PaneChildrenIndex`). A four-level cap stands in for the budget: `R/T/sub/deeper` is read,
    /// and the same folder through `R/z/link`, one level deeper, is not.
    @MainActor
    @Test func eachRouteToAFolderTheTreeHoldsTwiceListsItsOwnCopy() async throws {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "ColumnsBelowALink-twice")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("R", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("T/sub/deeper"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("z"), withIntermediateDirectories: true)
        try Data("f".utf8).write(to: root.appendingPathComponent("T/sub/deeper/f.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("z/link"),
                                  withDestinationURL: root.appendingPathComponent("T"))
        let m = FileSyncManager()
        m.linkedFolders = [:]
        let capped = await FileSyncManager.buildTree(url: root, sortOption: .name, maxDepth: 4, linkedFolders: [:])
        let walked = try #require(Self.node(at: ["T", "sub", "deeper"], in: capped))
        let stopped = try #require(Self.node(at: ["z", "link", "sub", "deeper"], in: capped))
        try #require(walked.id == stopped.id && walked.isUnexplored == nil && stopped.isUnexplored == true,
                     "premise: the two copies are \(walked.id) (\(walked.isUnexplored as Any)) and \(stopped.id) (\(stopped.isUnexplored as Any))")
        m.adoptRawTree(capped, isLeft: true, focusPath: root.path)
        await m.applyFilters()

        let index = m.leftChildrenIndex(treeRoot: root.path)
        let walkedColumn = try #require(PaneBrowsePath(components: ["T", "sub", "deeper"])
            .columnDirectories(treeRoot: root.path, links: [:]).last)
        let stoppedColumn = try #require(PaneBrowsePath(components: ["z", "link", "sub", "deeper"])
            .columnDirectories(treeRoot: root.path, links: [:]).last)
        #expect(index.children(atPath: walkedColumn)?.map(\.node.name) == ["f.txt"])
        #expect(!index.isUnexplored(atPath: walkedColumn), "the walked copy reads as unread — it answered with the other route's")
        #expect(index.isUnexplored(atPath: stoppedColumn))

        // And the stopped route's column fills its own copy, not the walked one.
        m.loadColumnChildren(atPath: stoppedColumn, isLeft: true)
        await waitUntil("the stopped copy is read") {
            Self.node(at: ["z", "link", "sub", "deeper"], in: m.rawLeftTree)?.isUnexplored == nil
        }
        await waitUntil("the request clears") { m.columnGraftsInFlightPaths(isLeft: true).isEmpty }
        #expect(m.leftChildrenIndex(treeRoot: root.path).children(atPath: stoppedColumn)?.map(\.node.name) == ["f.txt"])
    }

    // MARK: - A folder the walk did not read

    /// A budget-unexplored folder below a link is asked for, and its listing lands. The index must
    /// call the column's path unexplored, or the column reads "Empty" over an unlisted folder, and
    /// the graft must find the node by that path, not by id. A three-level cap stands in for the
    /// budget: both mark the same way.
    @MainActor
    @Test func anUnreadFolderBelowALinkIsReadIntoItsColumn() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = [:]
        let capped = await FileSyncManager.buildTree(url: f.root, sortOption: .name, maxDepth: 3, linkedFolders: [:])
        let unread = try #require(Self.node(at: ["link", "sub", "deeper"], in: capped))
        try #require(unread.isUnexplored == true && unread.id == f.target.appendingPathComponent("sub/deeper").path,
                     "premise: the capped walk read \(unread.id) or spelled it unresolved — this measures nothing")
        m.adoptRawTree(capped, isLeft: true, focusPath: f.root.path)
        await m.applyFilters()

        let directory = try #require(PaneBrowsePath(components: ["link", "sub", "deeper"])
            .columnDirectories(treeRoot: f.root.path, links: [:]).last)
        #expect(m.leftChildrenIndex(treeRoot: f.root.path).isUnexplored(atPath: directory),
                "the column reads “Empty” over a folder the walk never listed")

        m.loadColumnChildren(atPath: directory, isLeft: true)
        #expect(m.columnGraftsInFlightPaths(isLeft: true).contains(directory), "the column's request was refused")
        await waitUntil("the listing lands in the pane's tree") {
            Self.node(at: ["link", "sub", "deeper"], in: m.rawLeftTree)?.isUnexplored == nil
        }
        await waitUntil("the request clears") { m.columnGraftsInFlightPaths(isLeft: true).isEmpty }
        #expect(m.leftChildrenIndex(treeRoot: f.root.path).children(atPath: directory)?.map(\.node.name)
                == ["deepest", "e.txt"])
    }

    /// The outline asks with a row's id, not a composed path, and under a root spelled through a
    /// link no id is a path under the root, so names can't find it. The id prefix must: opening an
    /// unread folder in the Tree there must still fill it in.
    @MainActor
    @Test func anUnreadFolderTheOutlineAsksForByIdIsReadUnderARootSpelledThroughALink() async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try #require(f.root.path.hasPrefix("/private/var/"), "premise: the temp root is not under /private/var")
        let root = String(f.root.path.dropFirst("/private".count))
        let m = FileSyncManager()
        m.linkedFolders = [:]
        let capped = await FileSyncManager.buildTree(url: URL(fileURLWithPath: root), sortOption: .name,
                                                     maxDepth: 1, linkedFolders: [:])
        let plain = try #require(capped.first { $0.name == "plain" })
        try #require(plain.isUnexplored == true && plain.id.hasPrefix("/private/var/"),
                     "premise: the capped walk read \(plain.id) or spelled it under the root — this measures nothing")
        m.adoptRawTree(capped, isLeft: true, focusPath: root)

        m.loadColumnChildren(atPath: plain.id, isLeft: true)
        #expect(m.columnGraftsInFlightPaths(isLeft: true).contains(plain.id), "the outline's request was refused")
        await waitUntil("the listing lands in the pane's tree") {
            m.rawLeftTree.first { $0.name == "plain" }?.isUnexplored == nil
        }
        await waitUntil("the request clears") { m.columnGraftsInFlightPaths(isLeft: true).isEmpty }
    }

    // MARK: - The cache slice

    /// Navigating below a link is served from the root's cached walk, as anywhere else; a slice
    /// matched by id prefix misses there and takes a cold walk. Told apart by a file written behind
    /// the manager's back: a cold walk lists it, a slice of the earlier walk doesn't. `plain/a`,
    /// where ids continue, is the control.
    @MainActor
    @Test(arguments: ["plain/a", "link/sub/deeper"])
    func aFocusBelowTheRootIsSlicedFromItsCachedWalk(focus: String) async throws {
        let f = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = [:]
        let (left, right) = (Self.source("L", f.root.path), Self.source("R", f.other.path))
        await m.refreshTreesAndScan(left: left, right: right, comparing: false)
        try #require(m.prefetchedTrees[f.root.path] != nil, "premise: the root's deep walk is not cached")

        let folder = URL(fileURLWithPath: PathBoundary.join(root: f.root.path, relative: focus, links: [:]))
        let listedBefore = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        try Data().write(to: folder.appendingPathComponent("written-behind.txt"))
        m.leftRelativePath = focus
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)

        #expect(m.paneTreeFolder(isLeft: true) == folder.path)
        #expect(m.leftTree.map(\.name).sorted() == listedBefore,
                "walked from disk: \(m.leftTree.map(\.name).sorted()) — the cached walk of the root already held this folder")
    }
}
