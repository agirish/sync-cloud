import Testing
import Foundation
@testable import Sync

/// The one duplicate-merge guard with no coverage: `cancelledMidCopy`.
///
/// Every sibling refusal (keeper drift, source drift, symlinked keeper dir, vanished keeper,
/// trash failure, nested copy) is pinned in `FileSyncManagerDuplicatesTests`; the cancel branch —
/// the one that enforces "a partially-folded copy is NEVER trashed" — was not. A regression here
/// does not throw or warn: it trashes a folder whose contents only partly reached the keeper.
///
/// The cancel point is chosen deterministically by parking the merge inside its FIRST file copy,
/// cancelling the run's `Progress` while it cannot advance, then releasing it — so the second
/// plan step is guaranteed to be the one that observes the cancellation.
@Suite struct MergeCancelMidCopyTests {

    /// A real `FileManager` (the merge hashes real bytes, so a mock disk cannot drive this path)
    /// that cancels the run's `Progress` from inside the FIRST `copyItem` — after the copy phase
    /// has begun, before that copy returns — and then lets the copy complete. Step 2 is therefore
    /// guaranteed to be the iteration that observes the cancellation.
    ///
    /// The gate cancels on the worker's own thread rather than signalling the test to do it: a
    /// test-side cancel must be scheduled on the MainActor, which the full parallel suite can
    /// starve for seconds while the copy sits parked, and the cancel would then land in the wrong
    /// place (or not at all).
    ///
    /// A `FileManager` subclass rather than a `FileManaging` wrapper for the reason `buildTree`
    /// documents: only the `fileManager is FileManager` fast path yields file sizes, and without
    /// sizes there is nothing to hash or plan.
    private final class FirstCopyCancelGate: FileManager, @unchecked Sendable {
        /// FileManager is already (unchecked) Sendable, so a subclass may not add mutable stored
        /// state directly — it lives in a lock-guarded box.
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

        /// Hands the gate the merge's Progress. The gate waits for it, so a late install cannot
        /// make the cancellation land early.
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
        // Unique folder name so the assertion below can also prove nothing reached ~/.Trash, and
        // so a regression (which WOULD trash it) leaves no ambiguity about whose folder it is.
        let rName = "Redundant-\(UUID().uuidString)"
        let redundant = base.appendingPathComponent(rName)
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(rName)")
        defer { try? FileManager.default.removeItem(at: trashed) }

        // shared.txt is byte-identical on both sides, so it is skipped by the plan; the two unique
        // files become plan steps in name order — step 1 "a-unique.txt", step 2 "b-unique.txt".
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

        // THE INVARIANT: a copy whose fold did not complete is never trashed.
        #expect(FileManager.default.fileExists(atPath: redundant.path),
                "the partially-folded copy must stay on disk")
        #expect(FileManager.default.fileExists(atPath: trashed.path) == false,
                "nothing may reach the Trash after a mid-copy cancel")
        // Its contents are all still there — including the file that never got folded in.
        for name in ["shared.txt", "a-unique.txt", "b-unique.txt"] {
            #expect(FileManager.default.fileExists(atPath: redundant.appendingPathComponent(name).path),
                    "\(name) must survive in the cancelled copy")
        }

        // The cancel landed exactly between the two steps: the first file folded in, the second
        // never started. (If it had cancelled before any copy, or after both, the branch under
        // test would not be the one exercised.)
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("a-unique.txt").path),
                "the in-flight copy completes")
        #expect(FileManager.default.fileExists(atPath: keeper.appendingPathComponent("b-unique.txt").path) == false,
                "no step may start after the cancel")

        // The group stays listed so a retry can finish it, and the banner says so rather than
        // claiming a merge that did not happen.
        #expect(manager.duplicateGroups.count == 1)
        #expect(manager.banner?.severity == .warning)
        #expect(manager.banner?.message.contains("cancelled") == true)
        #expect(manager.mergingGroupIDs.isEmpty, "the in-flight marker clears on the cancel path too")
    }
}
