import Foundation
import Testing
import Events
@testable import Sync

/// **"Undo Last Run" pairs a run with the group that run registered, and reverses only the run it
/// showed** (FR26).
///
/// Two ways it described one run and reversed another:
///
/// 1. A run armed its pairing only after awaiting its identity walks, so the undo name it read was
///    whatever topped the stack at the end of that tail. A rename made during the tail was paired
///    with the run's records: the preview listed the run, and Undo reversed the rename.
/// 2. The confirmation is a modal alert, and runs keep finishing behind it. A second "Sync run"
///    re-armed the pairing under the same name, so Undo reversed a run the alert never listed.
@MainActor
@Suite struct SyncRunPairingTimingTests {

    private final class Marker { var undone = false }

    private func isolatedManager(fileManager: FileManaging = FileManager.default) -> FileSyncManager {
        let manager = FileSyncManager(fileManager: fileManager)
        manager.syncHistoryStore = makeTempHistoryStore(prefix: "SyncRunPairingTiming")
        let um = UndoManager()
        um.groupsByEvent = false            // the bulk run groups explicitly; so do the steps here
        manager.undoManager = um
        return manager
    }

    private func registerStep(_ manager: FileSyncManager, name: String, marker: Marker) {
        let um = manager.undoManager!
        um.beginUndoGrouping()
        um.setActionName(name)
        um.registerUndo(withTarget: marker) { $0.undone = true }
        um.endUndoGrouping()
    }

    /// Parks the identity walk — the first stat of the landed copy made off the main thread — so
    /// the run's tail can be held open while the test acts on the undo stack.
    private final class WalkGateDisk: FileManaging, @unchecked Sendable {
        let inner: MockFileManager
        let gatedPath: String
        let gate: ParkGate
        private let lock = NSLock()
        private var fired = false

        init(inner: MockFileManager, gatedPath: String, gate: ParkGate) {
            self.inner = inner
            self.gatedPath = gatedPath
            self.gate = gate
        }

        func attributesOfItem(atPath p: String) throws -> [FileAttributeKey: Any] {
            if p == gatedPath, !Thread.isMainThread, inner.fileExists(atPath: p) {
                lock.lock(); let first = !fired; fired = true; lock.unlock()
                if first { gate.park(timeout: 30) }
            }
            return try inner.attributesOfItem(atPath: p)
        }
        func fileExists(atPath p: String) -> Bool { inner.fileExists(atPath: p) }
        func fileExists(atPath p: String, isDirectory d: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            inner.fileExists(atPath: p, isDirectory: d)
        }
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
        func enumerator(at u: URL, includingPropertiesForKeys k: [URLResourceKey]?, options m: FileManager.DirectoryEnumerationOptions,
                        errorHandler h: ((URL, Error) -> Bool)?) -> FileManager.DirectoryEnumerator? {
            inner.enumerator(at: u, includingPropertiesForKeys: k, options: m, errorHandler: h)
        }
    }

    /// (1) A rename registered while the run's identity walk is still out is NOT paired with the
    /// run: the pairing names the run's own group, the rename now tops the stack, and "Undo Last
    /// Run" refuses rather than reversing the rename under the run's description.
    @Test(.parksAThread) func aStepRegisteredDuringTheRunsTailIsNotPairedWithTheRun() async throws {
        let root = "/pairing-tail"
        let mock = MockFileManager()
        try mock.createDirectory(at: URL(fileURLWithPath: "\(root)/L"), withIntermediateDirectories: true)
        try mock.createDirectory(at: URL(fileURLWithPath: "\(root)/R"), withIntermediateDirectories: true)
        mock.virtualDisk["\(root)/L/notes.txt"] = MockFileManager.FileStub(
            isDirectory: false, attributes: [.size: 10, .modificationDate: Date(timeIntervalSince1970: 1_000)], contents: nil)
        let gate = ParkGate()
        let disk = WalkGateDisk(inner: mock, gatedPath: "\(root)/R/notes.txt", gate: gate)
        let manager = isolatedManager(fileManager: disk)
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        defer { gate.release.signal() }
        let diff = FileDifference(relativePath: "notes.txt", leftItemPath: "\(root)/L/notes.txt",
                                  rightItemPath: "\(root)/R/notes.txt", type: .missingOnRight,
                                  action: .copyToRight, description: "Missing")
        manager.rawDifferences = [diff]
        manager.differences = [diff]

        let run = Task { await manager.syncAll(direction: .copyToRight, confirmed: true) }
        await awaitSignal(gate.entered, "the run's identity walk never reached the landed copy")
        await waitUntil("the run's group is registered") { manager.undoManager?.undoActionName == "Sync run" }

        // The user renames something while the walk is still out.
        let rename = Marker()
        registerStep(manager, name: "Rename notes.txt", marker: rename)
        gate.release.signal()
        await run.value
        try #require(!gate.releasedByTimeout, "the gate timed out: the tail was never held open")
        try #require(manager.undoManager?.undoActionName == "Rename notes.txt")

        #expect(manager.lastSyncRunUndoPreview == nil,
                "the run's records were paired with “\(manager.lastSyncRunUndoPreview?.actionName ?? "")”, the step on top — Undo Last Run would list the run and reverse that")
        #expect(manager.undoLastSyncRunAskingFirst(confirm: { _ in true }) != nil,
                "Undo Last Run acted with a rename on top")
        #expect(!rename.undone, "Undo Last Run reversed the rename")
    }

    /// (2) A second same-named run arming while the confirmation for the first is up: the second
    /// run arms while `confirm` — the modal — is up, and the yes undoes nothing and comes back as
    /// the refusal.
    @Test func theHistoryWindowsConfirmationRefusesARunThatFinishedBehindIt() {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let first = Marker(), second = Marker()
        registerStep(manager, name: "Sync run", marker: first)
        manager.recordSyncHistory([SyncHistoryRecord(runId: UUID(), action: .copy, sourcePath: "/a/one.txt", destPath: "/b/one.txt")])

        let refusal = manager.undoLastSyncRunAskingFirst { _ in
            registerStep(manager, name: "Sync run", marker: second)
            manager.recordSyncHistory([SyncHistoryRecord(runId: UUID(), action: .copy, sourcePath: "/a/two.txt", destPath: "/b/two.txt")])
            return true
        }

        #expect(!second.undone, "the confirmation for the first run reversed the second")
        #expect(!first.undone)
        #expect(refusal?.hasPrefix("Another sync run finished while you were deciding") == true,
                "got \(String(describing: refusal))")
    }

    /// The control: confirming the run that IS on top reverses it.
    @Test func aConfirmationForTheRunOnTopUndoesIt() throws {
        let manager = isolatedManager()
        defer { removeHistoryStoreFiles(manager.syncHistoryStore) }
        let marker = Marker()
        registerStep(manager, name: "Sync run", marker: marker)
        manager.recordSyncHistory([SyncHistoryRecord(runId: UUID(), action: .copy, sourcePath: "/a/one.txt", destPath: "/b/one.txt")])
        try #require(manager.lastSyncRunUndoPreview != nil)

        #expect(manager.undoLastSyncRunAskingFirst(confirm: { _ in true }) == nil)
        #expect(marker.undone)
    }
}
