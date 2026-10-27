import Testing
import Foundation
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

        init(trash: ScratchTrash, watched: String, armedFromStart: Bool, trashReportsNoLocation: Bool = false) {
            self.trash = trash
            self.watched = watched.hasSuffix("/") ? watched : watched + "/"
            self.armed = LockedBox(armedFromStart)
            self.trashReportsNoLocation = trashReportsNoLocation
            super.init()
        }

        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try trash.trashItem(at: url, resultingItemURL: trashReportsNoLocation ? nil : resultingItemURL)
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
                   historyRecorded: !manager.lastRecordedRunRecords.isEmpty)
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

        let ok = await manager.mergeDuplicateGroup(pair.group)

        #expect(ok == true, "the merge did not complete, so the samples below describe nothing")
        #expect(fm.trash.names == [pair.redundant.lastPathComponent], "premise: the merge trashed its copy")
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
        }
        #expect(manager.activeProgress == nil, "the merge left its lock up after it returned")
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
}
