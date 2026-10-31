import CoreServices
import Foundation
import Testing
@testable import Sync

/// **The watcher's pure half**: where a raw FSEvents event lands, spelled how, and which flags turn
/// into "list it again". FSEvents cannot be made to drop events or wrap its ids on demand, so every
/// such flag is pinned here, against `interpret` directly.
@Suite struct FolderWatcherInterpretTests {

    private static let documents = ResolvedWatchRoot(spelled: "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Documents",
                                                     real: "/Users/me/Documents")
    private static let dropbox = ResolvedWatchRoot(spelled: "/Users/me/Dropbox", real: "/Users/me/Library/CloudStorage/Dropbox")

    private static func raw(_ path: String, _ flags: Int, id: UInt64 = 10) -> RawFolderEvent {
        RawFolderEvent(id: id, flags: UInt32(flags), path: path, fileID: 77, documentID: 88)
    }

    /// **The headline case of the brief: a root handed over through a link comes back in the
    /// link's spelling.** iCloud Drive ▸ Documents is a link to `~/Documents` on this Mac;
    /// FSEvents reports the real path, and the consumer must hear the one it asked about.
    @Test func anEventUnderALinkedRootIsSpelledTheWayTheRootWas() {
        let (batch, _) = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents/Tax/2026.pdf",
                      kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)],
            roots: [Self.documents, Self.dropbox], replaying: false, now: 0)
        #expect(batch.rescans.isEmpty)
        let event = try! #require(batch.events.first)
        #expect(batch.events.count == 1, "placed under a root that does not hold it: \(batch.events.map(\.root))")
        #expect(event.root == Self.documents.spelled)
        #expect(event.path == Self.documents.spelled + "/Tax/2026.pdf")
        #expect(event.realPath == "/Users/me/Documents/Tax/2026.pdf")
        #expect(event.change == [.created, .isFile])
        #expect(event.fileID == 77)
        #expect(event.documentID == 88)
        #expect(!event.isOwn)
        #expect(!event.isHistorical)
    }

    /// A sibling that only shares a string prefix with a root is outside it — `PathBoundary`'s
    /// rule, which a bare `hasPrefix` breaks.
    @Test func aSiblingSharingAPrefixIsNotUnderTheRoot() {
        let (batch, _) = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents2/x.txt", kFSEventStreamEventFlagItemModified)],
            roots: [Self.documents], replaying: false, now: 0)
        #expect(batch.isEmpty)
    }

    /// The root folder itself is an event at the root's own spelling, with no trailing slash.
    @Test func theRootItselfIsSpelledAsTheRoot() {
        let (batch, _) = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents", kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir)],
            roots: [Self.documents], replaying: false, now: 0)
        #expect(batch.events.map(\.path) == [Self.documents.spelled])
    }

    /// The default macOS volume ignores case, so a root typed in another case than the disk's still
    /// hears its events — and the tail keeps the disk's case, which is what a listing will show.
    @Test func aRootInAnotherCaseStillPlacesTheEventInTheDisksCase() {
        let root = ResolvedWatchRoot(spelled: "/users/me/documents", real: "/users/me/documents")
        let (batch, _) = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents/Tax/Return.PDF", kFSEventStreamEventFlagItemModified)],
            roots: [root], replaying: false, now: 0)
        #expect(batch.events.map(\.path) == ["/users/me/documents/Tax/Return.PDF"])
    }

    @Test func ownEventsAreMarked() {
        let (batch, _) = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents/a", kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagOwnEvent)],
            roots: [Self.documents], replaying: false, now: 0)
        #expect(batch.events.map(\.isOwn) == [true])
    }

    /// Only the item bits survive into `change`; the stream bits (own, history, must-scan) do not.
    @Test func changeCarriesOnlyItemBits() {
        let (batch, _) = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents/a", kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir
                      | kFSEventStreamEventFlagOwnEvent)],
            roots: [Self.documents], replaying: false, now: 0)
        #expect(batch.events.first?.change == [.renamed, .isDirectory])
    }

    /// `MustScanSubDirs` names a folder whose items FSEvents could not keep up with: a rescan there,
    /// spelled under the root, and no event pretending to know what changed.
    @Test func mustScanSubDirsBecomesARescanOfThatFolder() {
        let (batch, _) = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents/Photos", kFSEventStreamEventFlagMustScanSubDirs, id: 42)],
            roots: [Self.documents, Self.dropbox], replaying: false, now: 0)
        #expect(batch.events.isEmpty)
        #expect(batch.rescans == [FolderWatchRescan(root: Self.documents.spelled,
                                                    path: Self.documents.spelled + "/Photos",
                                                    reason: .mustScanSubDirs, id: 42)])
    }

    /// Dropped events and wrapped ids name no folder that is safe to limit them to: every root.
    @Test(arguments: [
        (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped, FolderWatchRescan.Reason.eventsDropped),
        (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped, .eventsDropped),
        (kFSEventStreamEventFlagEventIdsWrapped, .eventIdsWrapped),
    ])
    func lostEventsRescanEveryRoot(flags: Int, reason: FolderWatchRescan.Reason) {
        let (batch, _) = FolderWatcher.interpret([Self.raw("/", flags, id: 9)],
                                                 roots: [Self.documents, Self.dropbox], replaying: false, now: 0)
        #expect(batch.events.isEmpty)
        #expect(Set(batch.rescans.map(\.root)) == [Self.documents.spelled, Self.dropbox.spelled])
        #expect(batch.rescans.allSatisfy { $0.reason == reason && $0.id == 9 && $0.path == $0.root })
        #expect(batch.rescans.count == 2)
    }

    /// `RootChanged` is reported at the root's own path, and touches only that root. **FSEvents
    /// gives it id zero** (FSEvents.h), so it is dated by the clock passed in: at zero it would order
    /// before every walk and mark nothing.
    @Test func rootChangedRescansOnlyThatRootAndIsDatedNow() {
        let (batch, _) = FolderWatcher.interpret([Self.raw("/Users/me/Library/CloudStorage/Dropbox",
                                                           kFSEventStreamEventFlagRootChanged, id: 0)],
                                                 roots: [Self.documents, Self.dropbox], replaying: false, now: 500)
        #expect(batch.rescans.map(\.root) == [Self.dropbox.spelled])
        #expect(batch.rescans.map(\.reason) == [.rootChanged])
        #expect(batch.rescans.map(\.id) == [500], "a zero-id RootChanged kept its zero")
    }

    /// A `MustScanSubDirs` no root places is still lost track of under this stream: every root.
    @Test func anUnplacedMustScanRescansEveryRoot() {
        let (batch, _) = FolderWatcher.interpret([Self.raw("/private/elsewhere", kFSEventStreamEventFlagMustScanSubDirs, id: 7)],
                                                 roots: [Self.documents], replaying: false, now: 0)
        #expect(batch.rescans == [FolderWatchRescan(root: Self.documents.spelled, path: Self.documents.spelled,
                                                    reason: .mustScanSubDirs, id: 7)])
    }

    /// A volume mounted or unmounted at, under or above a root changes what is there.
    @Test func aMountAboveARootRescansIt() {
        let (batch, _) = FolderWatcher.interpret([Self.raw("/Users/me/Library", kFSEventStreamEventFlagUnmount)],
                                                 roots: [Self.documents, Self.dropbox], replaying: false, now: 0)
        #expect(batch.rescans.map(\.root) == [Self.dropbox.spelled])
        #expect(batch.rescans.map(\.reason) == [.volumeChanged])
    }

    /// **History ends at the sentinel, and the sentinel can fall in any callback.** Events before
    /// it are replayed, events after it live; the state carries into the next call.
    @Test func eventsBeforeHistoryDoneAreHistoricalAndTheStateCarries() {
        let first = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents/old", kFSEventStreamEventFlagItemModified, id: 1)],
            roots: [Self.documents], replaying: true, now: 0)
        #expect(first.batch.events.map(\.isHistorical) == [true])
        #expect(first.replaying, "the replay ended without its sentinel")

        let second = FolderWatcher.interpret(
            [Self.raw("/Users/me/Documents/older", kFSEventStreamEventFlagItemModified, id: 2),
             Self.raw("", kFSEventStreamEventFlagHistoryDone, id: 3),
             Self.raw("/Users/me/Documents/new", kFSEventStreamEventFlagItemModified, id: 4)],
            roots: [Self.documents], replaying: first.replaying, now: 0)
        #expect(second.batch.events.map(\.isHistorical) == [true, false])
        #expect(second.batch.events.count == 2, "the sentinel was reported as an event")
        #expect(!second.replaying)
    }
}

/// A burst reaches the consumer once: due when the events have been quiet for `quiet`, or
/// `maxDelay` after the first, whichever is sooner.
@Suite struct FolderWatchCoalescerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aQuietGapMakesTheBatchDue() {
        var c = FolderWatchCoalescer(quiet: 1, maxDelay: 5)
        #expect(c.note(at: t0) == t0.addingTimeInterval(1))
        #expect(c.note(at: t0.addingTimeInterval(0.5)) == t0.addingTimeInterval(1.5))
        #expect(!c.isDue(at: t0.addingTimeInterval(1.4)))
        #expect(c.isDue(at: t0.addingTimeInterval(1.5)))
    }

    @Test func aBurstThatNeverStopsIsStillDueAtMaxDelay() {
        var c = FolderWatchCoalescer(quiet: 1, maxDelay: 5)
        var due = Date.distantPast
        for tick in 0...20 { due = c.note(at: t0.addingTimeInterval(Double(tick) * 0.5)) }
        #expect(due == t0.addingTimeInterval(5))
        c.reset()
        #expect(c.deadline == nil)
        #expect(c.note(at: t0.addingTimeInterval(11)) == t0.addingTimeInterval(12),
                "a reset kept the old burst's start, so the next batch is due at once")
    }
}

/// **The watcher against real FSEvents**, in a temp folder. Every wait is bounded and each test
/// asserts what arrived, never only that something did.
@Suite(.serialized) struct FolderWatcherLiveTests {

    /// Collects batches as the watcher hands them over (on its own queue).
    final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FolderWatchBatch] = []
        func add(_ batch: FolderWatchBatch) { lock.lock(); stored.append(batch); lock.unlock() }
        var batches: [FolderWatchBatch] { lock.lock(); defer { lock.unlock() }; return stored }
        var events: [FolderWatchEvent] { batches.flatMap(\.events) }
        var rescans: [FolderWatchRescan] { batches.flatMap(\.rescans) }
    }

    /// A temp folder spelled the way `NSTemporaryDirectory` spells it — under `/var`, a link to
    /// `/private/var`, so every root here is reached through a symlink, as iCloud's Documents is.
    static func makeFolder(_ name: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("synccloud-watch-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return PathBoundary.normalizedRoot(path)
    }

    /// Writes from another process, so FSEvents does not mark it as ours.
    static func touch(_ paths: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = paths
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    static func historyRecords(for root: String) -> (key: String, deviceUUID: String)? {
        guard let real = FolderWatcher.resolve(root) else { return nil }
        var info = stat()
        guard stat(real, &info) == 0, let uuid = FolderWatcher.deviceUUID(info.st_dev) else { return nil }
        return (FolderWatcher.volumeKey(for: real, device: info.st_dev), uuid)
    }

    @MainActor
    @Test func aChangeUnderALinkedRootArrivesSpelledThroughTheLink() async throws {
        let target = try Self.makeFolder("target")
        defer { try? FileManager.default.removeItem(atPath: target) }
        let linkHolder = try Self.makeFolder("holder")
        defer { try? FileManager.default.removeItem(atPath: linkHolder) }
        let link = linkHolder + "/Documents"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let inbox = Inbox()
        let watcher = FolderWatcher(history: .inMemory(), latency: 0.05, quiet: 0.2, maxDelay: 2) { inbox.add($0) }
        defer { watcher.stop() }
        watcher.watch([FolderWatchRoot(path: link)])

        try Self.touch(target + "/Return.pdf")
        await waitUntil("the external write was never reported", timeout: 10) {
            inbox.events.contains { $0.path.hasSuffix("/Return.pdf") }
        }
        let event = try #require(inbox.events.first { $0.path.hasSuffix("/Return.pdf") })
        #expect(event.root == link)
        #expect(event.path == link + "/Return.pdf", "reported in the disk's spelling, not the root's")
        #expect(event.realPath == FolderWatcher.resolve(target)! + "/Return.pdf")
        #expect(event.change.contains(.created))
        #expect(!event.isOwn, "another process's write was marked as ours")
        let inode = try FileManager.default.attributesOfItem(atPath: target + "/Return.pdf")[.systemFileNumber] as? UInt64
        #expect(event.fileID == inode, "the extended data's file id is not the file's inode")
    }

    /// **"Counts once": a burst of fifty files is one batch** — and one the WATCHER folded, not
    /// FSEvents: the files go in five writes a third of a second apart, past the stream's 0.05 s
    /// latency, so FSEvents hands them over in several callbacks (counted) and the three-second
    /// quiet window must join them. Asserted as the first batch holding every file.
    @MainActor
    @Test func aBurstArrivesAsOneBatch() async throws {
        let folder = try Self.makeFolder("burst")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let inbox = Inbox()
        let watcher = FolderWatcher(history: .inMemory(), latency: 0.05, quiet: 3, maxDelay: 60) { inbox.add($0) }
        defer { watcher.stop() }
        watcher.watch([FolderWatchRoot(path: folder)], replay: .none)

        let names = (0..<50).map { "f\($0).txt" }
        for group in stride(from: 0, to: names.count, by: 10) {
            if group > 0 { try await Task.sleep(nanoseconds: 330_000_000) }   // spacing, not a wait
            try Self.touch(contentsOf: names[group..<group + 10].map { folder + "/" + $0 })
        }
        await waitUntil("the burst never arrived", timeout: 30) { !inbox.batches.isEmpty }
        let burst = inbox.batches[0]
        let reported = Set(burst.events.map { ($0.path as NSString).lastPathComponent })
        #expect(reported.isSuperset(of: names),
                "the burst was split: \(names.count - reported.intersection(names).count) file(s) missing from its first batch")
        #expect(watcher.callbackCount >= 2,
                "FSEvents delivered the burst in one callback — nothing here shows the watcher folding it")
    }

    /// The process's own write is reported, marked as its own.
    @MainActor
    @Test func ourOwnWriteIsMarked() async throws {
        let folder = try Self.makeFolder("own")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let inbox = Inbox()
        let watcher = FolderWatcher(history: .inMemory(), latency: 0.05, quiet: 0.2, maxDelay: 2) { inbox.add($0) }
        defer { watcher.stop() }
        watcher.watch([FolderWatchRoot(path: folder)])
        try Data("x".utf8).write(to: URL(fileURLWithPath: folder + "/mine.txt"))
        await waitUntil("our write was never reported", timeout: 10) {
            inbox.events.contains { $0.path.hasSuffix("/mine.txt") }
        }
        #expect(inbox.events.filter { $0.path.hasSuffix("/mine.txt") }.allSatisfy { $0.isOwn })
    }

    /// **Adding a root leaves the others' streams alone** — a restart would have to replay, and a
    /// replay brings our own writes back without their mark.
    ///
    /// Two conditions make the replay real, and without them the old restart passed this test
    /// (mutation-tested): the write must be in fseventsd's history before the restart — an event it
    /// has not yet processed reaches the new stream live, mark and all — and still undelivered by the
    /// first stream. So a marker in another folder is waited for (ids are issued in order), under a
    /// first stream whose ten-second latency is still holding the write back — ten, because the
    /// marker's round trip (a process, fseventsd, a main-actor poll) must fit inside it on a loaded
    /// CI VM, and the precondition below fails loudly if it ever does not.
    @MainActor
    @Test func addingARootDoesNotReplayAnotherRootsOwnWritesAsSomeoneElses() async throws {
        let first = try Self.makeFolder("first")
        let second = try Self.makeFolder("second")
        let markerFolder = try Self.makeFolder("marker")
        defer {
            for folder in [first, second, markerFolder] { try? FileManager.default.removeItem(atPath: folder) }
        }
        let inbox = Inbox()
        let watcher = FolderWatcher(history: .inMemory(), latency: 10, quiet: 0.2, maxDelay: 15) { inbox.add($0) }
        defer { watcher.stop() }
        watcher.watch([FolderWatchRoot(path: first)], replay: .none)
        try Data("mine".utf8).write(to: URL(fileURLWithPath: first + "/mine.txt"))

        let markers = Inbox()
        let marker = FolderWatcher(history: .inMemory(), latency: 0.05, quiet: 0.05, maxDelay: 1) { markers.add($0) }
        defer { marker.stop() }
        marker.watch([FolderWatchRoot(path: markerFolder)], replay: .none)
        try Self.touch(markerFolder + "/marker.txt")
        await waitUntil("the marker was never delivered", timeout: 10) {
            markers.events.contains { $0.path.hasSuffix("/marker.txt") }
        }
        marker.stop()
        #expect(!inbox.events.contains { $0.path.hasSuffix("/mine.txt") },
                "the first stream delivered our write before the second root was added — the restart below tests nothing")

        watcher.watch([FolderWatchRoot(path: first), FolderWatchRoot(path: second)], replay: .none)
        await waitUntil("our write was never reported", timeout: 30) {
            inbox.events.contains { $0.path.hasSuffix("/mine.txt") }
        }
        let mine = inbox.events.filter { $0.path.hasSuffix("/mine.txt") }
        #expect(mine.allSatisfy { $0.isOwn && !$0.isHistorical },
                "our write came back as someone else's: \(mine.map { ($0.isOwn, $0.isHistorical) })")
        #expect(inbox.rescans.isEmpty, "`.none` claimed something about the past: \(inbox.rescans.map(\.reason))")
    }

    /// **The stored id replays what changed while nothing watched**, marked historical. The first
    /// watcher sees one write and stops; the second write lands with no watcher; a second watcher on
    /// the same history must report it.
    @MainActor
    @Test func aRestartReplaysWhatChangedWhileNothingWatched() async throws {
        let folder = try Self.makeFolder("replay")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let history = FolderWatchHistory.inMemory()
        let first = Inbox()
        let a = FolderWatcher(history: history, latency: 0.05, quiet: 0.2, maxDelay: 2) { first.add($0) }
        defer { a.stop() }
        a.watch([FolderWatchRoot(path: folder)])
        try Self.touch(folder + "/before.txt")
        await waitUntil("the first write was never reported", timeout: 10) {
            first.events.contains { $0.path.hasSuffix("/before.txt") }
        }
        a.stop()
        let key = try #require(Self.historyRecords(for: folder))
        let stored = try #require(history.load()[key.key], "stopping stored no id for the volume")
        #expect(stored.deviceUUID == key.deviceUUID)
        #expect(stored.lastEventId >= first.events.map(\.id).max()!)

        try Self.touch(folder + "/while-away.txt")
        // **Only a write FSEvents has already processed is history.** fseventsd numbers a change
        // when it reads it from the kernel, a moment after the write, and one it has not read yet
        // when the stream starts arrives after `HistoryDone`, as a live event. So wait for a later
        // marker in another folder to be delivered to a third watcher: ids are issued in order, so
        // once the marker is out, the write before it is history.
        let markerFolder = try Self.makeFolder("marker")
        defer { try? FileManager.default.removeItem(atPath: markerFolder) }
        let markers = Inbox()
        let c = FolderWatcher(history: .inMemory(), latency: 0.05, quiet: 0.1, maxDelay: 1) { markers.add($0) }
        defer { c.stop() }
        c.watch([FolderWatchRoot(path: markerFolder)])
        try Self.touch(markerFolder + "/marker.txt")
        await waitUntil("the marker was never delivered", timeout: 10) {
            markers.events.contains { $0.path.hasSuffix("/marker.txt") }
        }
        c.stop()

        let second = Inbox()
        let b = FolderWatcher(history: history, latency: 0.05, quiet: 0.2, maxDelay: 2) { second.add($0) }
        defer { b.stop() }
        b.watch([FolderWatchRoot(path: folder)])
        await waitUntil("the write made while nothing watched was never replayed", timeout: 15) {
            second.events.contains { $0.path.hasSuffix("/while-away.txt") }
        }
        #expect(second.rescans.isEmpty, "a valid history was treated as lost: \(second.rescans.map(\.reason))")
        #expect(second.events.filter { $0.path.hasSuffix("/while-away.txt") }.allSatisfy { $0.isHistorical })
    }

    /// **A stored id from another history is worthless**: the device UUID it was stored under no
    /// longer matches, so every root is changed as of the start, and nothing is replayed.
    ///
    /// **Two roots on one volume, in one call**: the first rewrites the volume's record, and the
    /// second must still be judged against the record that was there — both are told.
    @MainActor
    @Test func aChangedDeviceUUIDMarksEveryRootChanged() async throws {
        let folder = try Self.makeFolder("lost")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let sibling = try Self.makeFolder("lost-sibling")
        defer { try? FileManager.default.removeItem(atPath: sibling) }
        let key = try #require(Self.historyRecords(for: folder))
        try #require(Self.historyRecords(for: sibling)?.key == key.key, "the two folders are not on one volume")
        let history = FolderWatchHistory.inMemory([key.key: .init(deviceUUID: "00000000-0000-0000-0000-000000000000",
                                                                 lastEventId: 1)])
        let inbox = Inbox()
        let before = FolderWatcher.currentEventId()
        let watcher = FolderWatcher(history: history, latency: 0.05, quiet: 0.2, maxDelay: 2) { inbox.add($0) }
        defer { watcher.stop() }
        watcher.watch([FolderWatchRoot(path: folder), FolderWatchRoot(path: sibling)])
        await waitUntil("a foreign history was never reported for both roots", timeout: 10) { inbox.rescans.count >= 2 }
        #expect(Set(inbox.rescans.map(\.root)) == [folder, sibling])
        #expect(inbox.rescans.allSatisfy { $0.reason == .historyLost && $0.path == $0.root && $0.id >= before })
        #expect(history.load()[key.key]?.deviceUUID == key.deviceUUID, "the foreign record was kept")
    }

    /// **The stored id never passes what the consumer was handed.** A change sits in the coalescing
    /// window (a minute's quiet) when the watcher goes away without `stop()` — a quit, a crash. The
    /// record must not have moved past it, so the next `.stored` start replays it.
    @MainActor
    @Test func aChangeStillBeingCoalescedIsReplayedAfterTheWatcherGoes() async throws {
        let folder = try Self.makeFolder("undelivered")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let key = try #require(Self.historyRecords(for: folder))
        let history = FolderWatchHistory.inMemory()
        let unused = Inbox()
        var first: FolderWatcher? = FolderWatcher(history: history, latency: 0.05, quiet: 60, maxDelay: 120) { unused.add($0) }
        first?.watch([FolderWatchRoot(path: folder)], replay: .none)
        let recorded = try #require(history.load()[key.key]?.lastEventId)
        try Self.touch(folder + "/held.txt")
        await waitUntil("FSEvents never delivered the change to the watcher", timeout: 10) { (first?.callbackCount ?? 0) >= 1 }
        #expect(unused.batches.isEmpty, "the change was handed over — it is not being held, and this tests nothing")
        #expect(history.load()[key.key]?.lastEventId == recorded, "the record moved past a change nobody was handed")
        first = nil

        let inbox = Inbox()
        let second = FolderWatcher(history: history, latency: 0.05, quiet: 0.2, maxDelay: 2) { inbox.add($0) }
        defer { second.stop() }
        second.watch([FolderWatchRoot(path: folder)], replay: .stored)
        await waitUntil("the change held when the first watcher went was never replayed", timeout: 15) {
            inbox.events.contains { $0.path.hasSuffix("/held.txt") }
        }
    }

    /// **A root that cannot be watched yet is tried again** — not taken as settled because it was
    /// once asked for. The folder appears after the first `watch`; the same set asked again must
    /// start its stream, and a change in it must be reported.
    @MainActor
    @Test func aRootThatAppearsLaterIsWatchedOnTheNextAsk() async throws {
        let parent = try Self.makeFolder("late")
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let late = parent + "/late"
        let inbox = Inbox()
        let watcher = FolderWatcher(history: .inMemory(), latency: 0.05, quiet: 0.2, maxDelay: 2) { inbox.add($0) }
        defer { watcher.stop() }
        watcher.watch([FolderWatchRoot(path: late)], replay: .none)
        #expect(watcher.roots.isEmpty, "a folder that does not exist was reported as watched")
        try FileManager.default.createDirectory(atPath: late, withIntermediateDirectories: false)
        watcher.watch([FolderWatchRoot(path: late)], replay: .none)
        #expect(watcher.roots == [FolderWatchRoot(path: late)])
        try Self.touch(late + "/now.txt")
        await waitUntil("a change in the late folder was never reported", timeout: 10) {
            inbox.events.contains { $0.path.hasSuffix("/now.txt") }
        }
    }
}

private extension FolderWatcherLiveTests {
    static func touch(contentsOf paths: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        process.arguments = paths
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
