import Events
import EventsTestSupport
import Foundation
import Testing
@testable import Sync

/// **A folder whose provider never answers must not stop the comparison** — see
/// `FileSyncManager.DatalessFolderReads`.
///
/// The case measured on 2026-10-02: with OneDrive not running, listing either account's `.Trash`
/// (dataless) blocks forever. The Home pane's walk reached one, its pool thread blocked inside the
/// listing, and the refresh never got as far as comparing — the log said the walk had stopped at
/// its budget and then nothing, ever. Each Refresh after that leaked one more blocked thread until
/// the other pane stopped loading too.
///
/// The double here is that disk: one folder is dataless, and listing it parks until the test lets it
/// go — the provider answering. Everything else is an ordinary `MockFileManager`.
@Suite struct UnansweredFolderTests {

    /// **One disk per test, under a root of its own.** Every case here logs the same sentence about
    /// its unanswered folder, the cases run in parallel, and a `LogCapture` hears all of them — so on
    /// one shared path, another test's line could satisfy this one's log assertion.
    ///
    /// Left: `<root>/home`, holding the folder that does not answer. Right: `<root>/other`, which has
    /// one file the left lacks (`Notes/c.txt` — the row that proves the comparison ran) and the same
    /// file under its own `Archive` that the left's unread one holds (the row that must NOT appear).
    struct Fixture {
        let root: String

        var home: CloudProvider { provider("home", at: "/home") }
        var other: CloudProvider { provider("other", at: "/other") }
        var elsewhere: CloudProvider { provider("elsewhere", at: "/elsewhere") }
        /// NOT a dot-folder, unlike the `.Trash` that found this: hidden rows are filtered out of
        /// `differences` on their own, and a hidden name would let "nothing under it is reported
        /// missing" pass whether or not the walk marked it.
        var unanswered: String { root + "/home/Cloud/Archive" }

        func provider(_ id: String, at path: String) -> CloudProvider {
            CloudProvider(id: id, displayName: id, imageName: "folder", rootPath: root + path, type: .localFolder)
        }

        func disk(gate: ParkGate) throws -> UnansweredFolderDisk {
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
            return UnansweredFolderDisk(inner: mock, unanswered: unanswered, gate: gate)
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

    /// **The refresh compares while the folder's listing is still out**, and the folder comes back
    /// unexplored — so nothing under it is reported missing, and everything else still is.
    @MainActor
    @Test(.parksAThread) func aFolderThatNeverAnswersStillLetsTheRefreshCompare() async throws {
        let f = Fixture(root: "/refresh")
        let gate = ParkGate()
        let manager = FileSyncManager(fileManager: try f.disk(gate: gate))
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))
        manager.datalessFolderReads = reads
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
        // Not ALSO called unreadable: the walk's own line says "permission denied", and a reader of
        // the log would go looking at the folder's permissions instead of at the app that syncs it.
        #expect(!(await log.holds(containing: "could not list “\(f.unanswered)”")))

        // The provider answers at last. The read it was holding comes back and leaves the registry.
        gate.release.signal()
        await refresh.value
        await waitUntil("the late answer came back") { !reads.isOutstanding(f.unanswered) }
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// **A Refresh does not read an unanswered folder again** — the leak, one blocked thread per
    /// click, that took the whole pool. And once the provider answers, the next Refresh reads the
    /// folder like any other: the deadline deferred it, it did not drop it.
    @MainActor
    @Test(.parksAThread) func aRefreshSkipsAFolderStillUnansweredAndReadsItOnceItAnswers() async throws {
        let f = Fixture(root: "/skip")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        let manager = FileSyncManager(fileManager: disk)
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))
        manager.datalessFolderReads = reads

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

    /// **A pane whose ROOT does not answer is unknown, not empty.** The walk hands back the folder
    /// itself marked unexplored — the shape a root that cannot be listed has always had
    /// (`isUnreadableRootWalk`). As a bare `[]` the side would read as authoritatively empty, and
    /// every file opposite it would be reported missing. The same shape is what stops a source switch
    /// keeping the walk, and the walk after the switch asks again without a second read.
    @MainActor
    @Test(.parksAThread) func aPaneRootThatNeverAnswersIsUnknownAndIsNotKept() async throws {
        let f = Fixture(root: "/rootpane")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        let manager = FileSyncManager(fileManager: disk)
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))
        manager.datalessFolderReads = reads
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

    /// **A walk superseded while it waits lets go at once**, rather than sitting out the deadline —
    /// navigating away from Home must not cost the old walk's wait. The deadline here is far longer
    /// than the bound the test allows, so the only way to make the bound is to stop waiting on cancel.
    @MainActor
    @Test(.parksAThread) func aSupersededWalkStopsWaitingForTheFolder() async throws {
        let f = Fixture(root: "/supersede")
        let gate = ParkGate()
        let manager = FileSyncManager(fileManager: try f.disk(gate: gate))
        manager.datalessFolderReads = FileSyncManager.DatalessFolderReads(deadline: .seconds(60))

        let first = Task { await manager.refreshTreesAndScan(left: f.home, right: f.other) }
        await awaitSignal(gate.entered, "the walk never reached the folder that does not answer")

        let started = ContinuousClock.now
        await manager.refreshTreesAndScan(left: f.elsewhere, right: f.other)
        await first.value
        #expect(ContinuousClock.now - started < .seconds(10),
                "the superseded walk waited for the folder instead of unwinding")
        #expect(manager.hasScanned, "the refresh that superseded it did not compare")
        #expect(gate.isParked)

        gate.release.signal()
        await waitUntil("the late answer came back") { !manager.datalessFolderReads.isOutstanding(f.unanswered) }
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    // MARK: - The comparison's disk walk

    /// **The scan's own walk gives up on the folder too.** Compare walks the disk itself whenever a
    /// pane has no cached walk of the folder it compares — the comparison Compare owes on arrival
    /// is a direct `scanDirectories`, which does not wait for a pane's load — and that walk is a
    /// `DirectoryEnumerator`, which would block descending into the folder.
    @MainActor
    @Test(.parksAThread) func theComparisonsOwnWalkGivesUpOnTheFolderToo() async throws {
        let f = Fixture(root: "/coldscan")
        let gate = ParkGate()
        let manager = FileSyncManager(fileManager: try f.disk(gate: gate))
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))
        manager.datalessFolderReads = reads
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

    /// **A cancelled comparison stops waiting for the folder too.** That walk cannot suspend — it
    /// waits on its thread — so it has to notice the cancel itself; otherwise Stop, or the refresh
    /// that supersedes it, would sit out the deadline holding the scanning slot.
    @MainActor
    @Test(.parksAThread) func aCancelledComparisonStopsWaitingForTheFolder() async throws {
        let f = Fixture(root: "/cancel")
        let gate = ParkGate()
        let manager = FileSyncManager(fileManager: try f.disk(gate: gate))
        manager.datalessFolderReads = FileSyncManager.DatalessFolderReads(deadline: .seconds(60))

        let scan = Task {
            await manager.scanDirectories(left: f.home, leftPath: f.home.rootPath,
                                          right: f.other, rightPath: f.other.rootPath)
        }
        await awaitSignal(gate.entered, "the scan never reached the folder that does not answer")
        let started = ContinuousClock.now
        scan.cancel()
        await scan.value
        #expect(ContinuousClock.now - started < .seconds(10),
                "the cancelled scan waited for the folder instead of stopping")
        #expect(!manager.isScanning)
        #expect(!manager.hasScanned, "a cancelled scan published")

        gate.release.signal()
        await waitUntil("the late answer came back") { !manager.datalessFolderReads.isOutstanding(f.unanswered) }
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// The same walk, read directly: the folder's entry is there, marked unexplored, and nothing
    /// below it is — it was never listed.
    @Test(.parksAThread) func theDiskWalkMarksTheFolderUnexploredAndListsNothingBelowIt() async throws {
        let f = Fixture(root: "/diskwalk")
        let gate = ParkGate()
        let disk = try f.disk(gate: gate)
        let reads = FileSyncManager.DatalessFolderReads(deadline: .milliseconds(250))

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
        await waitForRelease(of: reads, path: f.unanswered)
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    // MARK: - The registry

    /// **One folder is one read, whichever way the walk reached it.** The Home pane reaches each
    /// OneDrive `.Trash` through OneDrive's link in the home folder (`~/OneDrive/.Trash`, measured)
    /// and can reach it again under `~/Library/CloudStorage/…`. Read once per spelling, a folder
    /// that is not answering would hold two threads and cost a walk two waits.
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
        await waitForRelease(of: reads, path: real.path)
        try #require(!gate.releasedByTimeout, "the gate timed out: the folder was never held unanswered")
    }

    /// Off the main actor, for the tests here that are not on it.
    private func waitForRelease(of reads: FileSyncManager.DatalessFolderReads, path: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while reads.isOutstanding(path), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(!reads.isOutstanding(path), "the late answer never came back")
    }
}

/// A disk on which one folder is dataless and its provider is not answering: listing it — directly,
/// or by an enumerator descending into it — parks on `gate` until the test releases it. Released, it
/// is materialized, exactly as listing a real one leaves it: no longer dataless, and listed at once.
///
/// The recursive enumerator descends LAZILY, as the real one was measured to: it reads a folder's
/// contents on the call AFTER the one that yielded the folder, so `skipDescendants()` made in
/// between keeps it from asking the provider at all.
final class UnansweredFolderDisk: FileManaging, @unchecked Sendable {
    private let inner: MockFileManager
    private let unanswered: String
    private let gate: ParkGate
    private let lock = NSLock()
    private var reads = 0
    private var answered = false

    init(inner: MockFileManager, unanswered: String, gate: ParkGate) {
        self.inner = inner
        self.unanswered = unanswered
        self.gate = gate
    }

    /// How many times something asked the provider for the folder's contents.
    var providerReads: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    func isDataless(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return url.path == unanswered && !answered
    }

    /// One listing of the dataless folder: the provider is asked, and the call parks until it answers.
    fileprivate func askTheProvider() {
        lock.lock()
        guard !answered else { lock.unlock(); return }
        reads += 1
        lock.unlock()
        gate.park(timeout: 30)
        lock.lock(); answered = true; lock.unlock()
    }

    func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?,
                    options m: FileManager.DirectoryEnumerationOptions,
                    errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
        if u.path == unanswered { askTheProvider() }
        let listing = inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        guard !m.contains(.skipsSubdirectoryDescendants), let listing else { return listing }
        let entries = listing.allObjects.compactMap { $0 as? URL }
        return DescendingEnumerator(entries: entries, unanswered: unanswered, disk: self)
    }

    func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
    func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        inner.fileExists(atPath: p, isDirectory: d)
    }
    func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] { try inner.attributesOfItem(atPath: p) }
    func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws { try inner.setAttributes(a, ofItemAtPath: p) }
    func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
        try inner.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
    }
    func copyItem(at s: URL, to d: URL) throws { try inner.copyItem(at: s, to: d) }
    func moveItem(at s: URL, to d: URL) throws { try inner.moveItem(at: s, to: d) }
    func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        try inner.trashItem(at: u, resultingItemURL: o)
    }
    func removeItem(at u: URL) throws { try inner.removeItem(at: u) }
    func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? {
        try inner.replaceItem(at: d, withItemAt: s, backupItemName: n)
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
                // Descending into the dataless folder is reading it — unless the caller said not to.
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
