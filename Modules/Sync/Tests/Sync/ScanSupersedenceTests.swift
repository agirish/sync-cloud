import Foundation
import Testing
@testable import Sync

/// Regression coverage for superseded scans: a scan queued behind an in-flight one must still
/// publish (the drain must not inherit the predecessor's cancellation), and a superseded scan's
/// disk walk must abort instead of holding `isScanning` for results nobody will read.
@Suite struct ScanSupersedenceTests {

    private static let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", rootPath: "/left", type: .iCloud)
    private static let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", rootPath: "/right", type: .iCloud)

    private func file() -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
    }

    // MARK: Bug: queued scan's results were discarded when drained on a cancelled task

    /// Refresh A is mid-walk when refresh B arrives: B cancels A's task and queues, since A still
    /// holds `isScanning`. A's walk drains B's request, and that drain must not inherit A's
    /// cancellation, or B's differences are dropped and the list keeps the previous folder's rows.
    @MainActor
    @Test(.parksAThread) func testScanQueuedFromCancelledPredecessorStillPublishes() async throws {
        let mockFM = MockFileManager()
        // A's walk parks here until released, so A holds the scanning slot while B arrives. A
        // gate, not an enumerator delay: a delay only makes that window likely, and a loaded run
        // can miss it.
        let gate = ParkGate()
        mockFM.enumeratorGate = gate
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/oldL"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/oldR"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/newL"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/newR"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/oldL/old_only.txt"] = file()
        mockFM.virtualDisk["/newL/new_only.txt"] = file()

        let manager = FileSyncManager(fileManager: mockFM)

        // Scan A (the "previous folder"), on a task a superseding refresh will cancel.
        let scanA = Task {
            await manager.scanDirectories(left: Self.left, leftPath: "/oldL", right: Self.right, rightPath: "/oldR")
        }
        await awaitSignal(gate.entered, "scan A never reached its walk — nothing held the slot")
        #expect(manager.isScanning)

        // Refresh B: cancel A (as refreshTreesAndScan does), then request the new folders while
        // A's walk still holds the scanning slot — the request queues.
        scanA.cancel()
        await manager.scanDirectories(left: Self.left, leftPath: "/newL", right: Self.right, rightPath: "/newR")
        #expect(manager.pendingScanRequest != nil)

        // A unwinds and drains the queued request.
        gate.release.signal()
        await scanA.value
        try #require(!gate.releasedByTimeout, "the gate timed out: scan A was never actually held in flight")
        await waitUntil("queued scan drains and publishes") { manager.hasScanned && !manager.isScanning && manager.pendingScanRequest == nil }

        // The queued scan's results must be published, not silently discarded.
        #expect(manager.hasScanned)
        #expect(manager.differences.map(\.relativePath) == ["new_only.txt"])
    }

    // MARK: Bug: superseded scans could not be cancelled mid-walk

    /// A cancelled walk must abort with `CancellationError` instead of finishing a full
    /// directory pass whose results are guaranteed to be discarded.
    @Test func testGetFilesInDirectoryAbortsWhenCancelled() async throws {
        let mockFM = MockFileManager()
        mockFM.enumeratorDelay = 0.05
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/src/a.txt"] = file()
        mockFM.virtualDisk["/src/b.txt"] = file()

        let walk = Task.detached {
            try FileDiffEngine.getFilesInDirectory(URL(fileURLWithPath: "/src"), fileManager: mockFM)
        }
        walk.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await walk.value
        }
    }

    /// Wraps a mock disk with an enumerator that counts the entries it hands out and parks inside
    /// the second until the test lets go, so the test cancels while the walk is certainly mid-walk
    /// and then counts how far it read on. Entries, not seconds, because the cancellation check runs
    /// once per entry (`docs/flaky-tests.md`, "Tests racing a real-time window").
    private final class GatedWalkFileManager: FileManaging, @unchecked Sendable {
        private let inner: MockFileManager
        fileprivate let gate = ParkGate()
        private let lock = NSLock()
        private var count = 0
        init(inner: MockFileManager) { self.inner = inner }

        /// How many entries the walks have been handed.
        var served: Int { lock.lock(); defer { lock.unlock() }; return count }

        fileprivate func serve() {
            lock.lock(); count += 1; let n = count; lock.unlock()
            if n == 2 { gate.park() }
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

        private final class GatedEnumerator: FileManager.DirectoryEnumerator {
            private let wrapped: FileManager.DirectoryEnumerator?
            private let disk: GatedWalkFileManager
            init(wrapping: FileManager.DirectoryEnumerator?, disk: GatedWalkFileManager) {
                self.wrapped = wrapping
                self.disk = disk
            }
            override func nextObject() -> Any? {
                guard let next = wrapped?.nextObject() else { return nil }
                disk.serve()
                return next
            }
        }

        func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions, errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            GatedEnumerator(wrapping: inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h), disk: self)
        }
    }

    /// Cancelling a running scan must reach the detached disk walks: the walk stops at its next
    /// entry and the scan publishes nothing. The cancel lands while the walk is parked inside entry
    /// 2 of 100, so a walk that saw it stops at 2 and one that didn't reads on to 100.
    @MainActor
    @Test(.parksAThread) func testCancellingScanAbortsTheDiskWalkPromptly() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/left"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/right"), withIntermediateDirectories: true)
        for i in 0..<100 {
            mockFM.virtualDisk["/left/file\(i).txt"] = file()
        }
        let disk = GatedWalkFileManager(inner: mockFM)
        let manager = FileSyncManager(fileManager: disk)

        let scan = Task {
            await manager.scanDirectories(left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right")
        }
        await awaitSignal(disk.gate.entered, "the walk never reached its second entry")
        #expect(manager.isScanning)

        scan.cancel()
        disk.gate.release.signal()
        await scan.value
        await waitUntil("scan finishes") { !manager.isScanning }
        try #require(!disk.gate.releasedByTimeout, "the gate timed out: the walk was never held mid-walk")

        #expect(disk.served == 2, "the walk read \(disk.served) of 100 entries — it carried on after the cancel")
        #expect(!manager.isScanning)
        #expect(!manager.hasScanned)
        #expect(manager.differences.isEmpty)
    }

    // MARK: - The user's Cancel

    /// `cancelScan()` cancels the in-flight refresh task, the link from the button to a stopped
    /// scan. Driven against the task handle, not a slow filesystem: the rest of the chain is held by
    /// `testCancellingScanAbortsTheDiskWalkPromptly`, and a sleeping enumerator would starve the
    /// main actor this test has to poll from.
    @MainActor
    @Test func testCancelScanCancelsTheInFlightRefreshTask() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let refresh = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        manager.activeRefreshTask = refresh
        manager.activeRefreshKey = manager.makeRefreshKey(left: Self.left, right: Self.right)

        manager.cancelScan()

        #expect(refresh.isCancelled)
        await refresh.value   // returns promptly precisely because the sleep was cancelled
    }

    /// The negative control for the test above: `activeRefreshTask` is only ever overwritten, never
    /// nilled, so a finished refresh leaves a stale handle. Liveness is the key (or a running scan),
    /// not the handle, or `cancelScan` would act long after the last scan ended.
    @MainActor
    @Test func testCancelScanLeavesAFinishedRefreshAlone() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let refresh = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        manager.activeRefreshTask = refresh          // the stale handle a finished refresh leaves
        manager.activeRefreshKey = nil               // ...and the released key that says it is done
        #expect(!manager.isScanning, "nothing may be running, or the guard passes for another reason")

        manager.cancelScan()

        #expect(!refresh.isCancelled)
        refresh.cancel()
        await refresh.value
    }

    /// A drained scan (queued behind a superseded one, run afterwards) is the one path into
    /// `executeScan` outside a refresh task. Its refresh has released the key, so cancelling
    /// `activeRefreshTask` does nothing and Stop would be dead for that scan. Asserts both halves:
    /// the guard admits `isScanning` with no key, and the drain handle is what gets cancelled.
    @MainActor
    @Test func testCancelScanReachesAScanDrainedOutsideARefresh() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        let drain = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        manager.scanDrainTask = drain
        manager.isScanning = true          // the drained scan holds the slot...
        manager.activeRefreshKey = nil     // ...on no refresh at all

        manager.cancelScan()

        #expect(drain.isCancelled)
        await drain.value
    }

    /// Cancel must also drop a queued scan that hasn't started, or the drain at the end of
    /// `executeScan` starts it the instant the cancelled one unwinds and Cancel looks dead. Writes
    /// `pendingScanRequest` directly, as a superseding refresh leaves it, to avoid a timing fixture.
    @MainActor
    @Test func testCancelScanDropsAQueuedScan() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        // Stand in for the in-flight refresh `cancelScan` guards on; without a live key it
        // correctly declines to act, which would make the assertion below vacuous.
        manager.activeRefreshKey = manager.makeRefreshKey(left: Self.left, right: Self.right)
        manager.pendingScanRequest = FileSyncManager.ScanRequest(
            left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right", generation: 7)

        manager.cancelScan()

        #expect(manager.pendingScanRequest == nil)
    }

    /// ...and the same guard seen from the queue's side: with no refresh in flight, a queued
    /// request is left alone.
    @MainActor
    @Test func testCancelScanIsANoOpWithNoRefreshInFlight() async throws {
        let manager = FileSyncManager(fileManager: MockFileManager())
        manager.pendingScanRequest = FileSyncManager.ScanRequest(
            left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right", generation: 7)

        manager.cancelScan()

        #expect(manager.pendingScanRequest != nil)
    }
}
