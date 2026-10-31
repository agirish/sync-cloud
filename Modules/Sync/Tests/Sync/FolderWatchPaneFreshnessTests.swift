import Foundation
import Testing
@testable import Sync

/// **"Changed since you looked", on the panes** — ROADMAP item 5's passive signal, end to end:
/// real folders, a real FSEvents stream, and writes from another process.
///
/// Each absence (a pane that must NOT flip) is asserted only after a positive control on the SAME
/// stream has proved the batch that would have flipped it was absorbed: FSEvents delivers one
/// stream's events in id order, so once a later change there has landed, an earlier one has too.
/// Two panes are two streams, with no order between them.
@Suite(.serialized) struct FolderWatchPaneFreshnessTests {

    private struct Fixture {
        let root: String
        let left: String
        let right: String
        var leftProvider: CloudProvider {
            CloudProvider(id: "L", displayName: "L", imageName: "folder", rootPath: left, type: .localFolder)
        }
        var rightProvider: CloudProvider {
            CloudProvider(id: "R", displayName: "R", imageName: "folder", rootPath: right, type: .localFolder)
        }
        func remove() { try? FileManager.default.removeItem(atPath: root) }
    }

    private static func makeFixture() throws -> Fixture {
        let root = FolderWatcherLiveTests.makeFolderPath("panes")
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/left/Finance", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/right", withIntermediateDirectories: true)
        try Data("a".utf8).write(to: URL(fileURLWithPath: root + "/left/Finance/a.txt"))
        return Fixture(root: root, left: root + "/left", right: root + "/right")
    }

    @MainActor
    private static func watchingManager(_ f: Fixture) async -> FileSyncManager {
        let m = FileSyncManager()
        m.enableFolderWatching(history: .inMemory(), latency: 0.05, quiet: 0.2, maxDelay: 2)
        await m.refreshTreesAndScan(left: f.leftProvider, right: f.rightProvider)
        return m
    }

    /// Both panes loaded. Their streams start from now (`FolderWatchReplay.none` — nothing cached
    /// relies on an older walk yet), so no rescan or replay is coming.
    @MainActor
    private static func settle(_ m: FileSyncManager) async {
        await waitUntil("the panes never loaded") { !m.isLoadingLeftTree && !m.isLoadingRightTree && !m.leftTree.isEmpty }
    }

    @MainActor
    @Test func anOutsideWriteMarksOnlyThePaneThatHoldsItAndARefreshClearsIt() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = await Self.watchingManager(f)
        defer { m.disableFolderWatching() }
        await Self.settle(m)
        var told: [FileSyncManager.PaneReloadScope] = []
        m.onPanesChangedOnDisk = { told.append($0) }
        #expect(!m.leftChangedOnDisk && !m.rightChangedOnDisk, "a fresh listing is already marked changed")
        #expect(m.prefetchedTrees[f.left] != nil && m.prefetchedTrees[f.right] != nil,
                "the panes' walks are not cached — the drop asserted below means nothing")

        try FolderWatcherLiveTests.touch(f.left + "/Finance/b.txt")
        await waitUntil("the write under the left pane never marked it", timeout: 10) { m.leftChangedOnDisk }
        #expect(!m.rightChangedOnDisk, "the right pane was marked for a write under the left")
        #expect(told == [.leftOnly])
        #expect(m.lastPaneNewsAt != nil)
        #expect(m.prefetchedTrees[f.left] == nil, "the left pane's walk survived a change it lists")
        #expect(m.prefetchedTrees[f.right] != nil, "the right pane's walk was dropped for a change it does not list")

        // A listing that starts after the change is clear of it.
        await m.refreshTreesAndScan(left: f.leftProvider, right: f.rightProvider)
        #expect(!m.leftChangedOnDisk, "a walk started after the change still reads as changed")
        let finance = try #require(m.leftTree.first { $0.name == "Finance" })
        #expect(finance.children?.map(\.name).sorted() == ["a.txt", "b.txt"])
    }

    /// **Our own writes and hidden noise leave the pane alone, against real FSEvents** — the app
    /// accounts for its own writes, and Finder's `.DS_Store` is no row a hidden-files-off pane shows.
    /// The control is on the same stream: a hidden change still drops the cached walk, so once the
    /// walk is gone the `.DS_Store` event has been absorbed, and the own write before it too.
    @MainActor
    @Test func ourOwnWritesAndHiddenFilesDoNotMarkThePane() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = await Self.watchingManager(f)
        defer { m.disableFolderWatching() }
        await Self.settle(m)
        try #require(m.prefetchedTrees[f.left] != nil, "the left walk is not cached — the control below cannot fire")

        try Data("mine".utf8).write(to: URL(fileURLWithPath: f.left + "/Finance/mine.txt"))
        try FolderWatcherLiveTests.touch(f.left + "/.DS_Store")
        await waitUntil("the hidden change was never absorbed", timeout: 10) { m.prefetchedTrees[f.left] == nil }
        #expect(!m.leftChangedOnDisk, "our own write or a hidden file marked the left pane")

        // And shown, the hidden change that already happened is news — no new write needed.
        m.showHiddenFiles = true
        #expect(m.leftChangedOnDisk, "showing hidden files revealed a changed hidden item with no warning")
    }

    /// **The same two filters, deterministically**: each pair is one change to the same path, at the
    /// same id, as an outside visible write (which must mark — the control) and as the thing that
    /// must not. With the filter removed, the second case marks exactly like the first.
    @MainActor
    @Test func ownAndHiddenChangesAreFilteredAgainstAControl() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        func change(_ m: FileSyncManager, _ path: String, own: Bool) throws {
            let mark = try #require(m.leftWatch.readMark)
            m.absorbFolderChanges(FolderWatchBatch(events: [
                FolderWatchEvent(id: mark + 1, root: f.left, path: path, realPath: path, change: [.modified], isOwn: own)]))
        }
        for (path, own, label) in [(f.left + "/Finance/x.txt", true, "own"), (f.left + "/Finance/.DS_Store", false, "hidden")] {
            let control = await Self.watchingManager(f)
            await Self.settle(control)
            try change(control, f.left + "/Finance/x.txt", own: false)
            #expect(control.leftChangedOnDisk, "the control (an outside visible change) did not mark — \(label) proves nothing")
            control.disableFolderWatching()

            let m = await Self.watchingManager(f)
            await Self.settle(m)
            try change(m, path, own: own)
            #expect(!m.leftChangedOnDisk, "an \(label) change marked the pane")
            m.disableFolderWatching()
        }
    }

    /// **The order is by FSEvents id, not by arrival.** A change older than the walk is no news to
    /// it however late it is delivered; one newer is. Driven through `absorbFolderChanges` with the
    /// ids placed either side of the left pane's read mark.
    @MainActor
    @Test func aChangeIsOrderedAgainstTheWalkByItsId() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = await Self.watchingManager(f)
        defer { m.disableFolderWatching() }
        await Self.settle(m)
        let mark = try #require(m.leftWatch.readMark)
        let path = f.left + "/Finance/x.txt"
        func event(_ id: UInt64) -> FolderWatchEvent {
            FolderWatchEvent(id: id, root: f.left, path: path, realPath: path, change: [.modified, .isFile])
        }
        let epoch = m.scanConfigGeneration
        m.absorbFolderChanges(FolderWatchBatch(events: [event(mark)]))
        #expect(!m.leftChangedOnDisk, "a change made before the walk began marked it")
        // A replay is mostly such changes; bumping the epoch for them would leave the walk in
        // flight after every navigation uncached.
        #expect(m.scanConfigGeneration == epoch, "a change the walk had already seen bumped the scan epoch")
        #expect(m.prefetchedTrees[f.left] != nil, "a change the walk had already seen dropped it")
        m.absorbFolderChanges(FolderWatchBatch(events: [event(mark + 1)]))
        #expect(m.leftChangedOnDisk, "a change made after the walk began did not mark it")
        #expect(m.scanConfigGeneration == epoch + 1)
        #expect(m.prefetchedTrees[f.left] == nil)
    }

    /// **The app hears nothing while a refresh runs** — its answer is a refresh, which would cancel
    /// and restart that one — and hears it once that refresh lets go, through the refresh's own end
    /// (`refreshTreesAndScan`), not a hand call. The change lands inside the refresh, as its left
    /// load starts (`folderWatchLoadWitness`), and is dated far past any walk, so the refresh leaves
    /// the pane stale and the held news must come out at its end.
    @MainActor
    @Test func newsWaitsForTheRefreshInFlight() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = await Self.watchingManager(f)
        defer { m.disableFolderWatching() }
        await Self.settle(m)
        var told: [FileSyncManager.PaneReloadScope] = []
        m.onPanesChangedOnDisk = { told.append($0) }
        let path = f.left + "/Finance/x.txt"
        let future = FolderWatcher.currentEventId() + 1_000_000_000
        var heldWhileRunning: [FileSyncManager.PaneReloadScope]?
        m.folderWatchLoadWitness = { [unowned m] isLeft in
            guard isLeft, heldWhileRunning == nil else { return }
            #expect(m.activeRefreshKey != nil, "the witness ran outside a refresh — this tests nothing")
            m.absorbFolderChanges(FolderWatchBatch(events: [
                FolderWatchEvent(id: future, root: f.left, path: path, realPath: path, change: [.modified])]))
            heldWhileRunning = told
        }

        m.prepareForcedRescan()
        await m.refreshTreesAndScan(left: f.leftProvider, right: f.rightProvider)
        #expect(heldWhileRunning == [], "the app was told while a refresh ran (nil: the change never landed)")
        #expect(m.leftChangedOnDisk, "the change is dated past every walk — the pane must still be stale")
        #expect(told == [.leftOnly], "the refresh's end did not deliver the held news")
        m.tellOwedPaneChanges()
        #expect(told == [.leftOnly], "the held news was delivered twice")
    }

    /// **One telling per `paneNewsInterval`**, however busy the folder: a second change inside the
    /// interval is held, and delivered when the interval runs out — not dropped.
    @MainActor
    @Test func newsComesNoOftenerThanTheInterval() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = await Self.watchingManager(f)
        defer { m.disableFolderWatching() }
        await Self.settle(m)
        m.paneNewsInterval = 1
        var told: [FileSyncManager.PaneReloadScope] = []
        m.onPanesChangedOnDisk = { told.append($0) }
        let left = f.left + "/Finance/x.txt", right = f.right + "/y.txt"
        let mark = max(m.leftWatch.readMark ?? 0, m.rightWatch.readMark ?? 0)
        m.absorbFolderChanges(FolderWatchBatch(events: [
            FolderWatchEvent(id: mark + 1, root: f.left, path: left, realPath: left, change: [.modified])]))
        m.absorbFolderChanges(FolderWatchBatch(events: [
            FolderWatchEvent(id: mark + 2, root: f.right, path: right, realPath: right, change: [.modified])]))
        #expect(told == [.leftOnly], "the second change inside the interval was not held")
        await waitUntil("the held change never came out when the interval ran out", timeout: 10) { told.count == 2 }
        #expect(told == [.leftOnly, .rightOnly])
    }

    /// **A cache hit is dated by the walk it serves, not by the hit.** A change made after that walk
    /// but delivered after the hit must still mark the pane — which it can only do if the pane's mark
    /// is the walk's. Also for a slice of the cached root, which is part of the root's walk.
    @MainActor
    @Test func aCacheHitKeepsTheMarkOfTheWalkItServes() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = await Self.watchingManager(f)
        defer { m.disableFolderWatching() }
        await Self.settle(m)
        let walked = try #require(m.prefetchedTreeReadMark[f.left], "the left walk carries no mark")
        #expect(m.leftWatch.readMark == walked)
        // Move the id clock past the walk with a change outside both panes, so a hit stamped "now"
        // and one stamped with the walk's id cannot coincide.
        let elsewhere = FolderWatcherLiveTests.makeFolderPath("clock")
        defer { try? FileManager.default.removeItem(atPath: elsewhere) }
        try FolderWatcherLiveTests.touch(elsewhere)
        await waitUntil("the FSEvents id never moved past the walk") { FolderWatcher.currentEventId() > walked }
        await m.refreshTreesAndScan(left: f.leftProvider, right: f.rightProvider)
        #expect(m.leftWatch.readMark == walked, "a cache hit took the id of the moment it was served")

        m.leftRelativePath = "Finance"
        await m.loadTree(path: f.left, isLeft: true)
        #expect(m.leftTree.map(\.name) == ["a.txt"], "the slice did not load")
        #expect(m.leftWatch.readMark == walked, "a slice of the cached root did not inherit the root's mark")
    }

    /// **The walk kept across a source switch keeps its mark** (`dropPrefetchedTrees(keeping:)`).
    @MainActor
    @Test func aKeptWalkKeepsItsMark() async throws {
        let m = FileSyncManager()
        m.prefetchedTrees = ["/a": [], "/b": []]
        m.prefetchedTreeReadMark = ["/a": 7, "/b": 9]
        m.dropPrefetchedTrees(keeping: "/a")
        #expect(m.prefetchedTreeReadMark == ["/a": 7])
    }

    /// **A folder that went takes the walks below it** — no event of theirs will say so — and only
    /// those older than the change.
    @MainActor
    @Test func aRemovedFolderDropsTheWalksBelowIt() async throws {
        let m = FileSyncManager()
        m.linkedFolders = [:]
        m.prefetchedTrees = ["/r": [], "/r/sub": [], "/r/sub/deep": [], "/other": []]
        m.prefetchedTreeReadMark = ["/r": 50, "/r/sub": 5, "/r/sub/deep": 5, "/other": 5]
        let dropped = m.dropPrefetchedTrees(changedBy: [(["/r/sub"], true, 10)])
        #expect(dropped == 2)
        #expect(Set(m.prefetchedTrees.keys) == ["/r", "/other"], "the parent's walk is newer than the change and must stay")
        // Without `below`, only walks LISTING the path go — and its own walk lists it ("" tail).
        m.prefetchedTrees["/r/sub/deep"] = []; m.prefetchedTreeReadMark["/r/sub/deep"] = 5
        #expect(m.dropPrefetchedTrees(changedBy: [(["/r/sub"], false, 10)]) == 0)
        #expect(m.dropPrefetchedTrees(changedBy: [(["/r/sub/deep/f"], false, 10)]) == 1)
    }

    /// **A stream started for a folder a cached walk lists through a link replays from that walk.**
    /// The iCloud Drive container's walk lists `~/Documents` through its link; when a pane returns to
    /// the container and `~/Documents` is watched again, its stream must replay from the container's
    /// walk, or a change made there meanwhile is lost.
    @MainActor
    @Test func aLinkedTargetReplaysFromTheWalkThatListsIt() async throws {
        let m = FileSyncManager()
        m.linkedFolders = ["/c": ["Documents": "/real/Documents"]]
        m.prefetchedTrees = ["/c": [], "/elsewhere": []]
        m.prefetchedTreeReadMark = ["/c": 40, "/elsewhere": 3]
        #expect(m.folderWatchReplayMark(for: FolderWatchRoot(path: "/real/Documents")) == 40)
        #expect(m.folderWatchReplayMark(for: FolderWatchRoot(path: "/real/Documents/Tax")) == 40)
        #expect(m.folderWatchReplayMark(for: FolderWatchRoot(path: "/unrelated")) == nil)
    }

    /// **A rescan marks every pane at, under or above the folder it names** — FSEvents could not
    /// say what changed there, so nothing listed there is vouched for.
    @MainActor
    @Test func aRescanAboveAPaneMarksIt() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = await Self.watchingManager(f)
        defer { m.disableFolderWatching() }
        await Self.settle(m)
        let id = max(m.leftWatch.readMark ?? 0, m.rightWatch.readMark ?? 0) + 1
        try #require(!m.prefetchedTrees.isEmpty, "nothing is cached — the drop below cannot fail")
        m.absorbFolderChanges(FolderWatchBatch(rescans: [
            FolderWatchRescan(root: f.root, path: f.root, reason: .mustScanSubDirs, id: id)]))
        #expect(m.leftChangedOnDisk && m.rightChangedOnDisk)
        #expect(m.prefetchedTrees.isEmpty, "a walk under the rescanned folder survived: \(m.prefetchedTrees.keys.sorted())")
    }

    /// **A pane on a symlinked folder hears a write made through the real path.**
    @MainActor
    @Test func aPaneOnALinkHearsAWriteToItsTarget() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let link = f.root + "/link-to-left"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: f.left)
        let m = FileSyncManager()
        m.enableFolderWatching(history: .inMemory(), latency: 0.05, quiet: 0.2, maxDelay: 2)
        defer { m.disableFolderWatching() }
        let linked = CloudProvider(id: "K", displayName: "K", imageName: "folder", rootPath: link, type: .localFolder)
        await m.refreshTreesAndScan(left: linked, right: f.rightProvider)
        await Self.settle(m)
        #expect(!m.leftChangedOnDisk)

        let real = try #require(FolderWatcher.resolve(f.left))
        try FolderWatcherLiveTests.touch(real + "/Finance/through-the-target.txt")
        await waitUntil("a write to the link's target never marked the pane on the link", timeout: 10) {
            m.leftChangedOnDisk
        }
    }

    /// **Swapping panes swaps what the watcher said about them**: the mark belongs to the listing.
    @MainActor
    @Test func aSwapMovesTheMarkWithTheListing() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = await Self.watchingManager(f)
        defer { m.disableFolderWatching() }
        await Self.settle(m)
        let mark = try #require(m.leftWatch.readMark)
        let path = f.left + "/Finance/x.txt"
        m.absorbFolderChanges(FolderWatchBatch(events: [
            FolderWatchEvent(id: mark + 1, root: f.left, path: path, realPath: path, change: [.modified])]))
        try #require(m.leftChangedOnDisk && !m.rightChangedOnDisk)
        m.swapPanes()
        #expect(m.rightChangedOnDisk && !m.leftChangedOnDisk)
    }

    /// **Nothing watching, nothing claimed** — and turning watching off clears what was said.
    @MainActor
    @Test func withoutAWatcherNothingIsEverMarked() async throws {
        let f = try Self.makeFixture()
        defer { f.remove() }
        let m = FileSyncManager()
        await m.refreshTreesAndScan(left: f.leftProvider, right: f.rightProvider)
        await Self.settle(m)
        let mark = try #require(m.leftWatch.readMark, "the walk took no mark — the absence below is vacuous")
        let path = f.left + "/Finance/x.txt"
        m.absorbFolderChanges(FolderWatchBatch(events: [
            FolderWatchEvent(id: mark + 1, root: f.left, path: path, realPath: path, change: [.modified])]))
        #expect(!m.leftChangedOnDisk)

        m.enableFolderWatching(history: .inMemory())
        m.absorbFolderChanges(FolderWatchBatch(events: [
            FolderWatchEvent(id: mark + 1, root: f.left, path: path, realPath: path, change: [.modified])]))
        #expect(m.leftChangedOnDisk, "the control: the same batch with a watcher marks the pane")
        m.disableFolderWatching()
        #expect(!m.leftChangedOnDisk)
    }
}

extension FolderWatcherLiveTests {
    /// A unique temp folder path (not created), spelled under `/var` as `NSTemporaryDirectory` is.
    static func makeFolderPath(_ name: String) -> String {
        PathBoundary.normalizedRoot((NSTemporaryDirectory() as NSString)
            .appendingPathComponent("synccloud-watch-\(name)-\(UUID().uuidString)"))
    }
}
