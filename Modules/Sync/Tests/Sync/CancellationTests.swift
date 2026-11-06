import Testing
import Foundation
@testable import Sync

/// Cancelling a copy, move or delete mid-run. Pins the `progress.isCancelled` check in
/// `transferItems` and `deleteItems`: the item in flight completes whole (no half-written file, no
/// stray `.tmp_`), and every item not yet started is skipped.
///
/// Against the mock, which copies whole. A real copy also watches Cancel inside the item and
/// abandons it in its staging file; the mock's `copyItem(at:to:observer:)` checks only before it
/// starts, so these cover the between-items half. `ObservedCopyTests` pins the mid-item half.
@Suite struct CancellationTests {

    /// Blocks the first call to one chosen primitive, signalling `entered`, so a test can hold one
    /// item in flight, cancel the Progress, release it, and see that no further items ran.
    private final class FirstOpGate: FileManaging, @unchecked Sendable {
        enum Op { case copy, move, trash }
        private let inner: MockFileManager
        private let gatedOp: Op
        /// The park, which records a timeout rather than discarding it: an item that resumed on its
        /// own would pass every assertion as if it had been held. Tests
        /// `try #require(!fm.releasedByTimeout)`.
        private let gate = ParkGate()
        private let lock = NSLock()
        private var gated = false

        init(inner: MockFileManager, gate op: Op) { self.inner = inner; gatedOp = op }

        var entered: DispatchSemaphore { gate.entered }
        var release: DispatchSemaphore { gate.release }
        var releasedByTimeout: Bool { gate.releasedByTimeout }

        private func gateIfFirst(_ op: Op) {
            guard op == gatedOp else { return }
            lock.lock(); let first = !gated; if first { gated = true }; lock.unlock()
            guard first else { return }
            gate.park()
        }

        func copyItem(at s: URL, to d: URL) throws { gateIfFirst(.copy); try inner.copyItem(at: s, to: d) }
        func moveItem(at s: URL, to d: URL) throws { gateIfFirst(.move); try inner.moveItem(at: s, to: d) }
        func trashItem(at u: URL, resultingItemURL o: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            gateIfFirst(.trash); try inner.trashItem(at: u, resultingItemURL: o)
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

    private func seedFiles(_ inner: MockFileManager, in dir: String, _ names: [String]) {
        for n in names { inner.virtualDisk["\(dir)/\(n)"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil) }
    }

    @MainActor
    private func manager() -> FileSyncManager {
        let m = FileSyncManager()
        m.collisionResolver = { _ in .replace }
        m.bulkCollisionResolver = { _ in (.replace, false) }
        m.permanentDeleteConfirmer = { _ in true }
        return m
    }

    private func dstFileCount(_ inner: MockFileManager, _ dir: String) -> Int {
        inner.virtualDisk.keys.filter { $0.hasPrefix(dir + "/") && $0.hasSuffix(".txt") }.count
    }

    // MARK: Cancel copy

    @MainActor
    @Test(.parksAThread) func testCancelDuringCopyCompletesInFlightItemAndSkipsRest() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seedFiles(inner, in: "/src", ["a.txt", "b.txt", "c.txt"])
        let fm = FirstOpGate(inner: inner, gate: .copy)
        let m = manager()

        let nodes = ["a.txt", "b.txt", "c.txt"].map { FileNode(id: "/src/\($0)", name: $0, isDirectory: false) }
        let op = Task { await m.copyItems(nodes: nodes, toPath: "/dst", fileManager: fm) }

        await awaitSignal(fm.entered, "the operation never reached the gated seam — nothing was in flight to cancel")   // first copy parked in flight
        m.activeProgress?.cancel()      // cancel while it is parked
        fm.release.signal()             // let the in-flight copy finish
        let transferred = await op.value
        try #require(!fm.releasedByTimeout, "the gate timed out: the item was never actually held in flight")

        // Exactly one item completed (the in-flight one), atomically; the other two never started.
        #expect(transferred.count == 1)
        #expect(dstFileCount(inner, "/dst") == 1)
        // No half-written staging file survives a cancel.
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
        // Source is untouched by a copy.
        #expect(dstFileCount(inner, "/src") == 3)
    }

    // MARK: Cancel move

    @MainActor
    @Test(.parksAThread) func testCancelDuringMoveCompletesInFlightItemAndSkipsRest() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seedFiles(inner, in: "/src", ["a.txt", "b.txt", "c.txt"])
        let fm = FirstOpGate(inner: inner, gate: .move)
        let m = manager()

        let nodes = ["a.txt", "b.txt", "c.txt"].map { FileNode(id: "/src/\($0)", name: $0, isDirectory: false) }
        let op = Task { await m.moveItems(nodes: nodes, toPath: "/dst", fileManager: fm) }

        await awaitSignal(fm.entered, "the operation never reached the gated seam — nothing was in flight to cancel")
        m.activeProgress?.cancel()
        fm.release.signal()
        let transferred = await op.value
        try #require(!fm.releasedByTimeout, "the gate timed out: the item was never actually held in flight")

        // One item moved (present at dest, gone from source); the remaining two stayed put.
        #expect(transferred.count == 1)
        #expect(dstFileCount(inner, "/dst") == 1)
        #expect(dstFileCount(inner, "/src") == 2)
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
    }

    // MARK: Cancel delete

    @MainActor
    @Test(.parksAThread) func testCancelDuringDeleteTrashesInFlightItemAndSkipsRest() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        seedFiles(inner, in: "/src", ["a.txt", "b.txt", "c.txt"])
        let fm = FirstOpGate(inner: inner, gate: .trash)
        let m = manager()

        let op = Task { await m.deleteItems(at: ["/src/a.txt", "/src/b.txt", "/src/c.txt"], fileManager: fm) }

        await awaitSignal(fm.entered, "the operation never reached the gated seam — nothing was in flight to cancel")
        m.activeProgress?.cancel()
        fm.release.signal()
        _ = await op.value
        try #require(!fm.releasedByTimeout, "the gate timed out: the item was never actually held in flight")

        // Exactly one item was trashed; the other two remain on disk (cancel observed before them).
        #expect(inner.trashedPaths.count == 1)
        #expect(dstFileCount(inner, "/src") == 2)
    }
}
