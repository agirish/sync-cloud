import Testing
import Foundation
@testable import Sync

/// Closes coverage gap A from the data-corruption review: cancelling a copy/move/delete mid-run
/// had NO test, even though "cancel copy / cancel move" is a core flow. These pin the contract of
/// the `progress.isCancelled` check in `transferItems`/`deleteItems`: cancellation is only observed
/// BETWEEN items, so the item already in flight completes ATOMICALLY (no half-written file, no
/// stray `.tmp_`), while every not-yet-started item is skipped.
@Suite struct CancellationTests {

    /// Blocks the FIRST call to one chosen primitive on a gate, signalling `entered` when that call
    /// is reached — so a test can hold exactly one item in flight, cancel the operation's Progress,
    /// then release it and observe that no further items were processed.
    private final class FirstOpGate: FileManaging, @unchecked Sendable {
        enum Op { case copy, move, trash }
        private let inner: MockFileManager
        private let gatedOp: Op
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var gated = false

        init(inner: MockFileManager, gate op: Op) { self.inner = inner; gatedOp = op }

        private func gateIfFirst(_ op: Op) {
            guard op == gatedOp else { return }
            lock.lock(); let first = !gated; if first { gated = true }; lock.unlock()
            guard first else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10) // timeout so a mis-wired test fails instead of hanging
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

    /// Awaits the gate being entered (first item in flight) off the main actor, so the main-actor
    /// test can then cancel `activeProgress` while that item is parked.
    private func awaitEntered(_ gate: FirstOpGate) async {
        // The blocking semaphore wait must run off an async context (GCD queue), then resume.
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                _ = gate.entered.wait(timeout: .now() + 10)
                cont.resume()
            }
        }
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
    @Test func testCancelDuringCopyCompletesInFlightItemAndSkipsRest() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seedFiles(inner, in: "/src", ["a.txt", "b.txt", "c.txt"])
        let fm = FirstOpGate(inner: inner, gate: .copy)
        let m = manager()

        let nodes = ["a.txt", "b.txt", "c.txt"].map { FileNode(id: "/src/\($0)", name: $0, isDirectory: false) }
        let op = Task { await m.copyItems(nodes: nodes, toPath: "/dst", fileManager: fm) }

        await awaitEntered(fm)          // first copy is parked in flight
        m.activeProgress?.cancel()      // cancel while it is parked
        fm.release.signal()             // let the in-flight copy finish
        let transferred = await op.value

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
    @Test func testCancelDuringMoveCompletesInFlightItemAndSkipsRest() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        try inner.createDirectory(at: URL(fileURLWithPath: "/dst"), withIntermediateDirectories: true)
        seedFiles(inner, in: "/src", ["a.txt", "b.txt", "c.txt"])
        let fm = FirstOpGate(inner: inner, gate: .move)
        let m = manager()

        let nodes = ["a.txt", "b.txt", "c.txt"].map { FileNode(id: "/src/\($0)", name: $0, isDirectory: false) }
        let op = Task { await m.moveItems(nodes: nodes, toPath: "/dst", fileManager: fm) }

        await awaitEntered(fm)
        m.activeProgress?.cancel()
        fm.release.signal()
        let transferred = await op.value

        // One item moved (present at dest, gone from source); the remaining two stayed put.
        #expect(transferred.count == 1)
        #expect(dstFileCount(inner, "/dst") == 1)
        #expect(dstFileCount(inner, "/src") == 2)
        #expect(inner.virtualDisk.keys.contains { $0.contains(".tmp_") } == false)
    }

    // MARK: Cancel delete

    @MainActor
    @Test func testCancelDuringDeleteTrashesInFlightItemAndSkipsRest() async throws {
        let inner = MockFileManager()
        try inner.createDirectory(at: URL(fileURLWithPath: "/src"), withIntermediateDirectories: true)
        seedFiles(inner, in: "/src", ["a.txt", "b.txt", "c.txt"])
        let fm = FirstOpGate(inner: inner, gate: .trash)
        let m = manager()

        let op = Task { await m.deleteItems(at: ["/src/a.txt", "/src/b.txt", "/src/c.txt"], fileManager: fm) }

        await awaitEntered(fm)
        m.activeProgress?.cancel()
        fm.release.signal()
        _ = await op.value

        // Exactly one item was trashed; the other two remain on disk (cancel observed before them).
        #expect(inner.trashedPaths.count == 1)
        #expect(dstFileCount(inner, "/src") == 2)
    }
}
