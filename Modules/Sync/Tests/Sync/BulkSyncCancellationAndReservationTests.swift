import Testing
import Foundation
import Events
@testable import Sync

/// The two untested halves of "Apply all" — the app's single most destructive surface.
///
/// 1. **Mid-run cancellation.** `CancellationTests` covers the serial `transferItems`/`deleteItems`
///    loops; nothing cancelled a PARALLEL bulk run. The contract of the worker loop's
///    `while !progressRef.progress.isCancelled` (`processInParallel`) is that cancellation is
///    observed only BETWEEN items: every worker's in-flight item completes atomically, no worker
///    takes a new one afterwards, and the run then reports and records exactly what landed —
///    not the total it set out to do.
/// 2. **Batch destination reservation.** `reservedTargets`/`reservedKey` exist because targets are
///    resolved up front but the copies run in parallel, so a disk-only uniqueness check cannot see
///    another item's pending target; its own comment calls the failure "silent data loss". The
///    reservation is only HALF covered: `BulkOperationsTests` pins the post-loop
///    `reservedTargets.contains` guard, but nothing exercises the reserved set from inside
///    `generateUniqueURL` — the ordering pinned here.
@Suite struct BulkSyncCancellationAndReservationTests {

    // MARK: Helpers

    /// Cancels the run at the one instant that makes the assertion deterministic: when ALL
    /// `width` workers are inside a copy, so none can be looping back for another item. The
    /// arrivals rendezvous on a barrier; the last one cancels the run's `Progress` and frees
    /// the rest.
    ///
    /// The cancellation is performed by the gate itself, on the worker's own thread, rather than
    /// by the test reacting to a signal — a test-side cancel has to be scheduled on the MainActor,
    /// which under the full parallel suite (900 tests, most of them `@MainActor`) can be starved
    /// for many seconds while the workers sit parked. The gate never needs the MainActor, so the
    /// cancel lands at the same point whether the suite runs alone or under load.
    ///
    /// Only the `safeCopyItem` staging call is intercepted — `MockFileManager.moveItem` reaches
    /// its own `copyItem` internally, below this wrapper — so one arrival means one item.
    /// An arrival BEYOND `width` never waits: a regression that keeps taking items must fail
    /// on the assertions, not by deadlocking.
    private final class BarrierCancelGate: FileManaging, @unchecked Sendable {
        let inner: MockFileManager
        private let width: Int
        private let lock = NSLock()
        private var arrived = 0
        private let barrier = DispatchSemaphore(value: 0)
        private let progressBox = LockedBox<Progress?>(nil)
        private var timedOut = false

        /// True if a worker gave up at the barrier, or if the cancelling worker never got the
        /// run's Progress. Both bounds exist so a mis-wire fails instead of hanging — but a
        /// discarded bound is worse than none: the rendezvous silently degrades into four
        /// independent copies, no cancel ever lands, and "the gate never engaged" becomes
        /// indistinguishable from "cancellation was observed and four items still landed",
        /// which is precisely what these tests assert. Tests `try #require(!gate.releasedByTimeout)`.
        var releasedByTimeout: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }

        private func recordTimeout() { lock.lock(); timedOut = true; lock.unlock() }

        init(inner: MockFileManager, width: Int) { self.inner = inner; self.width = width }

        /// Hands the gate the run's Progress. Called by the test as soon as the run publishes one;
        /// the gate waits for it, so installing it late cannot make the cancel land early.
        func installProgress(_ progress: Progress) { progressBox.withLock { $0 = progress } }

        private func awaitProgress() -> Progress? {
            let deadline = Date().addingTimeInterval(30)   // bounded: a mis-wire fails, never hangs
            while Date() < deadline {
                if let progress = progressBox.withLock({ $0 }) { return progress }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return nil
        }

        func copyItem(at s: URL, to d: URL) throws {
            lock.lock(); arrived += 1; let n = arrived; lock.unlock()
            if n < width {
                if barrier.wait(timeout: .now() + 30) == .timedOut { recordTimeout() }
            } else if n == width {
                if let progress = awaitProgress() { progress.cancel() } else { recordTimeout() }
                for _ in 0..<(width - 1) { barrier.signal() }
            }
            try inner.copyItem(at: s, to: d)
        }
        func moveItem(at s: URL, to d: URL) throws { try inner.moveItem(at: s, to: d) }
        func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            try inner.trashItem(at: u, resultingItemURL: o)
        }
        func replaceItem(at d: URL, withItemAt s: URL, backupItemName n: String) throws -> URL? {
            try inner.replaceItem(at: d, withItemAt: s, backupItemName: n)
        }
        func removeItem(at u: URL) throws { try inner.removeItem(at: u) }
        func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
        func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: p, isDirectory: d)
        }
        func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] { try inner.attributesOfItem(atPath: p) }
        func setAttributes(_ a: [FileAttributeKey: Any], ofItemAtPath p: String) throws { try inner.setAttributes(a, ofItemAtPath: p) }
        func createDirectory(at u: URL, withIntermediateDirectories c: Bool, attributes a: [FileAttributeKey: Any]?) throws {
            try inner.createDirectory(at: u, withIntermediateDirectories: c, attributes: a)
        }
        func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions, errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        }
    }

    private func diff(_ name: String, size: Int? = nil) -> FileDifference {
        FileDifference(
            relativePath: name,
            leftItemPath: "/src/\(name)",
            rightItemPath: "/dst/\(name)",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right",
            leftFileSize: size
        )
    }

    private func seed(_ disk: MockFileManager, _ path: String, size: Int) {
        disk.virtualDisk[path] = MockFileManager.FileStub(isDirectory: false, attributes: [.size: size], contents: nil)
    }

    /// Names of the `.txt` files currently under `dir` on the virtual disk.
    private func files(_ disk: MockFileManager, under dir: String) -> Set<String> {
        Set(disk.virtualDisk.keys
            .filter { $0.hasPrefix(dir + "/") && $0.hasSuffix(".txt") }
            .map { ($0 as NSString).lastPathComponent })
    }

    private func size(_ disk: MockFileManager, _ path: String) -> Int? {
        (disk.virtualDisk[path]?.attributes?[.size] as? Int)
    }

    // MARK: 1. Mid-run cancellation of a parallel bulk run

    @MainActor
    @Test func syncAllCancelledMidRunFinishesInFlightItemsAndTakesNoMore() async throws {
        let disk = MockFileManager()
        try disk.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        // Six items against a worker pool of four: two can never be taken once the four in flight
        // are parked, so "stopped taking new items" is observable rather than timing-dependent.
        let names = (1...6).map { "f\($0).txt" }
        for (index, name) in names.enumerated() { seed(disk, "/src/\(name)", size: 100 + index) }

        let gate = BarrierCancelGate(inner: disk, width: 4)
        let manager = FileSyncManager(fileManager: gate)
        let diffs = names.map { diff($0, size: 100) }
        manager.rawDifferences = diffs
        manager.differences = diffs

        let run = Task { await manager.syncAll(direction: .copyToRight) }
        // Hand the gate the run's Progress; it cancels once all four workers are inside a copy —
        // the instant at which items 5 and 6 are provably still in the queue.
        await waitUntil("the run publishes a cancellable Progress") { manager.activeProgress != nil }
        gate.installProgress(try #require(manager.activeProgress))
        await run.value
        try #require(!gate.releasedByTimeout, "the barrier timed out: the four workers never rendezvoused, so no cancel landed mid-run")

        // Exactly the four in-flight items landed — each one whole, none half-written.
        let landed = files(disk, under: "/dst")
        #expect(landed.count == 4, "only the in-flight items may complete, got \(landed.sorted())")
        #expect(landed.isSubset(of: Set(names)))
        #expect(disk.virtualDisk.keys.contains { $0.contains(".tmp_") } == false, "no staging file may survive a cancel")
        // A copy leaves every source in place.
        #expect(files(disk, under: "/src") == Set(names))

        // The run reports honestly: the two never-taken items are still listed as unresolved, and
        // they are exactly the ones absent from the destination.
        let remaining = Set(manager.differences.map(\.relativePath))
        #expect(remaining == Set(names).subtracting(landed))
        #expect(Set(manager.rawDifferences.map(\.relativePath)) == remaining,
                "the raw list must drop the same items, or a filter change resurrects synced rows")
        // …and records honestly: four history records, not six.
        #expect(manager.lastRecordedRunRecords.count == 4)
        #expect(Set(manager.lastRecordedRunRecords.compactMap { $0.destPath.map { ($0 as NSString).lastPathComponent } }) == landed)
        // A cancel is not a failure: no alert, and the banner counts what actually landed.
        #expect(manager.currentError == nil)
        #expect(manager.banner?.severity == .success)
        #expect(manager.banner?.message == "Copied 4 items")
        // The run released its shared latches, so the next bulk operation is not refused forever.
        #expect(manager.isBulkSyncRunning == false)
        #expect(manager.syncingDifferenceIds.isEmpty)
        #expect(manager.bulkSyncProgress == nil)
    }

    @MainActor
    @Test func bulkCopyLeftToRightCancelledMidRunFinishesInFlightItemsAndTakesNoMore() async throws {
        // Same contract on the second entry point onto the shared worker scaffolding
        // (`bulkCopyDifferencesLeftToRight`, the "copy to match dates" path), which reaches it
        // without syncAll's prepare/collision phase.
        let disk = MockFileManager()
        try disk.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        let names = (1...6).map { "d\($0).txt" }
        for (index, name) in names.enumerated() { seed(disk, "/src/\(name)", size: 200 + index) }

        // concurrency here is min(4, max(2, count)) = 4, the same worker width as syncAll.
        let gate = BarrierCancelGate(inner: disk, width: 4)
        let manager = FileSyncManager(fileManager: gate)
        let diffs = names.map { diff($0, size: 100) }
        manager.rawDifferences = diffs
        manager.differences = diffs

        // Current stamp: this test is about mid-run cancellation, not the staleness guard.
        let run = Task { await manager.bulkCopyDifferencesLeftToRight(diffs, asOf: manager.fileOperationsEpoch) }
        await waitUntil("the run publishes a cancellable Progress") { manager.activeProgress != nil }
        gate.installProgress(try #require(manager.activeProgress))
        await run.value
        try #require(!gate.releasedByTimeout, "the barrier timed out: the four workers never rendezvoused, so no cancel landed mid-run")

        let landed = files(disk, under: "/dst")
        #expect(landed.count == 4, "only the in-flight items may complete, got \(landed.sorted())")
        #expect(disk.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
        #expect(Set(manager.differences.map(\.relativePath)) == Set(names).subtracting(landed))
        #expect(manager.lastRecordedRunRecords.count == 4)
        #expect(manager.currentError == nil)
        #expect(manager.isBulkSyncRunning == false)
        #expect(manager.syncingDifferenceIds.isEmpty)
    }

    // MARK: 2. Batch destination reservation (reservedTargets / reservedKey)

    @MainActor
    @Test func aKeepBothTargetNeverLandsOnAnotherItemsRealDestination() async throws {
        // `BulkOperationsTests.testSyncAllKeepBothDoesNotCollideWithAnotherBatchTarget` already
        // covers one ordering — keep-both item FIRST, so the second item's plain target is pushed
        // aside by the post-loop `reservedTargets.contains` guard. This is the MIRROR ordering,
        // which nothing covered: the plain-target item comes first and reserves "/dst/note 2.txt",
        // and the keep-both item must then skip straight past that reserved name while it is being
        // uniquified. That half lives inside `generateUniqueURL(reserved:)`, which no test reaches
        // with a non-empty `reserved` set — the post-loop guard cannot stand in for it, because a
        // keep-both name is chosen before the guard ever looks.
        let disk = MockFileManager()
        try disk.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seed(disk, "/src/note 2.txt", size: 111)
        seed(disk, "/src/note.txt", size: 222)
        seed(disk, "/dst/note.txt", size: 999)

        let manager = FileSyncManager(fileManager: disk)
        manager.bulkCollisionResolver = { _ in (.keepBoth, false) }
        let diffs = [diff("note 2.txt", size: 111), diff("note.txt", size: 222)]
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        #expect(files(disk, under: "/dst") == ["note.txt", "note 2.txt", "note 3.txt"])
        #expect(size(disk, "/dst/note.txt") == 999)
        #expect(size(disk, "/dst/note 2.txt") == 111, "the plain-target item keeps its real name")
        #expect(size(disk, "/dst/note 3.txt") == 222, "keep-both skipped the reserved \" 2\" name")
        #expect(manager.currentError == nil)
    }

    // MARK: 3. Case sensitivity is a property of each DESTINATION, not of the batch

    /// A `diff` whose destination sits in a named subfolder of /dst.
    private func diff(_ name: String, inSubfolder folder: String, size: Int) -> FileDifference {
        FileDifference(
            relativePath: "\(folder)/\(name)",
            leftItemPath: "/src/\(folder)/\(name)",
            rightItemPath: "/dst/\(folder)/\(name)",
            type: .missingOnRight,
            action: .copyToRight,
            description: "Missing on right",
            leftFileSize: size
        )
    }

    @MainActor
    @Test func aCaseSensitiveDestinationDoesNotSpeakForACaseInsensitiveOne() async throws {
        // One batch can span volumes — a nested mount inside the destination root, or a pane rooted
        // at /Volumes. The case-sensitivity answer used to be taken ONCE, from `candidates.first`,
        // and then applied to every candidate's reservation key. So a first item landing on a
        // case-SENSITIVE mount switched off case folding for items landing on the case-INSENSITIVE
        // boot volume: two targets differing only by case both passed the in-memory uniqueness
        // check, and the parallel workers wrote to the same file. With `isMove` both sources are
        // consumed and one file's contents are gone — a success banner, no Trash entry, nothing to
        // undo.
        //
        // The probe is injected because the bug needs two volumes and a test machine has one; the
        // production probe answers per destination the same way this stub does.
        let disk = MockFileManager()
        try disk.createDirectory(at: URL(fileURLWithPath: "/src/mounted"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/src/plain"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/dst/mounted"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/dst/plain"), withIntermediateDirectories: true)
        seed(disk, "/src/mounted/first.txt", size: 111)
        seed(disk, "/src/plain/README.txt", size: 222)
        seed(disk, "/src/plain/Readme.txt", size: 333)

        let manager = FileSyncManager(fileManager: disk)
        // /dst/mounted is a case-sensitive mount; /dst/plain is on the case-insensitive volume.
        let probedParents = LockedBox<[String]>([])
        manager.destinationCaseSensitivity = { url in
            let parent = url.deletingLastPathComponent().path
            probedParents.withLock { $0.append(parent) }
            return parent == "/dst/mounted"
        }
        // Ordered so the case-SENSITIVE destination is the one `candidates.first` would have
        // answered for — the exact arrangement that used to disable folding for the other two.
        let diffs = [
            diff("first.txt", inSubfolder: "mounted", size: 111),
            diff("README.txt", inSubfolder: "plain", size: 222),
            diff("Readme.txt", inSubfolder: "plain", size: 333),
        ]
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        // The observable protection is the NAME the batch reserves, which is what this asserts:
        // the virtual disk keys by exact string and so is inherently case-sensitive, meaning it
        // cannot itself reproduce the collapse a real case-insensitive volume performs. On such a
        // volume "README.txt" and "Readme.txt" ARE one file, so a batch that reserves both verbatim
        // hands two workers the same destination. Folding the /dst/plain keys is what pushes the
        // second one to a distinct name — and that name is visible here.
        #expect(files(disk, under: "/dst/plain") == ["README.txt", "Readme 2.txt"],
                "the case-insensitive destination must fold, so the second variant gets its own name")
        #expect(size(disk, "/dst/mounted/first.txt") == 111)
        #expect(size(disk, "/dst/plain/README.txt") == 222)
        #expect(size(disk, "/dst/plain/Readme 2.txt") == 333)
        #expect(manager.currentError == nil)
        // Structural half of the same claim, and the one no downstream interplay can mask: BOTH
        // destinations were asked about. A batch that takes one answer from `candidates.first`
        // probes a single parent, whatever it then does with it. (Memoized per parent, so the
        // three items yield exactly these two.)
        #expect(Set(probedParents.withLock { $0 }) == ["/dst/mounted", "/dst/plain"])
    }

    @MainActor
    @Test func aCaseSensitiveDestinationStillKeepsBothSpellingsVerbatim() async throws {
        // The control, and the reason the probe was taught to answer at all: when the destination
        // really IS case-sensitive, two case variants are two different names and neither should be
        // uniquified to "… 2".
        //
        // Worth knowing what this does NOT catch: a build that folds unconditionally still passes,
        // because the reserved set would then hold folded keys while `generateUniqueURL` is handed
        // this destination's own (case-sensitive) rule, so its lookup misses and the uniquify
        // no-ops. The two only ever disagree under such a mutation — production derives both from
        // one per-destination answer. The dangerous direction (failing to fold where the volume
        // collapses case) is pinned by the test above.
        let disk = MockFileManager()
        try disk.createDirectory(at: URL(fileURLWithPath: "/src/mounted"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/dst/mounted"), withIntermediateDirectories: true)
        seed(disk, "/src/mounted/README.txt", size: 222)
        seed(disk, "/src/mounted/Readme.txt", size: 333)

        let manager = FileSyncManager(fileManager: disk)
        manager.destinationCaseSensitivity = { _ in true }
        let diffs = [
            diff("README.txt", inSubfolder: "mounted", size: 222),
            diff("Readme.txt", inSubfolder: "mounted", size: 333),
        ]
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        #expect(files(disk, under: "/dst/mounted") == ["README.txt", "Readme.txt"])
        #expect(size(disk, "/dst/mounted/README.txt") == 222)
        #expect(size(disk, "/dst/mounted/Readme.txt") == 333)
    }
}
