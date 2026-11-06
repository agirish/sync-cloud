import Testing
import Foundation
@testable import Sync

/// The duplicate merge's `cancelledMidCopy` guard: a partially folded copy is never trashed. A
/// regression doesn't throw or warn; it trashes a folder whose contents only partly reached the
/// keeper. The sibling refusals are pinned in `FileSyncManagerDuplicatesTests`.
///
/// The cancel point is deterministic: the merge is parked inside its first file copy, its
/// `Progress` is cancelled while it can't advance, then it is released, so the second plan step is
/// the one that observes the cancellation.
@Suite struct MergeCancelMidCopyTests {

    /// A real `FileManager` (the merge hashes real bytes, so a mock disk can't drive this path)
    /// that cancels the run's `Progress` from inside the first `copyItem`, then lets the copy
    /// finish, so step 2 observes the cancellation.
    ///
    /// It cancels on the worker's own thread: a test-side cancel would have to be scheduled on the
    /// main actor, which the parallel suite can starve for seconds, so it could land in the wrong
    /// place or not at all. A subclass rather than a `FileManaging` wrapper because only the
    /// `fileManager is FileManager` fast path in `buildTree` yields file sizes to hash and plan.
    private final class FirstCopyCancelGate: FileManager, @unchecked Sendable {
        /// A `FileManager` subclass can't add mutable stored state (it is already unchecked
        /// Sendable), so the state lives in a lock-guarded box.
        private final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            private var progress: Progress?
            /// True exactly once.
            func trip() -> Bool {
                lock.lock(); defer { lock.unlock() }
                let first = !fired
                fired = true
                return first
            }
            func install(_ progress: Progress) { lock.lock(); self.progress = progress; lock.unlock() }
            /// The installed Progress, waiting (bounded) for the test to hand it over.
            func awaitProgress() -> Progress? {
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    lock.lock(); let p = progress; lock.unlock()
                    if let p { return p }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return nil
            }
        }
        private let gate = Gate()

        /// Hands the gate the merge's Progress. The gate waits for it, so a late install can't make
        /// the cancellation land early.
        func installProgress(_ progress: Progress) { gate.install(progress) }

        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            if gate.trip() { gate.awaitProgress()?.cancel() }
            try super.copyItem(at: srcURL, to: dstURL)
        }
    }

    private func write(_ url: URL, bytes: Int, fill: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    @MainActor
    @Test func cancellingBetweenTheCopyPhaseAndTheTrashStepNeverTrashesTheHalfFoldedCopy() async throws {
        let base = try makeCanonicalTempRoot(prefix: "DuplicatesCancelTest")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        // A unique name, so the check below can prove nothing reached ~/.Trash, and a regression
        // that trashes it leaves no doubt whose folder it is.
        let rName = "Redundant-\(UUID().uuidString)"
        let redundant = base.appendingPathComponent(rName)
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
        defer { try? FileManager.default.removeItem(at: trashed) }

        // shared.txt is identical on both sides, so the plan skips it; the two unique files become
        // steps in name order: step 1 "a-unique.txt", step 2 "b-unique.txt".
        try write(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(redundant.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(redundant.appendingPathComponent("a-unique.txt"), bytes: 5000, fill: 0x41)
        try write(redundant.appendingPathComponent("b-unique.txt"), bytes: 5000, fill: 0x42)

        let gate = FirstCopyCancelGate()
        let manager = FileSyncManager(fileManager: gate)
        let k = DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let r = DuplicateCopy(id: redundant.path, name: rName, isDirectory: true, size: 15000, itemCount: 3,
                              modificationDate: nil, uniqueItemCount: 2, depth: 0, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.33), name: "Keeper",
                                   isDirectory: true, copies: [k, r], reclaimableBytes: 5000)
        manager.duplicateGroups = [group]

        let merge = Task { await manager.mergeDuplicateGroup(group) }
        // The merge publishes its Progress before planning; the gate cancels it from inside the
        // first file's copy, so the cancel lands strictly between step 1 and step 2.
        await waitUntil("the merge publishes a cancellable Progress") { manager.activeProgress != nil }
        gate.installProgress(try #require(manager.activeProgress))
        let ok = await merge.value

        #expect(ok == false)

        // The invariant: a copy whose fold didn't complete is never trashed.
        #expect(FileManager.default.fileExists(atPath: redundant.path),
                "the partially-folded copy must stay on disk")
        #expect(FileManager.default.fileExists(atPath: trashed.path) == false,
                "nothing may reach the Trash after a mid-copy cancel")
        // Its contents are all still there, including the file that never got folded in.
        for name in ["shared.txt", "a-unique.txt", "b-unique.txt"] {
            #expect(FileManager.default.fileExists(atPath: redundant.appendingPathComponent(name).path),
                    "\(name) must survive in the cancelled copy")
        }

        // The cancel landed between the two steps: the first file folded in, the second never
        // started. Before any copy or after both, a different branch would be exercised.
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("a-unique.txt").path),
                "the in-flight copy completes")
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("b-unique.txt").path) == false,
                "no step may start after the cancel")

        // The group stays listed so a retry can finish it, and the banner says so rather than
        // claiming a merge that didn't happen.
        #expect(manager.duplicateGroups.count == 1)
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("canceled") == true)
        #expect(manager.mergingGroupIDs.isEmpty, "the in-flight marker clears on the cancel path too")
    }

    /// A Trash-less volume whose `copyItem` cancels the run from inside the Nth call, so the cancel
    /// can be aimed at a later fold after an earlier one has completed in full.
    private final class NthCopyCancelGate: FileManager, @unchecked Sendable {
        private final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var seen = 0
            private var progress: Progress?
            let target: Int
            init(target: Int) { self.target = target }
            func trip() -> Bool {
                lock.lock(); defer { lock.unlock() }
                seen += 1
                return seen == target
            }
            func install(_ progress: Progress) { lock.lock(); self.progress = progress; lock.unlock() }
            func awaitProgress() -> Progress? {
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    lock.lock(); let p = progress; lock.unlock()
                    if let p { return p }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                return nil
            }
        }
        private let gate: Gate
        init(cancelOnCopyNumber n: Int) { gate = Gate(target: n); super.init() }
        func installProgress(_ progress: Progress) { gate.install(progress) }
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            if gate.trip() { gate.awaitProgress()?.cancel() }
            try super.copyItem(at: srcURL, to: dstURL)
        }
        override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
    }

    /// A Cancel must not start a destructive step that hadn't begun. The merge trashes its folds in
    /// one deferred `deleteItems` after the fold loop, so that call must not run once the user has
    /// cancelled: on a Trash-less volume a fold completed before Cancel would otherwise be deleted
    /// after it, behind a permanent-delete alert the user never asked for and a second progress
    /// dialog with its own Cancel.
    ///
    /// Two redundant copies: A folds completely (one unique file), B has two, and the cancel fires
    /// inside B's first copy so B's second step observes it, with A finished and queued for the
    /// deferred trash.
    @MainActor
    @Test func cancellingAfterAFoldCompletedDoesNotTrashItAfterTheFact() async throws {
        let base = try makeCanonicalTempRoot(prefix: "MergeCancelDeferredTrash")
        defer { try? FileManager.default.removeItem(at: base) }
        let keeper = base.appendingPathComponent("Keeper")
        let aName = "A-\(UUID().uuidString)"
        let bName = "B-\(UUID().uuidString)"
        let a = base.appendingPathComponent(aName)
        let b = base.appendingPathComponent(bName)

        try write(keeper.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(a.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(a.appendingPathComponent("a-only.txt"), bytes: 5000, fill: 0x41)
        try write(b.appendingPathComponent("shared.txt"), bytes: 5000, fill: 0x53)
        try write(b.appendingPathComponent("b1.txt"), bytes: 5000, fill: 0x42)
        try write(b.appendingPathComponent("b2.txt"), bytes: 5000, fill: 0x43)

        // Copy #1 is A's a-only.txt, copy #2 is B's b1.txt: cancelling there makes B's b2.txt the
        // step that observes it, with A already complete and queued for the deferred trash.
        let gate = NthCopyCancelGate(cancelOnCopyNumber: 2)
        let manager = FileSyncManager(fileManager: gate)
        manager.undoManager = UndoManager()
        let prompts = LockedBox<[[String]]>([])
        manager.permanentDeleteConfirmer = { names in
            prompts.withLock { $0.append(names) }
            return true
        }
        let k = DuplicateCopy(id: keeper.path, name: "Keeper", isDirectory: true, size: 5000, itemCount: 1,
                              modificationDate: nil, uniqueItemCount: 0, depth: 0, isRecommendedKeeper: true)
        let ca = DuplicateCopy(id: a.path, name: aName, isDirectory: true, size: 10000, itemCount: 2,
                               modificationDate: nil, uniqueItemCount: 1, depth: 0, isRecommendedKeeper: false)
        let cb = DuplicateCopy(id: b.path, name: bName, isDirectory: true, size: 15000, itemCount: 3,
                               modificationDate: nil, uniqueItemCount: 2, depth: 0, isRecommendedKeeper: false)
        let group = DuplicateGroup(matchType: .overlapping(sharedFraction: 0.33), name: "Keeper",
                                   isDirectory: true, copies: [k, ca, cb], reclaimableBytes: 5000)
        manager.duplicateGroups = [group]

        let merge = Task { await manager.mergeDuplicateGroup(group) }
        await waitUntil("the merge publishes a cancellable Progress") { manager.activeProgress != nil }
        gate.installProgress(try #require(manager.activeProgress))
        let ok = await merge.value

        #expect(ok == false)
        // The cancel landed where the fixture aims it: A folded, B's second file never started.
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("a-only.txt").path),
                "A never folded — the cancel landed too early for this pin")
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("b2.txt").path) == false,
                "a step started after the cancel — the cancel landed too late for this pin")

        // The invariant: the cancel stopped the trash that hadn't begun.
        #expect(prompts.withLock { $0 }.isEmpty,
                "the Cancel was answered with a permanent-delete confirmation the user never asked for: \(prompts.withLock { $0 })")
        #expect(FileManager.default.fileExists(atPath: a.path),
                "the fold completed before the Cancel was destroyed after it")
        #expect(FileManager.default.fileExists(atPath: b.path))

        // The banner says nothing was trashed and carries the flag, so `invalidateUndoableBanner`
        // can retire the ⌘Z offer when the stack moves on.
        let message = manager.banner?.message ?? ""
        #expect(message.contains("canceled"), "banner: “\(message)”")
        #expect(message.contains("nothing was trashed"),
                "the cancel banner does not say the copies were left alone: “\(message)”")
        #expect(manager.banner?.isUndoable == true,
                "the cancel banner offers ⌘Z in prose but ships isUndoable false, so the offer cannot be retired")
    }
}
