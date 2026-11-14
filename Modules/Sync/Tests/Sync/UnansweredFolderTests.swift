import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// A folder whose provider never answers must not stop the comparison
/// (`FileSyncManager.DatalessFolderReads`). With OneDrive not running, listing a dataless folder
/// such as its `.Trash` blocks forever: a walk that waits on it never compares, and each Refresh
/// that reads it again blocks one more pool thread until the other pane stops loading too.
///
/// The double: one folder is dataless, and listing it parks until the test releases it (the
/// provider answering). Everything else is an ordinary `MockFileManager`.
@Suite struct UnansweredFolderTests {

    /// One disk per test, under its own root: the cases run in parallel, log the same sentence, and
    /// a `LogCapture` hears them all, so a shared path would let another test's line pass this one.
    ///
    /// Left: `<root>/home`, holding the folder that doesn't answer. Right: `<root>/other`, with one
    /// file the left lacks (`Notes/c.txt`, proving the comparison ran) and the same file in its
    /// `Archive` as the left's unread one holds (a row that must not appear).
    struct Fixture {
        let root: String

        var home: CloudProvider { provider("home", at: "/home") }
        var other: CloudProvider { provider("other", at: "/other") }
        var elsewhere: CloudProvider { provider("elsewhere", at: "/elsewhere") }
        /// Not a dot-folder: hidden rows are filtered out of `differences` anyway, so a hidden name
        /// would let "nothing under it is reported missing" pass whether or not the walk marked it.
        var unanswered: String { root + "/home/Cloud/Archive" }

        func provider(_ id: String, at path: String) -> CloudProvider {
            CloudProvider(id: id, displayName: id, imageName: "folder", rootPath: root + path, type: .localFolder)
        }

        /// `reads` is the registry the disk's listings ask through. Pass the manager's, so the test
        /// has one registry, as the app does.
        func disk(gate: ParkGate,
                  reads: FileSyncManager.DatalessFolderReads = .init(deadline: .milliseconds(250))) throws -> UnansweredFolderDisk {
            let mock = MockFileManager()
            for dir in ["/home", "/home/Notes", "/home/Cloud", "/home/Cloud/Archive", "/home/Cloud/Docs",
                        "/other", "/other/Notes", "/other/Cloud", "/other/Cloud/Archive", "/other/Cloud/Docs",
                        "/elsewhere"] {
                try mock.createDirectory(at: URL(fileURLWithPath: root + dir), withIntermediateDirectories: true)
            }
            for file in ["/home/Notes/a.txt", "/home/Cloud/Archive/old.txt", "/home/Cloud/Docs/b.txt",
                         "/other/Notes/a.txt", "/other/Notes/c.txt", "/other/Cloud/Archive/old.txt",
                         "/other/Cloud/Docs/b.txt"] {
                mock.setStub(MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil), at: root + file)
            }
            return UnansweredFolderDisk(inner: mock, unanswered: unanswered, gate: gate, reads: reads)
        }

        /// A manager over this fixture's disk, sharing its registry, with the gate the unanswered
        /// folder parks on.
        @MainActor
        func manager(deadline: Duration = .milliseconds(250)) throws
        -> (manager: FileSyncManager, gate: ParkGate, disk: UnansweredFolderDisk, reads: FileSyncManager.DatalessFolderReads) {
            let gate = ParkGate()
            let reads = FileSyncManager.DatalessFolderReads(deadline: deadline)
            let disk = try disk(gate: gate, reads: reads)
            let manager = FileSyncManager(fileManager: disk)
            manager.datalessFolderReads = reads
            return (manager, gate, disk, reads)
        }
    }

    private static func node(_ path: String, in tree: [FileNode]) -> FileNode? {
        for node in tree {
            if node.id == path { return node }
            if let found = Self.node(path, in: node.children ?? []) { return found }
        }
        return nil
    }

    // MARK: - The pane walk

    /// The refresh compares while the folder's listing is still out, and the folder comes back
    /// unexplored: nothing under it is reported missing, and everything else still is.
    @MainActor
    @Test(.parksAThread) func aFolderThatNeverAnswersStillLetsTheRefreshCompare() async throws {
        let f = Fixture(root: "/refresh")
        let (manager, gate, _, reads) = try f.manager()
        let log = LogCapture()

        let refresh = Task { await manager.refreshTreesAndScan(left: f.home, right: f.other) }
        await awaitSignal(gate.entered, "the walk never reached the folder that does not answer")

        await waitUntil("the comparison ran while the folder's listing was still out") { manager.hasScanned }
        #expect(gate.isParked, "the listing came back on its own — this measured a folder that answered")
        #expect(reads.isOutstanding(f.unanswered))
        #expect(manager.differences.map(\.relativePath) == ["Notes/c.txt"],
                "only the file the left really lacks — nothing under the folder it could not read")
        let archive = try #require(Self.node(f.unanswered, in: manager.rawLeftTree))
        #expect(archive.isUnexplored == true, "a folder that did not answer is unknown, not empty")
        #expect(await log.holds(.warning, containing: "“\(f.unanswered)” did not answer"))
        // Not also called unreadable: that line says "permission denied", and would send a reader
        // to the folder's permissions instead of the app that syncs it.
        #expect(!(await log.holds(containing: "could not list “\(f.unanswered)”")))

        // The provider answers at last: the held read comes back and leaves the registry.
        gate.release.signal()
        await refresh.value
        await waitUntil("the late answer came back") { !reads.isOutstanding(f.unanswered) }
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// A Refresh doesn't read an unanswered folder again, or each click would block one more pool
    /// thread. Once the provider answers, the next Refresh reads it like any other: the deadline
    /// deferred it, not dropped it.
    @MainActor
    @Test(.parksAThread) func aRefreshSkipsAFolderStillUnansweredAndReadsItOnceItAnswers() async throws {
        let f = Fixture(root: "/skip")
        let (manager, gate, disk, reads) = try f.manager()

        await manager.refreshTreesAndScan(left: f.home, right: f.other)
        await awaitSignal(gate.entered, "the walk never reached the folder that does not answer")
        #expect(manager.hasScanned)
        #expect(disk.providerReads == 1)

        // Three more Refreshes, each a full re-walk (the cache dropped, as the toolbar's does).
        for _ in 0..<3 {
            let compared = try #require(manager.lastScanDate)
            manager.prepareForcedRescan()
            await manager.refreshTreesAndScan(left: f.home, right: f.other)
            let comparedAgain = try #require(manager.lastScanDate)
            #expect(comparedAgain > compared, "the Refresh did not compare again")
        }
        #expect(disk.providerReads == 1, "a Refresh started another read of a folder already not answering")
        #expect(Self.node(f.unanswered, in: manager.rawLeftTree)?.isUnexplored == true)
        #expect(gate.isParked)

        // Answered: the folder is on disk now, and the next walk lists it.
        gate.release.signal()
        await waitUntil("the late answer came back") { !reads.isOutstanding(f.unanswered) }
        manager.prepareForcedRescan()
        await manager.refreshTreesAndScan(left: f.home, right: f.other)
        let archive = try #require(Self.node(f.unanswered, in: manager.rawLeftTree))
        #expect(archive.isUnexplored != true)
        #expect(archive.children?.map(\.name) == ["old.txt"])
        #expect(manager.differences.map(\.relativePath) == ["Notes/c.txt"])
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// A pane whose root doesn't answer is unknown, not empty. The walk hands back the folder itself
    /// marked unexplored, the shape of an unlistable root (`isUnreadableRootWalk`); a bare `[]`
    /// would report every file opposite as missing. That shape also stops a source switch keeping
    /// the walk, and the next walk asks again without a second provider read.
    @MainActor
    @Test(.parksAThread) func aPaneRootThatNeverAnswersIsUnknownAndIsNotKept() async throws {
        let f = Fixture(root: "/rootpane")
        let (manager, gate, disk, reads) = try f.manager()
        // Both panes on an `Archive`; the left one is the folder that does not answer.
        let left = f.provider("left", at: "/home/Cloud/Archive")
        let right = f.provider("right", at: "/other/Cloud/Archive")

        await manager.refreshTreesAndScan(left: left, right: right)
        await awaitSignal(gate.entered, "the walk never reached the folder that does not answer")
        #expect(manager.hasScanned, "the refresh did not compare")
        #expect(manager.differences.isEmpty, "a file was reported missing from a folder nobody could read")
        #expect(manager.lastScanCoverage.left, "the comparison must say the left side went unread")
        let walk = try #require(manager.prefetchedTrees[f.unanswered])
        #expect(FileSyncManager.isUnreadableRootWalk(walk, at: f.unanswered))

        // A switch of the other pane does not keep it…
        manager.dropPrefetchedTrees(keeping: f.unanswered)
        #expect(manager.prefetchedTrees[f.unanswered] == nil, "a walk that read nothing was kept")
        // …and the walk after it asks again without asking the provider again.
        await manager.refreshTreesAndScan(left: left, right: right)
        #expect(disk.providerReads == 1, "the folder was read a second time while still unanswered")
        #expect(manager.differences.isEmpty)
        #expect(gate.isParked)

        gate.release.signal()
        await waitUntil("the late answer came back") { !reads.isOutstanding(f.unanswered) }
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// A walk superseded while it waits lets go at once, rather than sitting out the deadline:
    /// navigating away must not cost the old walk's wait. The deadline is far past the test's bound,
    /// so only stopping on cancel can meet it.
    @MainActor
    @Test(.parksAThread) func aSupersededWalkStopsWaitingForTheFolder() async throws {
        let f = Fixture(root: "/supersede")
        let (manager, gate, _, _) = try f.manager(deadline: .seconds(60))

        let first = Task { await manager.refreshTreesAndScan(left: f.home, right: f.other) }
        await awaitSignal(gate.entered, "the walk never reached the folder that does not answer")

        // Ten seconds and the turn floor, not seconds alone: main-actor load can stretch a correct
        // run past ten seconds (`docs/flaky-tests.md`, "A park's bound counted seconds while its
        // release waited for scheduler turns"), and sitting out the deadline costs sixty seconds
        // and far more turns.
        let budget = TurnDeadline(seconds: 10, turns: signalTurnFloor)
        await manager.refreshTreesAndScan(left: f.elsewhere, right: f.other)
        await first.value
        #expect(!budget.hasPassed,
                "the superseded walk waited for the folder instead of unwinding — \(budget.spent)")
        #expect(manager.hasScanned, "the refresh that superseded it did not compare")
        #expect(gate.isParked)

        gate.release.signal()
        await waitUntil("the late answer came back") { !manager.datalessFolderReads.isOutstanding(f.unanswered) }
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    // MARK: - The comparison's disk walk

    /// The scan's own walk gives up on the folder too. With no cached pane walk (as on arrival in
    /// Compare, a direct `scanDirectories`), the scan walks the disk with a `DirectoryEnumerator`,
    /// which would block descending into the folder.
    @MainActor
    @Test(.parksAThread) func theComparisonsOwnWalkGivesUpOnTheFolderToo() async throws {
        let f = Fixture(root: "/coldscan")
        let (manager, gate, _, reads) = try f.manager()
        #expect(manager.prefetchedTrees.isEmpty, "a cached tree would take the other branch")

        let scan = Task {
            await manager.scanDirectories(left: f.home, leftPath: f.home.rootPath,
                                          right: f.other, rightPath: f.other.rootPath)
        }
        await awaitSignal(gate.entered, "the scan never reached the folder that does not answer")
        await waitUntil("the comparison finished while the folder's listing was still out") { manager.hasScanned }
        #expect(gate.isParked)
        #expect(manager.differences.map(\.relativePath) == ["Notes/c.txt"])

        gate.release.signal()
        await scan.value
        await waitUntil("the late answer came back") { !reads.isOutstanding(f.unanswered) }
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// A cancelled comparison stops waiting too. That walk waits on its thread and can't suspend,
    /// so it must notice the cancel itself, or Stop would sit out the deadline holding the slot.
    @MainActor
    @Test(.parksAThread) func aCancelledComparisonStopsWaitingForTheFolder() async throws {
        let f = Fixture(root: "/cancel")
        let (manager, gate, _, _) = try f.manager(deadline: .seconds(60))

        let scan = Task {
            await manager.scanDirectories(left: f.home, leftPath: f.home.rootPath,
                                          right: f.other, rightPath: f.other.rootPath)
        }
        await awaitSignal(gate.entered, "the scan never reached the folder that does not answer")
        // In seconds AND turns, for the reason `aSupersededWalkStopsWaitingForTheFolder` gives.
        let budget = TurnDeadline(seconds: 10, turns: signalTurnFloor)
        scan.cancel()
        await scan.value
        #expect(!budget.hasPassed,
                "the cancelled scan waited for the folder instead of stopping — \(budget.spent)")
        #expect(!manager.isScanning)
        #expect(!manager.hasScanned, "a cancelled scan published")

        gate.release.signal()
        await waitUntil("the late answer came back") { !manager.datalessFolderReads.isOutstanding(f.unanswered) }
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// The same walk, read directly: the folder's entry is there, marked unexplored, with nothing
    /// below it, since it was never listed.
    @Test(.parksAThread) func theDiskWalkMarksTheFolderUnexploredAndListsNothingBelowIt() async throws {
        let f = Fixture(root: "/diskwalk")
        let gate = ParkGate()
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))
        let disk = try f.disk(gate: gate, reads: reads)

        let walk = Task.detached {
            try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: f.home.rootPath), fileManager: disk,
                                                   datalessReads: reads)
        }
        await awaitSignal(gate.entered, "the walk never reached the folder that does not answer")
        let info = try await walk.value
        #expect(gate.isParked)
        #expect(info["Cloud/Archive"]?.isUnexplored == true)
        #expect(info["Cloud/Archive/old.txt"] == nil)
        #expect(info["Cloud/Docs/b.txt"] != nil, "the folder beside it was walked as usual")

        gate.release.signal()
        await awaitAnswered(reads, path: f.unanswered)
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    // MARK: - The registry

    /// One folder is one read, however the walk reached it. The Home pane can reach a OneDrive
    /// folder through its link in the home folder and again under `~/Library/CloudStorage/…`; read
    /// once per spelling, an unanswered folder would hold two threads and cost two waits.
    @Test(.parksAThread) func aFolderReachedThroughALinkIsTheReadAlreadyOut() async throws {
        let root = try makeCanonicalTempRoot(prefix: "dataless-spelling")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let gate = ParkGate()
        let listings = LockedBox(0)
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))
        let throughTheLink = await reads.read(link.path) {
            listings.withLock { $0 += 1 }
            gate.park(timeout: 30)
            return 1
        }
        #expect(throughTheLink == nil, "the read was meant to go unanswered")
        let throughTheFolder = await reads.read(real.path) {
            listings.withLock { $0 += 1 }
            return 2
        }
        #expect(throughTheFolder == nil, "the folder is still unanswered, under its other spelling")
        #expect(listings.withLock { $0 } == 1, "the same folder was asked for twice")

        gate.release.signal()
        await awaitAnswered(reads, path: real.path)
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// When the app that syncs a folder launches, its unanswered folders are forgotten (a read asked
    /// of the process that quit may never return) and read again. Another app's stay.
    @Test(.parksThreads(2)) func aLaunchedAppsUnansweredFoldersAreReadAgain() async throws {
        let root = try makeCanonicalTempRoot(prefix: "dataless-forget")
        defer { try? FileManager.default.removeItem(at: root) }
        let oneDrive = root.appendingPathComponent("OneDrive")
        let stuck = oneDrive.appendingPathComponent("Projects"), other = root.appendingPathComponent("Dropbox/Stuck")
        for folder in [stuck, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        let gate = ParkGate()
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(100))
        #expect(await reads.read(stuck.path) { gate.park(timeout: 30); return 1 } == nil)
        #expect(await reads.read(other.path) { gate.park(timeout: 30); return 2 } == nil)
        #expect(reads.unansweredPaths().count == 2)

        #expect(reads.forgetUnanswered(under: [oneDrive.path]) == 1)
        // The registry keeps a folder by its resolved spelling (`/var/…` for `/private/var/…`).
        #expect(reads.unansweredPaths() == [other.resolvingSymlinksInPath().path])
        #expect(await reads.read(stuck.path) { 3 } == 3, "a forgotten folder was not read again")

        gate.release.signal()
        gate.release.signal()
        await awaitAnswered(reads, path: other.path)
    }
}

/// Waits, bounded, for `reads` to stop holding `path` outstanding: the late answer a released
/// provider sends back. Off the main actor, for the tests that are not on it.
func awaitAnswered(_ reads: FileSyncManager.DatalessFolderReads, path: String,
                   sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while reads.isOutstanding(path), ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(!reads.isOutstanding(path), "the late answer never came back", sourceLocation: sourceLocation)
}

/// A disk with one dataless folder whose provider isn't answering: listing it, directly or by an
/// enumerator descending into it, parks on `gate` until the test releases it. Released, it is
/// materialized as a real listing leaves it: no longer dataless, and listed at once.
///
/// Like the real one, the recursive enumerator descends lazily: it reads a folder's contents on
/// the call after the one that yielded it, so `skipDescendants()` in between never asks the
/// provider. It marks folder entries (`hasDirectoryPath`) in absolute and relative spellings, as
/// the real one does (`theRealEnumeratorMarksEveryFolderItYields`).
///
/// Its listings ask through `datalessFolderReads`, a short-deadline registry passed in, so a test
/// never waits out the app's five seconds or touches `DatalessFolderReads.shared`.
final class UnansweredFolderDisk: ForwardingFileManaging<MockFileManager>, @unchecked Sendable {
    private let unanswered: String
    private let gate: ParkGate
    private let folderReads: FileSyncManager.DatalessFolderReads
    private let lock = NSLock()
    private var reads = 0
    private var readQueues: [String] = []
    private var answered = false

    init(inner: MockFileManager, unanswered: String, gate: ParkGate,
         reads: FileSyncManager.DatalessFolderReads = .init(deadline: .milliseconds(250))) {
        self.unanswered = unanswered
        self.gate = gate
        self.folderReads = reads
        super.init(inner: inner)
    }

    override var datalessFolderReads: FileSyncManager.DatalessFolderReads { folderReads }

    /// How many times something asked the provider for the folder's contents.
    var providerReads: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    /// The dispatch queue each ask ran on. It must never be the cooperative pool's
    /// (`com.apple.root.*.cooperative`).
    var providerReadQueues: [String] {
        lock.lock(); defer { lock.unlock() }
        return readQueues
    }

    override func isDataless(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return url.path == unanswered && !answered
    }

    /// One listing of the dataless folder: the provider is asked, and the call parks until it answers.
    fileprivate func askTheProvider() {
        let queue = String(cString: __dispatch_queue_get_label(nil))
        lock.lock()
        guard !answered else { lock.unlock(); return }
        reads += 1
        readQueues.append(queue)
        lock.unlock()
        // Two minutes, so "still parked" holds on a loaded machine. The tests release it
        // themselves; only a caller blocked on it ever waits this out.
        gate.park(timeout: 120)
        lock.lock(); answered = true; lock.unlock()
    }

    override func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?,
                             options m: FileManager.DirectoryEnumerationOptions,
                             errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        if u.path == unanswered { askTheProvider() }
        let listing = inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        guard !m.contains(.skipsSubdirectoryDescendants), let listing else { return listing }
        let entries = listing.allObjects.compactMap { $0 as? URL }.map(markingFolders)
        return DescendingEnumerator(entries: entries, unanswered: unanswered, disk: self)
    }

    /// The entry as the real enumerator spells it: a folder's URL says it is one.
    private func markingFolders(_ entry: URL) -> URL {
        var isDirectory: ObjCBool = false
        guard inner.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return entry
        }
        if let base = entry.baseURL {
            return URL(fileURLWithPath: entry.relativePath, isDirectory: true, relativeTo: base)
        }
        return URL(fileURLWithPath: entry.path, isDirectory: true)
    }

    /// A recursive listing that reads the dataless folder's contents only when it descends into it.
    private final class DescendingEnumerator: FileManager.DirectoryEnumerator {
        private let entries: [URL]
        private let unanswered: String
        private let disk: UnansweredFolderDisk
        private var index = 0
        /// The folder just yielded, until the next call decides whether to descend into it.
        private var justYielded: String?
        private var skipping: String?

        init(entries: [URL], unanswered: String, disk: UnansweredFolderDisk) {
            self.entries = entries
            self.unanswered = unanswered
            self.disk = disk
        }

        override func skipDescendants() { skipping = justYielded }

        override func nextObject() -> Any? {
            if let folder = justYielded {
                justYielded = nil
                // Descending into the dataless folder reads it, unless the caller skipped it.
                if folder == unanswered, skipping != folder { disk.askTheProvider() }
            }
            while index < entries.count {
                let entry = entries[index]
                index += 1
                if let skipped = skipping, entry.path.hasPrefix(skipped + "/") { continue }
                justYielded = entry.path
                return entry
            }
            return nil
        }
    }
}
