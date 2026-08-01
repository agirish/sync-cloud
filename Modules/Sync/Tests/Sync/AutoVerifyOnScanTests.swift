import Testing
import Foundation
@testable import Sync

/// Pins the scan-time checksum pass (`autoVerifySameSizePairs`): identical same-size pairs are
/// hidden via `verifiedSameDifferenceIds`, differing pairs stay, and stale or unsafe passes
/// (superseded scan, operations in flight) publish nothing. Real temp files — the checksummer
/// reads from the real filesystem.
@Suite struct AutoVerifyOnScanTests {

    /// Parks the FIRST stat the checksummer makes on a semaphore, signalling `entered` — so a
    /// test can hold the scan-time pass mid-hash while it runs a file operation, then release
    /// the hash and observe the batch being discarded. Everything else passes straight through
    /// to the real `FileManager` the fixture's temp files live on.
    private final class FirstStatGate: FileManaging, @unchecked Sendable {
        private let inner: FileManager
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var gated = false

        init(inner: FileManager) { self.inner = inner }

        private func gateIfFirst() {
            lock.lock(); let first = !gated; if first { gated = true }; lock.unlock()
            guard first else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10) // timeout so a mis-wired test fails instead of hanging
        }

        func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
        func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            gateIfFirst()
            return inner.fileExists(atPath: p, isDirectory: d)
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
        func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions, errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        }
    }

    @MainActor
    private func makeFixture(fileManager: FileManaging = FileManager.default) throws -> (manager: FileSyncManager, identical: FileDifference, differed: FileDifference, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AutoVerify-\(UUID().uuidString)")
        let left = base.appendingPathComponent("left")
        let right = base.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)

        try Data("identical".utf8).write(to: left.appendingPathComponent("same.txt"))
        try Data("identical".utf8).write(to: right.appendingPathComponent("same.txt"))
        try Data("aaaa".utf8).write(to: left.appendingPathComponent("diff.txt"))
        try Data("bbbb".utf8).write(to: right.appendingPathComponent("diff.txt"))

        func dateDiff(_ name: String, size: Int) -> FileDifference {
            FileDifference(
                relativePath: name,
                leftItemPath: left.appendingPathComponent(name).path,
                rightItemPath: right.appendingPathComponent(name).path,
                type: .differentDates,
                action: .copyToRight,
                description: "Different dates",
                leftFileSize: size,
                rightFileSize: size
            )
        }
        let identical = dateDiff("same.txt", size: 9)
        let differed = dateDiff("diff.txt", size: 4)

        let manager = FileSyncManager(fileManager: fileManager)
        manager.autoVerifySameSizeDuringScan = true
        manager.rawDifferences = [identical, differed]
        manager.differences = [identical, differed]
        return (manager, identical, differed, { try? fm.removeItem(at: base) })
    }

    @MainActor
    @Test func testIdenticalPairsAreHiddenAndDifferingPairsStay() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)

        #expect(manager.verifiedSameDifferenceIds == [fixture.identical.id])
        #expect(manager.differences.map(\.id) == [fixture.differed.id])
        // Silent by design: no progress UI, no copy-identical offer, no banner.
        #expect(manager.verifyAllProgress == nil)
        #expect(manager.verifiedIdenticalForCopy == nil)
        #expect(manager.banner == nil)
    }

    @MainActor
    @Test func testSupersededScanPublishesNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        let staleGeneration = manager.scanRequestGeneration
        manager.scanRequestGeneration += 1
        await manager.autoVerifySameSizePairs(scanGeneration: staleGeneration)

        #expect(manager.verifiedSameDifferenceIds.isEmpty)
        #expect(manager.differences.count == 2)
    }

    @MainActor
    @Test func testSkipsWhileOperationsAreInFlight() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        manager.activeFileOperationsCount = 1
        await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
    }

    /// A file operation that starts — and even FINISHES — while the pass is hashing must void
    /// the whole batch: the pre-operation "identical" verdicts describe bytes the operation may
    /// have rewritten, and if the hash drains before the operation's rescan bumps
    /// `scanRequestGeneration`, folding them into `verifiedSameDifferenceIds` would silently
    /// show a real difference as in-sync until the next scan. The entry guard can't see this
    /// (`activeFileOperationsCount` is back to 0 by commit time) — only the operations epoch can.
    @MainActor
    @Test func testOperationRunningMidHashDiscardsTheBatch() async throws {
        let gate = FirstStatGate(inner: FileManager.default)
        let fixture = try makeFixture(fileManager: gate)
        defer { fixture.cleanup() }
        let manager = fixture.manager

        // Start the pass; its first checksum stat parks on the gate.
        let pass = Task { @MainActor in
            await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        }
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                _ = gate.entered.wait(timeout: .now() + 10)
                cont.resume()
            }
        }

        // A complete file operation runs while the hash is parked: count goes 1 → 0, the epoch
        // moves, and — the exact race — `scanRequestGeneration` has NOT been bumped yet.
        let generationBefore = manager.scanRequestGeneration
        await manager.enqueueFileOperation { }
        #expect(manager.activeFileOperationsCount == 0)
        #expect(manager.scanRequestGeneration == generationBefore)

        gate.release.signal()
        await pass.value

        #expect(manager.verifiedSameDifferenceIds.isEmpty, "verdicts hashed across a file operation must be discarded")
        #expect(manager.differences.count == 2)
    }

    @MainActor
    @Test func testDisabledToggleIsANoOp() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager

        manager.autoVerifySameSizeDuringScan = false
        await manager.autoVerifySameSizePairs(scanGeneration: manager.scanRequestGeneration)
        #expect(manager.verifiedSameDifferenceIds.isEmpty)
    }
}
