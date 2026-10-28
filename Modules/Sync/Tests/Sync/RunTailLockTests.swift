import Testing
import Foundation
import Combine
import Events
import EventsTestSupport
@testable import Sync

/// **A run's last stretch — arming its undo — is still the run** (M3, L7).
///
/// `activeProgress` is the window's write lock, the capsule and the ⌘Z gate at once. A merge
/// published its own, then handed the trash to `deleteItems`, which put up the trash's progress
/// and cleared it when the trash was done — so the merge's undo registration and identity walk ran
/// with no lock at all: writes live, the capsule gone, ⌘Z free to reach a step whose identities
/// did not exist yet. And a copy, move or merge in that stretch showed a Stop and took ⌘. that
/// stopped nothing, since there is nothing left to stop.
///
/// Both are observed where they live: from the main actor, while the identity walk is held
/// suspended. The walk reads the lock of each folded or copied file off the main actor after the
/// undo is registered; the double below catches that read, puts one main-actor observation on
/// the main queue, and waits for it — the rendezvous `MergeUndoGroupingAndGateTests` uses for the
/// trash, for the reasons it gives there. Bounded, and the expiry records itself.
@Suite struct RunTailLockTests {

    /// What the main actor saw of `activeProgress` at one moment.
    struct Sample: Equatable, Sendable {
        let title: String?
        let lockReason: String?
        let isCancellable: Bool
        let completed: Int64
        let total: Int64
        /// The run's history is recorded — which happens in the same main-actor stretch as its
        /// undo registration, so a sample with this set was taken in the tail.
        let historyRecorded: Bool
        /// When the window takes the run on `activeProgress` to have started.
        let startedAt: Date?
    }

    /// A real `FileManager` whose off-main `attributesOfItem` for a path under `watched` takes a
    /// main-actor sample before answering — once `armed` says the interesting part has begun. Its
    /// Trash is the test's own, and can be made to report no location.
    private final class TailSampler: FileManager, @unchecked Sendable {
        let trash: ScratchTrash
        let watched: String
        let trashReportsNoLocation: Bool
        /// Set by the trash, for the merge: before it, the reads are the plan's, not the tail's.
        let armed: LockedBox<Bool>
        let read = LockedBox<(@MainActor () -> Sample?)?>(nil)
        let samples = LockedBox<[Sample?]>([])
        let rendezvousExpired = LockedBox<Bool>(false)
        let trashedAt = LockedBox<Date?>(nil)

        init(trash: ScratchTrash, watched: String, armedFromStart: Bool, trashReportsNoLocation: Bool = false) {
            self.trash = trash
            self.watched = watched.hasSuffix("/") ? watched : watched + "/"
            self.armed = LockedBox(armedFromStart)
            self.trashReportsNoLocation = trashReportsNoLocation
            super.init()
        }

        /// Run on the main queue as the trash starts — the reader's Stop, pressed mid-trash. The
        /// trash runs on a pool thread and the main actor is free (the merge awaits the operation).
        let beforeTrash = LockedBox<(@MainActor () -> Void)?>(nil)

        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            if let stop = beforeTrash.withLock({ $0 }) {
                DispatchQueue.main.sync { MainActor.assumeIsolated { stop() } }
            }
            try trash.trashItem(at: url, resultingItemURL: trashReportsNoLocation ? nil : resultingItemURL)
            trashedAt.withLock { $0 = $0 ?? Date() }
            armed.withLock { $0 = true }
        }

        override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
            // Never from the main thread: the block below needs the main queue free.
            if !Thread.isMainThread, path.hasPrefix(watched), armed.withLock({ $0 }) {
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { [self] in
                    let sample = MainActor.assumeIsolated { read.withLock { $0 }?() }
                    samples.withLock { $0.append(sample) }
                    done.signal()
                }
                if done.wait(timeout: .now() + 10) == .timedOut {
                    rendezvousExpired.withLock { $0 = true }
                }
            }
            return try super.attributesOfItem(atPath: path)
        }
    }

    @MainActor
    private static func sample(_ manager: FileSyncManager) -> Sample? {
        manager.activeProgress.map {
            Sample(title: $0.localizedDescription, lockReason: $0.runLockReason,
                   isCancellable: $0.isCancellable, completed: $0.completedUnitCount, total: $0.totalUnitCount,
                   historyRecorded: !manager.lastRecordedRunRecords.isEmpty,
                   startedAt: manager.activeProgressStartedAt)
        }
    }

    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    /// The overlapping pair a merge folds: one shared file, one unique to the redundant copy.
    /// Named per case: `LogCapture` sees every case's lines.
    private func makePair(_ base: URL, name: String) throws -> (keeper: URL, redundant: URL, group: DuplicateGroup) {
        let keeper = base.appendingPathComponent("Keeper-\(name)")
        let redundant = base.appendingPathComponent("Redundant-\(name)")
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try write(redundant.appendingPathComponent("shared.txt"), bytes: 4000, fill: 0x53)
        try write(redundant.appendingPathComponent("unique.txt"), bytes: 4000, fill: 0x55)
        let k = DuplicateCopy(id: keeper.path, name: keeper.lastPathComponent, isDirectory: true, size: 4000,
                              itemCount: 1, modificationDate: nil, uniqueItemCount: 0, depth: 0,
                              isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant.path, name: redundant.lastPathComponent, isDirectory: true, size: 8000,
                              itemCount: 2, modificationDate: nil, uniqueItemCount: 1, depth: 0,
                              isRecommendedKeeper: false)
        return (keeper, redundant, DuplicateGroup(matchType: .overlapping(sharedFraction: 0.5), name: name,
                                                  isDirectory: true, copies: [k, r], reclaimableBytes: 4000))
    }

    /// **M3.** Sampled inside the merge's identity walk, after its trash: the merge's own lock is
    /// still up, and only cleared once the merge returns.
    @MainActor
    @Test(.parksAThread) func aMergeKeepsTheRunLockUntilItReturns() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeTailLock")
        defer { try? FileManager.default.removeItem(at: base) }
        let pair = try makePair(base, name: "Lock-\(UUID().uuidString)")
        let fm = TailSampler(trash: ScratchTrash(in: base), watched: pair.keeper.path, armedFromStart: false)
        let manager = FileSyncManager(fileManager: fm)
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "MergeTailLock")
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        manager.undoManager = UndoManager()
        manager.duplicateGroups = [pair.group]
        fm.read.withLock { $0 = { @MainActor in Self.sample(manager) } }
        var banners: [OperationBanner] = []
        let watch = manager.$banner.sink { if let banner = $0 { banners.append(banner) } }
        defer { watch.cancel() }

        let ok = await manager.mergeDuplicateGroup(pair.group)

        #expect(ok == true, "the merge did not complete, so the samples below describe nothing")
        #expect(fm.trash.names == [pair.redundant.lastPathComponent], "premise: the merge trashed its copy")
        let trashedAt = try #require(fm.trashedAt.withLock { $0 })
        #expect(fm.rendezvousExpired.withLock { $0 } == false, "a main-actor sample never ran inside the walk")
        // A read can land while the trash's own progress is still up — an identity walk started
        // at the fold may run late. That is the trash's lock, held for the merge; every other
        // reading after the trash must be the merge's own.
        let trashLock = Progress.runLockReason(waitingFor: "the move to the Trash")
        let samples = fm.samples.withLock { $0 }.filter { $0?.lockReason != trashLock }
        #expect(!samples.isEmpty, "no read of the keeper ran after the trash — nothing below was observed in the tail")
        for sample in samples {
            #expect(sample?.lockReason == Progress.runLockReason(waitingFor: "the merge"),
                    "the merge's undo was being armed with the run lock down: \(String(describing: sample))")
            // L7, for the merge: past the trash, nothing is left that a Stop could stop. No
            // reading falls between the trash handing the lock back and this being set: both are
            // one main-actor stretch.
            #expect(sample?.isCancellable == false, "the merge's tail still offers Stop: \(String(describing: sample))")
            #expect(sample?.title == "Finishing…", "\(String(describing: sample))")
            // Handed back after the trash, the merge is still the run that began before it — not
            // the newest run in the capsule, nor one whose log span starts at the handback.
            #expect(sample.flatMap(\.startedAt).map { $0 < trashedAt } == true,
                    "the merge was taken to have started at its handback: \(String(describing: sample)), trashed at \(trashedAt)")
        }
        #expect(manager.activeProgress == nil, "the merge left its lock up after it returned")
        // What names it once it ended — its notification, Activity's row — is the merge's own
        // title over the merge's own minutes, not "Finishing…".
        let ended = try #require(manager.lastFinishedRun)
        #expect(ended.title == "Merging “\(pair.group.name)”", "\(String(describing: ended.title))")
        #expect(ended.started < trashedAt, "the merge's span starts at its handback")
        // The trash's own banner, posted before the merge registers anything, offers no undo: one
        // made then would point at the step below the merge's.
        let trashBanners = banners.filter { $0.message.contains("to the Trash") }
        #expect(!trashBanners.isEmpty, "premise: the trash posted its banner")
        #expect(trashBanners.allSatisfy { !$0.isUndoable },
                "the merge's trash offered an undo it had not registered: \(trashBanners.map(\.message))")
        #expect(banners.last?.message.hasPrefix("Merged") == true && banners.last?.isUndoable == true,
                "the merge's own banner lost its offer: \(String(describing: banners.last))")
    }

    /// **L7.** A copy whose files have all landed is only arming its undo: Stop and ⌘. go, the
    /// lock stays.
    @MainActor
    @Test(.parksAThread) func aCopyArmingItsUndoOffersNoStop() async throws {
        let base = try makeCanonicalTempRoot(prefix: "CopyTailStop")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("src/a.txt")
        let destination = base.appendingPathComponent("dst")
        try write(source, bytes: 100, fill: 0x41)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let fm = TailSampler(trash: ScratchTrash(in: base), watched: destination.path, armedFromStart: true)
        let manager = FileSyncManager(fileManager: fm)
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "CopyTailStop")
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        manager.undoManager = UndoManager()
        fm.read.withLock { $0 = { @MainActor in Self.sample(manager) } }

        let copied = await manager.copyItems(
            nodes: [FileNode(id: source.path, name: "a.txt", isDirectory: false)],
            toPath: destination.path, fileManager: fm)

        #expect(copied.count == 1, "premise: the copy landed")
        #expect(fm.rendezvousExpired.withLock { $0 } == false, "a main-actor sample never ran")
        // The tail's readings: the run's history is recorded, in the stretch that registers its
        // undo. A reading between the last file landing and that stretch is still the run proper.
        let tail = fm.samples.withLock { $0 }.compactMap { $0 }.filter(\.historyRecorded)
        #expect(!tail.isEmpty, "no read of the copy ran once it had landed — the tail was never observed")
        for sample in tail {
            #expect(sample.isCancellable == false, "Stop and ⌘. are live while only the undo is being armed: \(sample)")
            #expect(sample.title == "Finishing…", "\(sample)")
            #expect(sample.lockReason == Progress.runLockReason(waitingFor: "the copy"), "\(sample)")
        }
        #expect(manager.activeProgress == nil)
        #expect(manager.lastFinishedRun?.title == "Copying 1 item",
                "the ended copy is named for its tail: \(String(describing: manager.lastFinishedRun?.title))")
    }

    /// **L3, the merge's log.** A copy the Trash took without saying where is in the Trash; the
    /// log called it "deleted permanently". The fold's undo is still withheld — no restore can be
    /// registered for that copy — and the line now says why in true words.
    @MainActor
    @Test func aCopyTrashedWithoutALocationIsNotLoggedAsDeleted() async throws {
        let log = LogCapture()
        let base = try makeCanonicalTempRoot(prefix: "MergeNoLocation")
        defer { try? FileManager.default.removeItem(at: base) }
        let name = "NoLocation-\(UUID().uuidString)"
        let pair = try makePair(base, name: name)
        let fm = TailSampler(trash: ScratchTrash(in: base), watched: "/nowhere", armedFromStart: false,
                             trashReportsNoLocation: true)
        let manager = FileSyncManager(fileManager: fm)
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "MergeNoLocation")
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let undo = UndoManager()
        manager.undoManager = undo
        manager.duplicateGroups = [pair.group]

        let ok = await manager.mergeDuplicateGroup(pair.group)

        #expect(ok == true)
        #expect(fm.trash.names == [pair.redundant.lastPathComponent], "premise: the copy is in the Trash")
        #expect(undo.canUndo == false, "the fold's undo was registered with no restore for its copy")
        let lines = await log.entries.map(\.message).filter { $0.contains("“\(name)”") }
        #expect(!lines.contains { $0.contains("deleted permanently") },
                "the log says a copy sitting in the Trash was deleted permanently: \(lines)")
        #expect(lines.contains { $0.contains("moved to the Trash with no location reported") && $0.contains("NOT registered") },
                "\(lines)")
    }

    /// **L7, for Sync All.** The bulk run arms its undo too, with its Stop live: the capsule's and
    /// the Differences list's, which reads the flag only when it redraws.
    @MainActor
    @Test(.parksAThread) func aBulkSyncArmingItsUndoOffersNoStop() async throws {
        let base = try makeCanonicalTempRoot(prefix: "BulkTailStop")
        defer { try? FileManager.default.removeItem(at: base) }
        let left = base.appendingPathComponent("src"), right = base.appendingPathComponent("dst")
        try write(left.appendingPathComponent("a.txt"), bytes: 100, fill: 0x41)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        let fm = TailSampler(trash: ScratchTrash(in: base), watched: right.path, armedFromStart: true)
        let manager = FileSyncManager(fileManager: fm)
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "BulkTailStop")
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        manager.undoManager = UndoManager()
        let diff = FileDifference(relativePath: "a.txt", leftItemPath: left.appendingPathComponent("a.txt").path,
                                  rightItemPath: right.appendingPathComponent("a.txt").path,
                                  type: .missingOnRight, action: .copyToRight, description: "Missing on right",
                                  leftFileSize: 100)
        manager.rawDifferences = [diff]
        manager.differences = [diff]
        fm.read.withLock { $0 = { @MainActor in Self.sample(manager) } }
        // The Differences list redraws when the count is published: one published while the run
        // is no longer cancellable is what takes its Cancel down.
        var redrawnFinishing = false
        let watch = manager.$bulkSyncProgress.sink { value in
            if value != nil, manager.activeProgress?.isCancellable == false { redrawnFinishing = true }
        }
        defer { watch.cancel() }

        await manager.syncAll(direction: .copyToRight)

        #expect(FileManager.default.fileExists(atPath: right.appendingPathComponent("a.txt").path), "premise: the sync copied")
        #expect(fm.rendezvousExpired.withLock { $0 } == false, "a main-actor sample never ran")
        let tail = fm.samples.withLock { $0 }.compactMap { $0 }.filter(\.historyRecorded)
        #expect(!tail.isEmpty, "no read of the copy ran once its history was recorded — the tail was never observed")
        for sample in tail {
            #expect(sample.isCancellable == false, "Stop is live while only the undo is being armed: \(sample)")
            #expect(sample.title == "Finishing…", "\(sample)")
            #expect(sample.lockReason == Progress.runLockReason(waitingFor: "the sync"), "\(sample)")
        }
        #expect(redrawnFinishing, "nothing made the Differences list redraw once Stop had gone")
        #expect(manager.lastFinishedRun?.title == "Syncing 1 file", "\(String(describing: manager.lastFinishedRun?.title))")
    }

    /// **A Stop during a merge's trash stops the merge.** The capsule shows the trash's own
    /// progress then, so its Stop is the only one the reader has; the merge it hands back to used
    /// to end uncancelled, and Activity showed the stopped merge as a problem (TE221).
    @MainActor
    @Test func aStopDuringAMergesTrashEndsTheMergeAsAStop() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeTrashStop")
        defer { try? FileManager.default.removeItem(at: base) }
        let pair = try makePair(base, name: "Stop-\(UUID().uuidString)")
        let fm = TailSampler(trash: ScratchTrash(in: base), watched: "/nowhere", armedFromStart: false)
        let manager = FileSyncManager(fileManager: fm)
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "MergeTrashStop")
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        manager.undoManager = UndoManager()
        manager.duplicateGroups = [pair.group]
        let stoppedTitle = LockedBox<String?>(nil)
        fm.beforeTrash.withLock { $0 = { @MainActor in
            stoppedTitle.withLock { $0 = manager.activeProgress?.localizedDescription }
            manager.activeProgress?.cancel()
        } }

        _ = await manager.mergeDuplicateGroup(pair.group)

        #expect(stoppedTitle.withLock { $0 }?.hasPrefix("Moving") == true,
                "premise: the Stop landed on the trash's progress, not the merge's: \(String(describing: stoppedTitle.withLock { $0 }))")
        let ended = try #require(manager.lastFinishedRun)
        #expect(ended.title == "Merging “\(pair.group.name)”", "\(String(describing: ended.title))")
        #expect(ended.cancelled, "the merge the reader stopped ended as if it had run to the end")
    }
}
