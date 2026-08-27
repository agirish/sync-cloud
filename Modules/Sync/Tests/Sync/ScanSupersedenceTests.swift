import Foundation
import Testing
@testable import Sync

/// Regression coverage for superseded scans: a scan queued behind an in-flight one must still
/// publish (the drain must not inherit the predecessor's cancellation), and a superseded scan's
/// disk walk must abort instead of holding `isScanning` for results nobody will read.
@Suite struct ScanSupersedenceTests {

    private static let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", path: "/left", type: .iCloud)
    private static let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", path: "/right", type: .iCloud)

    private func file() -> MockFileManager.FileStub {
        MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
    }

    // MARK: Bug: queued scan's results were discarded when drained on a cancelled task

    /// The only production path that queues a pending scan: refresh A is mid-walk when refresh B
    /// arrives; B cancels A's task, and B's scanDirectories sees `isScanning` and queues. A's
    /// un-cancellable walk finishes and drains B's request — that drain must run B's scan on a
    /// task that does NOT inherit A's cancellation, or B's fresh differences are silently dropped
    /// and the list keeps showing the previous folder's rows.
    @MainActor
    @Test func testScanQueuedFromCancelledPredecessorStillPublishes() async throws {
        let mockFM = MockFileManager()
        mockFM.enumeratorDelay = 0.15
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
        await waitUntil("scan starts") { manager.isScanning }
        #expect(manager.isScanning)

        // Refresh B: cancel A (as refreshTreesAndScan does), then request the new folders while
        // A's walk still holds the scanning slot — the request queues.
        scanA.cancel()
        await manager.scanDirectories(left: Self.left, leftPath: "/newL", right: Self.right, rightPath: "/newR")
        #expect(manager.pendingScanRequest != nil)

        // A unwinds and drains the queued request.
        await scanA.value
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

    /// Wraps a mock disk with an enumerator that sleeps per yielded entry, so a full walk takes
    /// seconds — long enough to observe whether cancelling the scan actually aborts the walk.
    private final class SlowWalkFileManager: FileManaging, @unchecked Sendable {
        private let inner: MockFileManager
        let perItemDelay: TimeInterval
        init(inner: MockFileManager, perItemDelay: TimeInterval) {
            self.inner = inner
            self.perItemDelay = perItemDelay
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

        private final class SlowEnumerator: FileManager.DirectoryEnumerator {
            private let wrapped: FileManager.DirectoryEnumerator?
            private let delay: TimeInterval
            init(wrapping: FileManager.DirectoryEnumerator?, delay: TimeInterval) {
                self.wrapped = wrapping
                self.delay = delay
            }
            override func nextObject() -> Any? {
                guard let next = wrapped?.nextObject() else { return nil }
                Thread.sleep(forTimeInterval: delay)
                return next
            }
        }

        func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions, errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            SlowEnumerator(wrapping: inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h), delay: perItemDelay)
        }
    }

    /// Cancelling a running scan must propagate into the detached disk walks: the scan winds
    /// down promptly (well under the full-walk time) and publishes nothing.
    @MainActor
    @Test(.parksThreads(2)) func testCancellingScanAbortsTheDiskWalkPromptly() async throws {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/left"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/right"), withIntermediateDirectories: true)
        // 100 entries x 40ms each = ~4s for an uncancelled walk.
        for i in 0..<100 {
            mockFM.virtualDisk["/left/file\(i).txt"] = file()
        }
        let slowFM = SlowWalkFileManager(inner: mockFM, perItemDelay: 0.04)
        let manager = FileSyncManager(fileManager: slowFM)

        let scan = Task {
            await manager.scanDirectories(left: Self.left, leftPath: "/left", right: Self.right, rightPath: "/right")
        }
        await waitUntil("scan starts") { manager.isScanning }
        #expect(manager.isScanning)

        let cancelledAt = Date()
        scan.cancel()
        await scan.value
        await waitUntil("scan finishes") { !manager.isScanning }

        // Aborted mid-walk: nowhere near the ~4s a full walk takes.
        #expect(Date().timeIntervalSince(cancelledAt) < 2.0)
        #expect(!manager.isScanning)
        #expect(!manager.hasScanned)
        #expect(manager.differences.isEmpty)
    }

    // MARK: - The user's Cancel

    /// `cancelScan()` cancels the in-flight refresh task — the link that turns a button press into
    /// a stopped scan.
    ///
    /// Driven against the task handle rather than a slow filesystem on purpose. The end of that
    /// chain — a cancelled task aborts the disk walk and publishes nothing — is already held
    /// deterministically by `testCancellingScanAbortsTheDiskWalkPromptly` above; an end-to-end
    /// version here would have to make a whole `refreshTreesAndScan` slow, and the only lever for
    /// that (`SlowWalkFileManager`) sleeps on whatever thread the enumerator runs on, which starves
    /// the very main actor a test has to poll from. The first cut did exactly that and never
    /// observed `isScanning` at all.
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

    /// The negative control for the test above, and the guard's real job: `activeRefreshTask` is
    /// never nilled out — only overwritten — so a completed refresh leaves a finished handle
    /// sitting there, and a `cancelScan` written against the handle alone would "cancel" long
    /// after the last scan ended. Liveness is the KEY (or a running scan), not the handle.
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

    /// A DRAINED scan — one queued behind a superseded scan and run afterwards — is the single
    /// path that reaches `executeScan` outside a refresh task. Its refresh has already finished
    /// and released the key, so `activeRefreshTask` is stale and cancelling it does nothing; the
    /// Stop button, which shows for as long as `isScanning`, would be dead for that whole scan.
    ///
    /// Both facts are asserted, because either alone passes for the wrong reason: the guard has to
    /// admit this state (`isScanning` with no key), and the drain handle has to be the thing that
    /// gets cancelled.
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

    /// Cancel must also drop a scan that is QUEUED but not started, or the drain at the end of
    /// `executeScan` starts a fresh scan the instant the cancelled one unwinds — and Cancel looks
    /// like it did nothing at all.
    ///
    /// Driven by writing `pendingScanRequest` directly, which is exactly what a superseding refresh
    /// leaves behind, and pins the rule without a second timing-dependent fixture.
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
