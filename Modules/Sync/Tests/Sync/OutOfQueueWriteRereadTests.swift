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
}
