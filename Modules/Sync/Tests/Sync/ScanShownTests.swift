import Combine
import Foundation
import Testing
@testable import Sync

/// **A Compare scan is shown as running only once it has run long enough to be worth showing.**
///
/// Compare's busy surfaces (its card, its count pill, the panes' Stop rung) used to read
/// `isScanning` directly. Scans of two cached walks finish in 120–400 ms on the user's own pairs, so
/// every one of them flipped all three to "scanning" and straight back: a flash, reported alongside
/// the pane's stacked spinners on 2026-10-03. `isScanShown` is what those surfaces read now.
///
/// **No clock in these tests.** The wait is `scanShownWait`, and each test ends it by hand, so the
/// order "scan ended, then the wait ended" (or the reverse) is a fact of the test rather than a race.
/// A first version raced a real one-second wait against a two-file scan, and on a loaded full-package
/// run the scan alone took longer than the wait.
@MainActor
@Suite struct ScanShownTests {

    private static let left = CloudProvider(id: "l", displayName: "Left", imageName: "folder", rootPath: "/left", type: .iCloud)
    private static let right = CloudProvider(id: "r", displayName: "Right", imageName: "folder", rootPath: "/right", type: .iCloud)

    /// A wait that ends when the test says so. One-shot: `end()` before anyone waits also counts.
    @MainActor private final class Latch {
        private var waiter: CheckedContinuation<Void, Never>?
        private var ended = false
        private(set) var waited = false
        /// True once a wait has returned. Whatever the waiting task does next runs in the same
        /// main-actor job, so by the time a test sees this, that has happened too.
        private(set) var returned = false
        func wait() async {
            waited = true
            if !ended { await withCheckedContinuation { waiter = $0 } }
            returned = true
        }
        func end() {
            ended = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func disk() throws -> MockFileManager {
        let mockFM = MockFileManager()
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/L"), withIntermediateDirectories: true)
        try mockFM.createDirectory(at: URL(fileURLWithPath: "/R"), withIntermediateDirectories: true)
        mockFM.virtualDisk["/L/only_left.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        return mockFM
    }

    /// The figure itself, pinned as a literal: every other test here replaces the wait, so nothing
    /// else would notice the shipped value drifting.
    @Test func theShippedWaitIsThreeQuartersOfASecond() {
        #expect(FileSyncManager.defaultScanShownAfter == .milliseconds(750))
    }

    /// **A scan still running when the wait ends is shown, and stops being shown when it ends.**
    /// The scan parks in its walk, so it is running however slowly this machine gets to the check.
    @Test(.parksAThread) func aScanStillRunningWhenTheWaitEndsIsShownUntilItEnds() async throws {
        let mockFM = try disk()
        let gate = ParkGate()
        mockFM.enumeratorGate = gate
        let manager = FileSyncManager(fileManager: mockFM)
        let latch = Latch()
        manager.scanShownWait = { await latch.wait() }

        let scan = Task {
            await manager.scanDirectories(left: Self.left, leftPath: "/L", right: Self.right, rightPath: "/R")
        }
        await awaitSignal(gate.entered, "the scan never reached its walk — nothing held it running")
        #expect(manager.isScanning, "premise: the scan is running")
        await waitUntil("the scan starts its wait") { latch.waited }
        #expect(!manager.isScanShown, "a scan was shown before its wait ended")

        latch.end()
        await waitUntil("a scan running past its wait is shown") { manager.isScanShown }

        gate.release.signal()
        await scan.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the scan was never actually held")
        #expect(!manager.isScanning)
        #expect(!manager.isScanShown, "the scan ended and is still shown as running")
    }

    /// **A scan that ends inside the wait is never shown — not during it, and not when the wait
    /// ends afterwards.** Every value `isScanShown` publishes is recorded, so a rise that came and
    /// went between two looks is still caught.
    @Test func aScanThatEndsInsideTheWaitIsNeverShown() async throws {
        let manager = FileSyncManager(fileManager: try disk())
        let latch = Latch()
        manager.scanShownWait = { await latch.wait() }
        var published: [Bool] = []
        let sink = manager.$isScanShown.sink { published.append($0) }
        defer { sink.cancel() }

        await manager.scanDirectories(left: Self.left, leftPath: "/L", right: Self.right, rightPath: "/R")
        await waitUntil("the scan finishes") { manager.hasScanned && !manager.isScanning }
        // Premise: the scan really ran, and its wait really began — otherwise "never shown" would be
        // a statement about a scan, or a wait, that never happened.
        #expect(manager.differences.map(\.relativePath) == ["only_left.txt"])
        #expect(latch.waited, "premise: the scan never started its wait")

        // Now end the wait, after the scan: a wait that outlives its scan must not light it up.
        latch.end()
        await waitUntil("the wait returns into its task") { latch.returned }

        #expect(!published.contains(true), "a scan that ended inside the wait was shown: \(published)")
        #expect(!manager.isScanShown)
    }
}
