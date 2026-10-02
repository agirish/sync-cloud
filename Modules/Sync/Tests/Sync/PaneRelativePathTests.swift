import Foundation
import Testing
@testable import Sync

/// Pins `paneRelativePath(of:isLeft:root:)` — where a folder a pane lists sits below its source's
/// root, which is the path "Compare only this folder" and the rail's Open focus on.
///
/// Every case walks a real folder and asks about a node the walk produced, because the defect is
/// in how the walk spells ids: two levels below a folder symlink, under a root spelled through a
/// link, and for iCloud Drive's `Documents` under a root above its container, a node's id is not
/// its parent's id plus its name, and stripping the root off it found nothing. Each of those cases
/// requires that premise first, so a walk that one day keeps the link's spelling turns them red
/// rather than leaving them proving nothing.
@Suite struct PaneRelativePathTests {

    /// `R/link → T`, with `T` outside `R`: the link, its child, and two levels below that, plus a
    /// plain branch that no link touches.
    private static func makeLinkedTree(under base: URL) throws -> (root: URL, target: URL) {
        let fm = FileManager.default
        let root = base.appendingPathComponent("R", isDirectory: true)
        let target = base.appendingPathComponent("T", isDirectory: true)
        try fm.createDirectory(at: target.appendingPathComponent("sub/deeper/deepest"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: target.appendingPathComponent("sub/deeper/deepest/f.txt"))
        try fm.createDirectory(at: root.appendingPathComponent("plain/a/b"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        return (root, target)
    }

    /// A manager whose panes have walked their roots at their focuses, the way the app loads them.
    /// The right pane gets an empty folder of its own unless a test names one.
    @MainActor
    private static func loaded(root: String, focus: String = "", rightRoot: String? = nil, rightFocus: String = "",
                               links: PathBoundary.LinkedFolders = [:], in base: URL) async throws -> FileSyncManager {
        let empty = base.appendingPathComponent("other-pane", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let m = FileSyncManager()
        m.linkedFolders = links
        m.leftRelativePath = focus
        m.rightRelativePath = rightFocus
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder", rootPath: root, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder", rootPath: rightRoot ?? empty.path,
                                  type: .localFolder)
        await m.refreshTreesAndScan(left: left, right: right, comparing: false)
        return m
    }

    /// The node a click would hand over: found by walking down the published tree by the names
    /// on screen.
    private static func node(_ names: [String], in tree: [FileNode]) -> FileNode? {
        var level = tree
        var found: FileNode?
        for name in names {
            guard let next = level.first(where: { $0.name == name }) else { return nil }
            found = next
            level = next.children ?? []
        }
        return found
    }

    /// Whether two paths name one folder on disk, whichever link either goes through.
    private static func sameFolder(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    // MARK: - Ids the root cannot be stripped off

    /// **Below a folder symlink.** The link and its child keep the link's spelling, and from there
    /// the listing comes back where the link leads: `T/sub/deeper`. Each level answers with the
    /// names down to it, and each answer, joined back the way a focus is, is the folder listed.
    @MainActor
    @Test func aFolderTwoLevelsBelowAFolderLinkIsPlacedByItsNames() async throws {
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-link")
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, _) = try Self.makeLinkedTree(under: base)
        let m = try await Self.loaded(root: root.path, in: base)

        let deeper = try #require(Self.node(["link", "sub", "deeper"], in: m.leftTree),
                                  "premise: the walk does not list the folder below the link")
        try #require(PathBoundary.relativize(deeper.id, under: root.path, links: [:]) == nil,
                     "premise: \(deeper.id) is spelled under the root, so stripping it would do")
        for names in [["link"], ["link", "sub"], ["link", "sub", "deeper"], ["link", "sub", "deeper", "deepest"]] {
            let node = try #require(Self.node(names, in: m.leftTree), "the walk does not list \(names)")
            let relative = m.paneRelativePath(of: node, isLeft: true, root: root.path)
            #expect(relative == names.joined(separator: "/"), "\(node.id) placed at \(relative ?? "nil")")
            let focus = FileSyncManager.focusURL(root: root.path, relative: relative ?? "", fallback: root, links: [:])
            #expect(Self.sameFolder(focus.path, node.id), "\(relative ?? "nil") joins to \(focus.path), not \(node.id)")
        }
    }

    /// **Under a root spelled through a link**, where nothing is spelled under the root: a `/var/…`
    /// root lists `/private/var/…` from its first level down, so even a plain child was refused.
    /// `makeCanonicalTempRoot` exists to hide exactly this spelling, so the fixture does not use it.
    @MainActor
    @Test func everyFolderUnderARootSpelledThroughALinkIsPlaced() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-relative-var-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, _) = try Self.makeLinkedTree(under: base)
        let m = try await Self.loaded(root: root.path, in: base)

        let plain = try #require(Self.node(["plain"], in: m.leftTree), "premise: the walk does not list `plain`")
        try #require(PathBoundary.relativize(plain.id, under: root.path, links: [:]) == nil,
                     "premise: \(plain.id) is spelled under \(root.path) — this machine's temp root is not behind a link")
        for names in [["plain"], ["plain", "a", "b"], ["link", "sub", "deeper"]] {
            let node = try #require(Self.node(names, in: m.leftTree), "the walk does not list \(names)")
            let relative = m.paneRelativePath(of: node, isLeft: true, root: root.path)
            #expect(relative == names.joined(separator: "/"), "\(node.id) placed at \(relative ?? "nil")")
            let focus = FileSyncManager.focusURL(root: root.path, relative: relative ?? "", fallback: root, links: [:])
            #expect(Self.sameFolder(focus.path, node.id), "\(relative ?? "nil") joins to \(focus.path), not \(node.id)")
        }
    }

    /// **iCloud Drive's `Documents` under a root above its container.** The walk lists the link as
    /// the real folder wherever it lists the container, so below `~/Library/Mobile Documents` the
    /// node is `~/Documents/Finance`. Placed by its names it is `com~apple~CloudDocs/Documents/
    /// Finance`, and joined back that is the same folder — through the link, because `join` reads
    /// the table at the root only. At the container itself the table answers, as it did before.
    @MainActor
    @Test func aFolderAboveTheContainerIsPlacedThroughTheContainersName() async throws {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-above")
        defer { try? fm.removeItem(at: base) }
        let container = base.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let real = base.appendingPathComponent("home/Documents", isDirectory: true)
        try fm.createDirectory(at: container.appendingPathComponent("Pictures"), withIntermediateDirectories: true)
        try fm.createDirectory(at: real.appendingPathComponent("Finance/IN"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: real)
        let links: PathBoundary.LinkedFolders = [container.path: ["Documents": real.path]]
        let above = container.deletingLastPathComponent().path

        let m = try await Self.loaded(root: above, links: links, in: base)
        let finance = try #require(Self.node(["com~apple~CloudDocs", "Documents", "Finance"], in: m.leftTree),
                                   "premise: the walk above the container does not list Finance")
        try #require(finance.id == real.appendingPathComponent("Finance").path,
                     "premise: the walk lists \(finance.id), not the real folder")
        let relative = m.paneRelativePath(of: finance, isLeft: true, root: above)
        #expect(relative == "com~apple~CloudDocs/Documents/Finance", "placed at \(relative ?? "nil")")
        let focus = FileSyncManager.focusURL(root: above, relative: relative ?? "", fallback: container, links: links)
        #expect(Self.sameFolder(focus.path, finance.id), "joins to \(focus.path)")

        // Control: at the container the id is placed through the table, which needed no tree.
        let atContainer = try await Self.loaded(root: container.path, links: links, in: base)
        let same = try #require(Self.node(["Documents", "Finance"], in: atContainer.leftTree))
        #expect(atContainer.paneRelativePath(of: same, isLeft: true, root: container.path) == "Documents/Finance")
        // …and it is the manager's table, the one its walks were made with: a pane that holds no
        // tree has only the table to answer from.
        let unloaded = FileSyncManager()
        unloaded.linkedFolders = links
        #expect(unloaded.paneRelativePath(of: finance, isLeft: true, root: container.path) == "Documents/Finance")
    }

    /// **A folder symlink inside iCloud Drive's `Documents`**, with the pane at the container and
    /// focused on `Documents`: that focus is walked at the real `~/Documents` (`join` reads the
    /// table), so the folder's own relative path comes back through the manager's table too, and
    /// the names below the link go onto it.
    @MainActor
    @Test func aFolderBelowALinkInsideTheLinkedDocumentsIsPlaced() async throws {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-in-documents")
        defer { try? fm.removeItem(at: base) }
        let container = base.appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
        let real = base.appendingPathComponent("home/Documents", isDirectory: true)
        let projects = base.appendingPathComponent("home/Projects", isDirectory: true)
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createDirectory(at: projects.appendingPathComponent("app/src"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: real)
        try fm.createSymbolicLink(at: real.appendingPathComponent("Code"), withDestinationURL: projects)
        let links: PathBoundary.LinkedFolders = [container.path: ["Documents": real.path]]

        let m = try await Self.loaded(root: container.path, focus: "Documents", links: links, in: base)
        try #require(m.paneTreeFolder(isLeft: true) == real.path, "premise: the focus was not walked at the real folder")
        let src = try #require(Self.node(["Code", "app", "src"], in: m.leftTree), "premise: the walk does not reach `src`")
        try #require(src.id == projects.appendingPathComponent("app/src").path, "premise: `src` is listed as \(src.id)")
        #expect(m.paneRelativePath(of: src, isLeft: true, root: container.path) == "Documents/Code/app/src")
    }

    /// **A pane focused below the link** lists resolved ids from its first level down, so the names
    /// go onto the focus, not onto the root.
    @MainActor
    @Test func aFolderInAPaneFocusedBelowTheLinkIsPlacedBelowTheFocus() async throws {
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-focused")
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, _) = try Self.makeLinkedTree(under: base)
        let m = try await Self.loaded(root: root.path, focus: "link/sub", in: base)

        let deepest = try #require(Self.node(["deeper", "deepest"], in: m.leftTree), "premise: the focused walk lists nothing")
        #expect(m.paneRelativePath(of: deepest, isLeft: true, root: root.path) == "link/sub/deeper/deepest")
    }

    // MARK: - Which tree, and which folder

    /// **The names go onto the folder the tree was walked at, not onto where the pane now claims to
    /// be.** `focusOn` moves the relative path at once and the walk lands later, so in between the
    /// tree on screen is the old folder's and a row in it can still be acted on.
    @MainActor
    @Test func aStaleTreeIsPlacedFromTheFolderItWasWalkedAt() async throws {
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-stale")
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, _) = try Self.makeLinkedTree(under: base)
        let m = try await Self.loaded(root: root.path, in: base)
        let deeper = try #require(Self.node(["link", "sub", "deeper"], in: m.leftTree))

        m.leftRelativePath = "plain"     // a focus whose walk has not landed
        #expect(m.paneRelativePath(of: deeper, isLeft: true, root: root.path) == "link/sub/deeper")
    }

    /// **Names come from the tree that belongs to `paneTreeFolder`.** `adoptRawTree` writes the raw
    /// tree and that folder together, and the published tree follows a filter pass later — so for
    /// that pass the rows on screen are the previous walk's. Read off them, a row's names would be
    /// composed onto the new walk's folder and name somewhere that is not the row.
    @MainActor
    @Test func namesAreNotReadFromAPublishedTreeTheWalkHasReplaced() async throws {
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-replaced")
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, _) = try Self.makeLinkedTree(under: base)
        let m = try await Self.loaded(root: root.path, in: base)
        let deeper = try #require(Self.node(["link", "sub", "deeper"], in: m.leftTree))

        let plain = root.appendingPathComponent("plain", isDirectory: true)
        let walk = await FileSyncManager.buildTree(url: plain, sortOption: .name, linkedFolders: [:])
        m.adoptRawTree(walk, isLeft: true, focusPath: plain.path)
        try #require(Self.node(["link", "sub", "deeper"], in: m.leftTree) != nil,
                     "premise: the published tree moved with the raw one — there is no window to test")
        let relative = m.paneRelativePath(of: deeper, isLeft: true, root: root.path)
        #expect(relative == nil, "placed at \(relative ?? "nil") from a tree that no longer belongs to the pane's folder")
    }

    /// **The id's own spelling wins where it is under the root.** A folder can be in the tree twice
    /// — here the link leads inside the root, as Home's `~/Dropbox` does — and the node does not say
    /// which row was clicked. The id is spelled along the real route, the one that keeps its walk's
    /// ids in their own spelling; the names would pick whichever route sorts first (`link`).
    @MainActor
    @Test func theIdsOwnRouteWinsWhereItIsUnderTheRoot() async throws {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-two-routes")
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("R", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("real/sub/deeper"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"),
                                  withDestinationURL: root.appendingPathComponent("real"))
        let m = try await Self.loaded(root: root.path, in: base)

        let viaLink = try #require(Self.node(["link", "sub", "deeper"], in: m.leftTree), "premise: the link is not walked")
        try #require(viaLink.id == root.appendingPathComponent("real/sub/deeper").path,
                     "premise: below the link the id is \(viaLink.id), not the real route's")
        #expect(m.paneRelativePath(of: viaLink, isLeft: true, root: root.path) == "real/sub/deeper")
    }

    /// **A folder the pane does not hold is still refused** — the names come from the pane's own
    /// tree, so they cannot place a node the walk never listed, however its id is spelled.
    @MainActor
    @Test func aFolderThePaneDoesNotHoldIsRefused() async throws {
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-outside")
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, target) = try Self.makeLinkedTree(under: base)
        let m = try await Self.loaded(root: root.path, in: base)

        let alias = FileNode(id: root.path + "-alias/sub", name: "sub", isDirectory: true)
        #expect(m.paneRelativePath(of: alias, isLeft: true, root: root.path) == nil)
        // Where the link leads, but not a folder the walk listed.
        let unlisted = FileNode(id: target.appendingPathComponent("elsewhere").path, name: "elsewhere", isDirectory: true)
        #expect(m.paneRelativePath(of: unlisted, isLeft: true, root: root.path) == nil)
    }

    /// **Each pane's names come from its own tree.** Both panes on one root, the left focused on a
    /// branch that does not hold the folder: the right pane places it, the left refuses it.
    @MainActor
    @Test func aFolderIsPlacedFromItsOwnPanesTree() async throws {
        let base = try makeCanonicalTempRoot(prefix: "pane-relative-sides")
        defer { try? FileManager.default.removeItem(at: base) }
        let (root, _) = try Self.makeLinkedTree(under: base)
        let m = try await Self.loaded(root: root.path, focus: "plain", rightRoot: root.path, in: base)

        let deeper = try #require(Self.node(["link", "sub", "deeper"], in: m.rightTree),
                                  "premise: the right pane does not list the folder")
        #expect(m.paneRelativePath(of: deeper, isLeft: false, root: root.path) == "link/sub/deeper")
        #expect(m.paneRelativePath(of: deeper, isLeft: true, root: root.path) == nil,
                "the left pane, walked at `plain`, placed a folder it does not hold")
    }
}
