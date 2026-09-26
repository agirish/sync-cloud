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
        for key in ["/c", "/h/Documents", "/h/Documents/Finance", "/h/Documents/Other", "/c/Pictures", "/h"] {
            m.prefetchedTrees[key] = []
        }
        let dropped = m.dropPrefetchedTrees(holding: "/h/Documents/Finance", links: links)
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
}
