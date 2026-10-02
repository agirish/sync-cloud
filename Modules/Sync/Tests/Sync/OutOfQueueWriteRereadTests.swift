import Testing
import Foundation
@testable import Sync

/// **A file written outside the file-operation queue is listed by the next re-read only if the
/// re-read is prepared the way the queue prepares one** — TE44.
///
/// Edit's ⌘N writes its new file straight to disk (`EditorFileStore.createEmptyFile`), not through
/// `enqueueFileOperation`, so it does not get that function's epilogue: drop the prefetch cache,
/// bump the scan-config epoch, send `refreshSubject`. The app now asks for the same re-read with
/// `prepareForcedRescan()` and a `.both` send. This pins why the first half is not optional: a
/// pane that has finished a deep walk keeps it in `prefetchedTrees`, and a re-read of the same
/// folder without the drop is served that walk — the one taken before the file existed.
///
/// **The app now asks for the targeted form** (TE47 review): `prepareReread(afterWritingAt:)`
/// drops only the walks that list the new file's folder, and the app re-reads only the pane that
/// shows it, without a comparison. The second test proves the targeted drop still defeats the
/// cache — the point the first one makes — and that it keeps what it has no business dropping.
@Suite struct OutOfQueueWriteRereadTests {

    private static func makeFixture() throws -> (root: URL, left: URL, right: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synccloud-out-of-queue-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        let finance = root.appendingPathComponent("left/Finance", isDirectory: true)
        try fm.createDirectory(at: finance.appendingPathComponent("IN"), withIntermediateDirectories: true)
        try fm.createDirectory(at: finance.appendingPathComponent("US"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("right"), withIntermediateDirectories: true)
        let resolved = root.resolvingSymlinksInPath()
        return (resolved, resolved.appendingPathComponent("left"), resolved.appendingPathComponent("right"))
    }

    private static func providers(_ f: (root: URL, left: URL, right: URL)) -> (CloudProvider, CloudProvider) {
        (CloudProvider(id: "L", displayName: "L", imageName: "folder", rootPath: f.left.path, type: .localFolder),
         CloudProvider(id: "R", displayName: "R", imageName: "folder", rootPath: f.right.path, type: .localFolder))
    }

    @MainActor
    @Test func aPreparedRereadListsTheNewFileAndAnUnpreparedOneDoesNot() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (left, right) = Self.providers(fixture)
        let m = FileSyncManager()
        await m.refreshTreesAndScan(left: left, right: right)
        // The walk's own spelling of the folder (`/private/var/…` for a temp dir, which
        // `resolvingSymlinksInPath` spells `/var/…`) — the spelling the pane, and so the app's
        // `editorFolder`, would hand to the create.
        let finance = try #require(m.leftTree.first { $0.name == "Finance" },
                                   "the fixture's own folder is not listed — nothing below means anything")
        try #require(finance.children?.map(\.name).sorted() == ["IN", "US"])
        let created = (finance.id as NSString).appendingPathComponent("Test.md")

        // What ⌘N does: one file, straight to disk, nobody told.
        try Data().write(to: URL(fileURLWithPath: created))

        // The control: a re-read of the same target WITHOUT the preparation is served the cached
        // walk. If this ever lists the file, the cache no longer behaves as described above, and
        // the assertion below has stopped proving that the preparation is what lists it.
        await m.refreshTreesAndScan(left: left, right: right)
        #expect(m.leftNodes(for: [created]).isEmpty,
                "an unprepared re-read listed the file — the cache this test is about did not serve it")

        // The fix: prepared the way a file operation's epilogue prepares one.
        m.prepareForcedRescan()
        await m.refreshTreesAndScan(left: left, right: right)
        let node = try #require(m.leftNodes(for: [created]).first,
                                "a prepared re-read still does not list the file ⌘N created")
        #expect(node.isDirectory == false)
        #expect(node.id == created, "listed under another spelling — the pane selection could not name it")
    }

    /// **The targeted form: the walks listing the folder go, the rest stay, and a one-pane
    /// re-read with no comparison lists the file.** The control is the first test's: unprepared,
    /// the same one-pane re-read is served the pre-write walk.
    @MainActor
    @Test func aTargetedRereadListsTheNewFileAndKeepsWhatItDoesNotHold() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (left, right) = Self.providers(fixture)
        let m = FileSyncManager()
        await m.refreshTreesAndScan(left: left, right: right)
        let finance = try #require(m.leftTree.first { $0.name == "Finance" })
        let created = (finance.id as NSString).appendingPathComponent("Test.md")
        // The walk's key is the provider root as handed over (`/var/…`), its node ids the walk's
        // own spelling (`/private/var/…`) — the two spellings a save panel and a pane can differ by.
        let leftRoot = try #require(m.prefetchedTrees.keys.first { FileSyncManager.folder($0, holds: finance.id) },
                                    "the left pane's deep walk is not cached — nothing below means anything: \(m.prefetchedTrees.keys.sorted())")
        let rightRoot = try #require(m.prefetchedTrees.keys.first { $0 != leftRoot },
                                     "the right pane's deep walk is not cached — the keep below means nothing")
        // A walk of a sibling folder the file is NOT under, as a navigation there would cache it.
        let sibling = (finance.id as NSString).appendingPathComponent("IN")
        m.prefetchedTrees[sibling] = []
        m.prefetchedTreeReadAt[sibling] = Date()

        try Data().write(to: URL(fileURLWithPath: created))

        // Control: unprepared, the one-pane re-read is served the cached walk.
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        #expect(m.leftNodes(for: [created]).isEmpty,
                "an unprepared re-read listed the file — the cache this test is about did not serve it")

        m.prepareReread(afterWritingAt: created)
        #expect(m.prefetchedTrees[leftRoot] == nil, "the walk that lists the folder survived — it serves the pre-write tree")
        #expect(m.prefetchedTreeReadAt[leftRoot] == nil, "the dropped walk's read stamp survived it")
        #expect(m.prefetchedTrees[rightRoot] != nil, "the other pane's walk was dropped — it does not hold the file")
        #expect(m.prefetchedTrees[sibling] != nil, "a sibling folder's walk was dropped — it does not hold the file")
        #expect(m.prefetchedTreeReadAt[sibling] != nil)

        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        let node = try #require(m.leftNodes(for: [created]).first,
                                "a targeted re-read does not list the file ⌘N created")
        #expect(node.id == created)
    }

    /// **"Lists" includes a linked folder.** The iCloud container's walk lists `~/Documents` under
    /// the link's name, so a file written in `~/Documents/Finance` makes the container's entry
    /// stale though its key is no prefix of the file's path. A synthetic table, so no real iCloud
    /// is needed; the keys are never read from disk.
    @MainActor
    @Test func aWalkReachingTheFolderThroughALinkIsDroppedToo() {
        let links: PathBoundary.LinkedFolders = ["/c": ["Documents": "/h/Documents"]]
        let m = FileSyncManager()
        m.linkedFolders = links
        for key in ["/c", "/h/Documents", "/h/Documents/Finance", "/h/Documents/Other", "/c/Pictures", "/h"] {
            m.prefetchedTrees[key] = []
        }
        let dropped = m.dropPrefetchedTrees(holding: "/h/Documents/Finance")
        #expect(Set(m.prefetchedTrees.keys) == ["/h/Documents/Other", "/c/Pictures"],
                "kept \(m.prefetchedTrees.keys.sorted())")
        #expect(dropped == 4)
        // The link-side spelling of the same folder is a plain prefix of the container's key.
        #expect(FileSyncManager.folder("/c", holds: "/c/Documents/Finance/x.md", links: links))
        #expect(FileSyncManager.folder("/h/Documents/Finance", holds: "/h/Documents/Finance/x.md", links: links))
        #expect(!FileSyncManager.folder("/h/Documents/Fin", holds: "/h/Documents/Finance/x.md", links: links))
        #expect(!FileSyncManager.folder("", holds: "/h/Documents/Finance/x.md", links: links),
                "an empty folder — no root at all — claimed a path")
    }

    // MARK: - A walk rooted above the container

    /// iCloud Drive's shape on the fixture's own table: `Library/Mobile Documents/com~apple~CloudDocs`
    /// links `Documents` to `home/Documents`, which lies outside it, and `other` holds no link.
    private static func makeLinkedFixture() throws
        -> (base: URL, container: URL, real: URL, other: URL, links: PathBoundary.LinkedFolders) {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "synccloud-out-of-queue-linked")
        let container = base.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        let real = base.appendingPathComponent("home/Documents", isDirectory: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        try fm.createDirectory(at: container.appendingPathComponent("Pictures"), withIntermediateDirectories: true)
        try fm.createDirectory(at: real.appendingPathComponent("Finance/IN"), withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: other.appendingPathComponent("x.md"))
        try fm.createSymbolicLink(at: container.appendingPathComponent("Documents"), withDestinationURL: real)
        return (base, container, real, other, [container.path: ["Documents": real.path]])
    }

    /// Whether a walk lists a node with this id, at any depth.
    private static func lists(_ id: String, in nodes: [FileNode]) -> Bool {
        nodes.contains { $0.id == id || lists(id, in: $0.children ?? []) }
    }

    /// **A walk rooted ABOVE the container lists the linked folder too, so a write there drops it.**
    /// The walk substitutes a link wherever it lists the container, not only at its own root, so a
    /// pane on `~/Library/Mobile Documents` lists `~/Documents` as surely as one on iCloud Drive —
    /// and a file written in `~/Documents/Finance` makes that walk stale though its key is no
    /// prefix of the file's path and its root is not the container. Served stale, a warm Compare
    /// at that root disagrees with a cold one. The table goes in through the manager's seam; the
    /// machine's own links are never read.
    ///
    /// The control is the right pane's walk, which reaches nothing the write touched and stays.
    @MainActor
    @Test func aWalkAboveTheContainerIsDroppedByAWriteWhereTheLinkLeads() async throws {
        let f = try Self.makeLinkedFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let m = FileSyncManager()
        m.linkedFolders = f.links
        let above = f.container.deletingLastPathComponent().path
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder", rootPath: above, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder", rootPath: f.other.path,
                                  type: .localFolder)
        await m.refreshTreesAndScan(left: left, right: right, comparing: false)

        let finance = f.real.appendingPathComponent("Finance").path
        let walk = try #require(m.prefetchedTrees[above],
                                "premise: the walk above the container is not cached: \(m.prefetchedTrees.keys.sorted())")
        try #require(Self.lists(finance, in: walk),
                     "premise: the walk above the container does not reach the linked folder — no write can make it stale")
        try #require(m.prefetchedTrees[f.other.path] != nil,
                     "premise: the control's walk is not cached — its survival below would prove nothing")
        let created = (finance as NSString).appendingPathComponent("Test.md")
        try Data().write(to: URL(fileURLWithPath: created))

        // Control: unprepared, the one-pane re-read is served the cached walk.
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        #expect(m.leftNodes(for: [created]).isEmpty,
                "an unprepared re-read listed the file — the cache this test is about did not serve it")

        m.prepareReread(afterWritingAt: created)
        #expect(m.prefetchedTrees[above] == nil,
                "the walk above the container survived — it lists the folder through the link and serves the pre-write tree")
        #expect(m.prefetchedTreeReadAt[above] == nil, "the dropped walk's read stamp survived it")
        #expect(m.prefetchedTrees[f.other.path] != nil, "the other pane's walk was dropped — it reaches nothing written")

        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        let node = try #require(m.leftNodes(for: [created]).first,
                                "the pane above the container still does not list the file written where the link leads")
        #expect(node.id == created)
    }

    /// **…and a warm Compare at that root sees the write.** Against a mirror of the tree the scan
    /// reports nothing, and both panes are cached, so it is warm. Served the walk from before the
    /// write it went on reporting nothing; with the walk dropped it reports the new file, keyed
    /// under the container's name as the cold walk keys it.
    @MainActor
    @Test func aWarmCompareAboveTheContainerSeesAWriteWhereTheLinkLeads() async throws {
        let f = try Self.makeLinkedFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = f.base.appendingPathComponent("mirror", isDirectory: true)
        for folder in ["com~apple~CloudDocs/Documents/Finance/IN", "com~apple~CloudDocs/Pictures"] {
            try FileManager.default.createDirectory(at: mirror.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
        let m = FileSyncManager()
        m.linkedFolders = f.links
        let above = f.container.deletingLastPathComponent().path
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder", rootPath: above, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder", rootPath: mirror.path,
                                  type: .localFolder)
        await m.refreshTreesAndScan(left: left, right: right)
        try #require(m.prefetchedTrees[above] != nil && m.prefetchedTrees[mirror.path] != nil,
                     "premise: both walks are cached, so the scans below are warm")
        try #require(m.hasScanned && m.rawDifferences.isEmpty,
                     "premise: the tree and its mirror compare equal: \(m.rawDifferences.map(\.relativePath))")
        let created = f.real.appendingPathComponent("Finance/Test.md")
        try Data().write(to: created)

        // Control: unprepared, the warm scan is served the walk from before the write.
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly)
        #expect(m.rawDifferences.isEmpty,
                "an unprepared scan saw the write — the cache this test is about did not serve it")

        m.prepareReread(afterWritingAt: created.path)
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly)
        let key = "com~apple~CloudDocs/Documents/Finance/Test.md"
        #expect(m.rawDifferences.map(\.relativePath) == [key],
                "\(m.rawDifferences.map { "\($0.relativePath): \($0.description)" })")
        let cold = try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: above, isDirectory: true))
        #expect(cold[key] != nil, "the disk walk keys the file elsewhere: \(cold.keys.sorted())")
    }

    /// **The rule on paths alone: a folder holds what a link at its root OR BELOW it leads to.**
    /// Not a folder below the container, whose walk never lists the link; not one beside it whose
    /// name merely opens the same way; and only the link's own target. With no table, the same
    /// folder holds nothing outside it — the answer the rule must differ from. A synthetic table;
    /// nothing is read from disk.
    @Test func aFolderHoldsWhatALinkAtOrBelowItLeadsTo() {
        let links: PathBoundary.LinkedFolders = ["/u/Library/Mobile Documents/c": ["Documents": "/u/Documents"]]
        let file = "/u/Documents/Finance/x.md"
        for holder in ["/u/Library/Mobile Documents/c", "/u/Library/Mobile Documents", "/u/Library"] {
            #expect(FileSyncManager.folder(holder, holds: file, links: links),
                    "\(holder) lists the linked folder, and did not hold a file in it")
        }
        for stranger in ["/u/Library/Mobile", "/u/Library/Mobile Documents/c/Pictures", "/u/Library/Caches"] {
            #expect(!FileSyncManager.folder(stranger, holds: file, links: links),
                    "\(stranger) never lists the linked folder, and held a file in it")
        }
        #expect(!FileSyncManager.folder("/u/Library", holds: "/u/Desktop/x.md", links: links),
                "a folder the table does not link was held")
        #expect(!FileSyncManager.folder("/u/Library", holds: "/u/Documents2/x.md", links: links),
                "a sibling sharing the target's opening was held")
        #expect(!FileSyncManager.folder("/u/Library", holds: file, links: [:]),
                "with no table, a folder held a file outside it")
    }

    // MARK: - A folder symlink the table does not name

    /// `R` holds `link → T`, `T` outside it, and `other` reaches nothing of `T`'s. `T/sub` holds a
    /// file, so the walk of `R` lists it two levels below the link, where its id comes back
    /// resolved: `T/sub/x.txt`, not `R/link/sub/x.txt`.
    private static func makeFolderLinkFixture() throws -> (base: URL, r: URL, t: URL, other: URL) {
        let fm = FileManager.default
        let base = try makeCanonicalTempRoot(prefix: "synccloud-out-of-queue-folder-link")
        let r = base.appendingPathComponent("R", isDirectory: true)
        let t = base.appendingPathComponent("T", isDirectory: true)
        let other = base.appendingPathComponent("other", isDirectory: true)
        try fm.createDirectory(at: r.appendingPathComponent("plain"), withIntermediateDirectories: true)
        try fm.createDirectory(at: t.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: t.appendingPathComponent("sub/x.txt"))
        try Data().write(to: other.appendingPathComponent("o.md"))
        try fm.createSymbolicLink(at: r.appendingPathComponent("link"), withDestinationURL: t)
        return (base, r, t, other)
    }

    /// The left pane on `R`, the right on `other`, both walked and cached — no comparison, as the
    /// re-read after a write outside Compare runs. The table is empty: the link is an ordinary one.
    /// `leftRoot` is `R` as the pane is handed it — the fixture's canonical spelling by default.
    @MainActor
    private static func loadFolderLinkPanes(_ f: (base: URL, r: URL, t: URL, other: URL), leftRoot: String? = nil)
        async throws -> (m: FileSyncManager, left: CloudProvider, right: CloudProvider, x: FileNode) {
        let m = FileSyncManager()
        m.linkedFolders = [:]
        let leftRoot = leftRoot ?? f.r.path
        let left = CloudProvider(id: "L", displayName: "L", imageName: "folder", rootPath: leftRoot, type: .localFolder)
        let right = CloudProvider(id: "R", displayName: "R", imageName: "folder", rootPath: f.other.path,
                                  type: .localFolder)
        await m.refreshTreesAndScan(left: left, right: right, comparing: false)
        let walk = try #require(m.prefetchedTrees[leftRoot],
                                "premise: R's walk is not cached: \(m.prefetchedTrees.keys.sorted())")
        let x = try #require(Self.node(named: "x.txt", in: walk), "premise: R's walk does not reach through the link")
        try #require(!x.id.hasPrefix(leftRoot + "/"),
                     "premise: the id kept the link's spelling, so a prefix of R already holds it — nothing below is measured: \(x.id)")
        try #require(m.prefetchedTrees[f.other.path] != nil,
                     "premise: the control's walk is not cached — its survival below would prove nothing")
        return (m, left, right, x)
    }

    private static func node(named name: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.name == name { return node }
            if let hit = Self.node(named: name, in: node.children ?? []) { return hit }
        }
        return nil
    }

    /// **A walk that followed a folder link is dropped by a new file where the link leads.** A
    /// pane row's id names `T`, so a document opened from one and a file saved beside it do too,
    /// and no prefix of `R` matches either. Measured before this was fixed: the walk survived the
    /// write and the re-read pane was served the tree from before it. The control is the other
    /// pane's walk, which reaches nothing of `T`'s and stays.
    ///
    /// Twice: with `R` handed over canonically (`/private/var/…`), and spelled `/var/…`, the way
    /// `NSTemporaryDirectory()` spells it. The walk's ids come back `/private/var/…` either way, and
    /// the record is spelled `/var/…`; the write has to meet the record whichever spelling the
    /// pane's root was given in.
    @MainActor
    @Test(arguments: [false, true])
    func aWalkThatFollowedAFolderLinkIsDroppedByANewFileWhereItLeads(varSpelledRoot: Bool) async throws {
        let f = try Self.makeFolderLinkFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let leftRoot = varSpelledRoot ? String(f.r.path.dropFirst("/private".count)) : f.r.path
        try #require(!varSpelledRoot || (f.r.path.hasPrefix("/private/var/") && FileManager.default.fileExists(atPath: leftRoot)),
                     "premise: the temp root is not under /private/var — the /var spelling is not another spelling of it")
        let (m, left, right, x) = try await Self.loadFolderLinkPanes(f, leftRoot: leftRoot)
        let created = ((x.id as NSString).deletingLastPathComponent as NSString).appendingPathComponent("new.txt")
        try Data().write(to: URL(fileURLWithPath: created))

        // Control: unprepared, the one-pane re-read is served the cached walk.
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        #expect(m.leftNodes(for: [created]).isEmpty,
                "an unprepared re-read listed the file — the cache this test is about did not serve it")

        m.prepareReread(afterWritingAt: created)
        #expect(m.prefetchedTrees[leftRoot] == nil,
                "the walk that followed the link survived — it serves the tree from before the write")
        #expect(m.prefetchedTreeReadAt[leftRoot] == nil && m.prefetchedTreeLinkTargets[leftRoot] == nil,
                "the dropped walk's provenance survived it")
        #expect(m.prefetchedTrees[f.other.path] != nil, "the other pane's walk was dropped — it reaches nothing written")

        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        let node = try #require(m.leftNodes(for: [created]).first,
                                "the re-read pane does not list the file written where the link leads")
        #expect(node.id == created)
    }

    /// **…and by a rewrite of a file it lists there** — an autosave of a document opened from one
    /// of those rows, which saves under the row's id. The walk carries the old size, and the re-read
    /// pane, or a warm Compare, would go on showing it.
    @MainActor
    @Test func aWalkThatFollowedAFolderLinkIsDroppedByARewriteWhereItLeads() async throws {
        let f = try Self.makeFolderLinkFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let (m, left, right, x) = try await Self.loadFolderLinkPanes(f)
        try #require(x.fileSize == 1, "premise: the walk does not carry the file's size")
        try Data("xxxxxxxxxx".utf8).write(to: URL(fileURLWithPath: x.id))

        // Control: unprepared, the re-read is served the walk that carries the old size.
        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        #expect(m.leftNodes(for: [x.id]).first?.fileSize == 1,
                "an unprepared re-read saw the rewrite — the cache this test is about did not serve it")

        m.prepareReread(afterWritingAt: x.id)
        #expect(m.prefetchedTrees[f.r.path] == nil,
                "the walk that followed the link survived the rewrite — it carries the size from before it")
        #expect(m.prefetchedTrees[f.other.path] != nil, "the other pane's walk was dropped — it reaches nothing written")

        await m.refreshTreesAndScan(left: left, right: right, reloading: .leftOnly, comparing: false)
        #expect(m.leftNodes(for: [x.id]).first?.fileSize == 10,
                "the re-read pane still shows the size from before the rewrite")
    }

    /// **What a walk followed is all it is dropped for.** A write in the other pane's folder drops
    /// that walk and keeps `R`'s, whose recorded targets name `T` alone — so the record cannot have
    /// grown into "every folder outside the root".
    @MainActor
    @Test func aWalkThatFollowedAFolderLinkKeepsThroughAWriteElsewhere() async throws {
        let f = try Self.makeFolderLinkFixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let (m, _, _, _) = try await Self.loadFolderLinkPanes(f)
        let elsewhere = f.other.appendingPathComponent("p.md")
        try Data().write(to: elsewhere)
        m.prepareReread(afterWritingAt: elsewhere.path)
        #expect(m.prefetchedTrees[f.other.path] == nil, "the walk of the folder written in survived — the control is broken")
        #expect(m.prefetchedTrees[f.r.path] != nil, "R's walk was dropped by a write it does not reach")
        #expect(m.prefetchedTreeLinkTargets[f.r.path] != nil, "the kept walk lost its record of the link")
    }

    /// **The rule on paths: a folder holds what its walk followed a link to** — at a recorded
    /// target and below it, and not in a sibling sharing a target's opening. With nothing recorded
    /// the same folder holds nothing outside it, which is the answer the rule must differ from; an
    /// unset pane holds nothing whatever is passed. The two mechanisms compose: a link to a folder
    /// above iCloud Drive's container leads on to what the container links in. Synthetic paths;
    /// nothing is read from disk.
    @Test func aFolderHoldsWhatItsWalkFollowedALinkTo() {
        let file = "/t/sub/x.md"
        #expect(FileSyncManager.folder("/r", holds: file, links: [:], linkTargets: ["/t"]))
        #expect(FileSyncManager.folder("/r", holds: "/t", links: [:], linkTargets: ["/t"]),
                "the target's own top level — the folder a file written there is in")
        #expect(!FileSyncManager.folder("/r", holds: file, links: [:]),
                "with nothing recorded, a folder held a file outside it")
        #expect(!FileSyncManager.folder("/r", holds: "/t2/x.md", links: [:], linkTargets: ["/t"]),
                "a sibling sharing the target's opening was held")
        #expect(!FileSyncManager.folder("", holds: file, links: [:], linkTargets: ["/t"]),
                "an unset pane held a file through a walk it does not have")
        #expect(FileSyncManager.folder("/r", holds: "/r/link/sub/x.md", links: [:]),
                "the link's own spelling is a plain prefix — held before any of this")
        let table: PathBoundary.LinkedFolders = ["/lib/Mobile/c": ["Documents": "/h/Documents"]]
        #expect(FileSyncManager.folder("/r", holds: "/h/Documents/x.md", links: table, linkTargets: ["/lib"]),
                "a link to a folder above the container did not lead on to what the container links in")
    }
}
