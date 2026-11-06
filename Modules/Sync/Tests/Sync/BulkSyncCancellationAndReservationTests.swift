import Testing
import Foundation
import Events
@testable import Sync

/// Two parts of "Apply all", the app's most destructive surface.
///
/// 1. Mid-run cancellation of a parallel bulk run (`CancellationTests` covers the serial loops).
///    `processInParallel` observes cancellation only between items: each in-flight item completes
///    whole, no worker takes another, and the run reports and records exactly what landed.
/// 2. Batch destination reservation. Targets are resolved up front but copied in parallel, so a
///    disk-only uniqueness check can't see another item's pending target: silent data loss.
///    `BulkOperationsTests` pins the post-loop `reservedTargets.contains` guard; this pins the
///    reserved set inside `generateUniqueURL`.
@Suite struct BulkSyncCancellationAndReservationTests {

    // MARK: Helpers

    /// Cancels the run when all `width` workers are inside a copy, so none can loop back for
    /// another item. Arrivals rendezvous on a barrier; the last cancels the run's `Progress` and
    /// frees the rest.
    ///
    /// The gate cancels on the worker's own thread: a test-side cancel would need the main actor,
    /// which a full parallel run can starve for seconds while the workers sit parked.
    ///
    /// Only the `safeCopyItem` staging call is intercepted (`MockFileManager.moveItem` calls its
    /// own `copyItem` below this wrapper), so one arrival is one item. An arrival beyond `width`
    /// never waits, so a regression that keeps taking items fails the assertions, not by deadlock.
    private final class BarrierCancelGate: FileManaging, @unchecked Sendable {
        let inner: MockFileManager
        private let width: Int
        private let lock = NSLock()
        private var arrived = 0
        private let barrier = DispatchSemaphore(value: 0)
        private let progressBox = LockedBox<Progress?>(nil)
        private var timedOut = false

        /// True if a worker gave up at the barrier or the cancelling worker never got the run's
        /// Progress. The bounds keep a mis-wire from hanging, but must be recorded: otherwise a gate
        /// that never engaged looks like a cancel after which four items landed, which is what these
        /// tests assert. Tests `try #require(!gate.releasedByTimeout)`.
        var releasedByTimeout: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }

        private func recordTimeout() { lock.lock(); timedOut = true; lock.unlock() }

        init(inner: MockFileManager, width: Int) { self.inner = inner; self.width = width }

        /// Hands the gate the run's Progress once the run publishes one. The gate waits for it, so
        /// installing it late can't make the cancel land early.
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

    /// Needs more than four cores: the four workers block inside a copy at once, the cooperative
    /// pool is as wide as the core count, and the release needs a thread of its own. On a 3-vCPU
    /// hosted runner the rendezvous can't form.
    @MainActor
    @Test(.parksThreads(4),
          .enabled(if: cooperativePoolWidth > 4,
                   "four workers blocked at once plus the release need more than four cores"))
    func syncAllCancelledMidRunFinishesInFlightItemsAndTakesNoMore() async throws {
        let disk = MockFileManager()
        try disk.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try disk.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        // Six items, four workers: two can't be taken while four are parked, so "stopped taking
        // new items" is observable, not timing-dependent.
        let names = (1...6).map { "f\($0).txt" }
        for (index, name) in names.enumerated() { seed(disk, "/src/\(name)", size: 100 + index) }

        let gate = BarrierCancelGate(inner: disk, width: 4)
        let manager = FileSyncManager(fileManager: gate)
        let diffs = names.map { diff($0, size: 100) }
        manager.rawDifferences = diffs
        manager.differences = diffs

        let run = Task { await manager.syncAll(direction: .copyToRight) }
        // The gate cancels once all four workers are inside a copy, while items 5 and 6 are
        // still queued.
        await waitUntil("the run publishes a cancellable Progress") { manager.activeProgress != nil }
        gate.installProgress(try #require(manager.activeProgress))
        await run.value
        try #require(!gate.releasedByTimeout, "the barrier timed out: the four workers never rendezvoused, so no cancel landed mid-run")

        // Exactly the four in-flight items landed, each whole.
        let landed = files(disk, under: "/dst")
        #expect(landed.count == 4, "only the in-flight items may complete, got \(landed.sorted())")
        #expect(landed.isSubset(of: Set(names)))
        #expect(disk.virtualDisk.keys.contains { $0.contains(".tmp_") } == false, "no staging file may survive a cancel")
        // A copy leaves every source in place.
        #expect(files(disk, under: "/src") == Set(names))

        // The two never-taken items are still listed, and are exactly the ones not at the
        // destination.
        let remaining = Set(manager.differences.map(\.relativePath))
        #expect(remaining == Set(names).subtracting(landed))
        #expect(Set(manager.rawDifferences.map(\.relativePath)) == remaining,
                "the raw list must drop the same items, or a filter change resurrects synced rows")
        // Four history records, not six.
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

    // MARK: 2. Batch destination reservation (reservedTargets / reservedKey)

    @MainActor
    @Test func aKeepBothTargetNeverLandsOnAnotherItemsRealDestination() async throws {
        // The mirror of `BulkOperationsTests.testSyncAllKeepBothDoesNotCollideWithAnotherBatchTarget`
        // (keep-both first, caught by the post-loop guard). Here the plain-target item reserves
        // "/dst/note 2.txt" first, and the keep-both item must skip that name while uniquifying,
        // inside `generateUniqueURL(reserved:)`: its name is chosen before the post-loop guard looks.
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
        // One batch can span volumes (a nested mount in the destination, or a pane at /Volumes), so
        // case sensitivity is asked per destination. One answer for the whole batch would let a
        // case-sensitive first item switch off folding on a case-insensitive volume: two names
        // differing only by case would pass the uniqueness check and the workers write one file.
        // With `isMove` one file's contents are gone, with a success banner and nothing to undo.
        //
        // The probe is injected because this needs two volumes; production answers per
        // destination the same way.
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
        // The case-sensitive destination comes first, so a batch-wide answer taken from
        // `candidates.first` would disable folding for the other two.
        let diffs = [
            diff("first.txt", inSubfolder: "mounted", size: 111),
            diff("README.txt", inSubfolder: "plain", size: 222),
            diff("Readme.txt", inSubfolder: "plain", size: 333),
        ]
        manager.rawDifferences = diffs
        manager.differences = diffs

        await manager.syncAll(direction: .copyToRight)

        // Asserts the name the batch reserves: the virtual disk is case-sensitive, so it can't
        // collapse names the way a real case-insensitive volume does, where "README.txt" and
        // "Readme.txt" are one file. Folding the /dst/plain keys moves the second to its own name.
        #expect(files(disk, under: "/dst/plain") == ["README.txt", "Readme 2.txt"],
                "the case-insensitive destination must fold, so the second variant gets its own name")
        #expect(size(disk, "/dst/mounted/first.txt") == 111)
        #expect(size(disk, "/dst/plain/README.txt") == 222)
        #expect(size(disk, "/dst/plain/Readme 2.txt") == 333)
        #expect(manager.currentError == nil)
        // Both destinations were asked about; a batch-wide answer would probe one parent. Memoized
        // per parent, so three items give exactly these two.
        #expect(Set(probedParents.withLock { $0 }) == ["/dst/mounted", "/dst/plain"])
    }

    @MainActor
    @Test func aCaseSensitiveDestinationStillKeepsBothSpellingsVerbatim() async throws {
        // The control: on a case-sensitive destination two case variants are two names, and
        // neither is uniquified to "… 2".
        //
        // Folding unconditionally still passes here: the reserved keys would be folded while
        // `generateUniqueURL` gets this destination's case-sensitive rule, so its lookup misses.
        // The dangerous direction, not folding where the volume collapses case, is the test above.
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
