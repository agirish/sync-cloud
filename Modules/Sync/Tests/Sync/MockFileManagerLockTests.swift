import Testing
import Foundation
@testable import Sync

/// The mock is shared between a test and the operation it starts, so the test's own reads and
/// writes of its collections must wait for an operation holding the lock, as the operation's do.
/// See "An unlocked read of the mock's disk lands inside the write the test is waiting for" in
/// `docs/flaky-tests.md`.
@Suite struct MockFileManagerLockTests {

    /// A real `moveItem` is held inside the lock, parked at its child's copy with the destination
    /// folder written and the source not yet removed: the half-done state an unlocked read could
    /// see. Every locked collection is read and written from threads of its own meanwhile, and the
    /// disk is snapshotted once. Each access must wait out the whole move, and the snapshot must
    /// show it finished.
    ///
    /// One park for all of them, because a test that builds a `ParkGate` holds one of the process's
    /// few park reservations (`parkThreadBudget`; `ParkBudgetTests` requires the trait), and every
    /// other gated test queues behind it. The park is on a dedicated `Thread`, not the pool.
    ///
    /// Not pinned: that `moveItem` holds the lock across its copy and its remove. Dropping that hold
    /// survives, because the move re-takes the lock for the remove before a waiting reader wakes.
    @Test(.parksAThread) func everyAccessWaitsOutAMoveHeldInsideTheLock() async throws {
        let fm = MockFileManager()
        fm.virtualDisk["/src/project"] = MockFileManager.FileStub(isDirectory: true, attributes: nil, contents: ["notes.txt"])
        fm.virtualDisk["/src/project/notes.txt"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
        let gate = ParkGate()
        fm.beforeCopyItem = { source in
            guard source == "/src/project/notes.txt" else { return }
            fm.beforeCopyItem = nil
            gate.park(timeout: 60)
        }
        Thread {
            try? fm.moveItem(at: URL(fileURLWithPath: "/src/project"), to: URL(fileURLWithPath: "/dst/project"))
        }.start()
        await awaitSignal(gate.entered, "the move never reached the child's copy")
        try #require(gate.didPark, "the move never parked, so nothing holds the lock")

        let released = LockedBox(false)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let early = LockedBox<[String]>([])
        let done = LockedBox(0)
        let snapshot = LockedBox<Set<String>?>(nil)
        func onItsOwnThread(_ name: String, _ access: @escaping @Sendable () -> Void) {
            DispatchQueue.global().async {
                started.signal()
                access()
                if !released.withLock({ $0 }) { early.withLock { $0.append(name) } }
                done.withLock { $0 += 1 }
                finished.signal()
            }
        }
        for access in SharedAccess.allCases {
            onItsOwnThread(access.rawValue) { access.perform(on: fm) }
        }
        onItsOwnThread("snapshot") {
            // One read, so one snapshot, of the move's paths only: `writeVirtualDisk` may have
            // added `/elsewhere` by then.
            let keys = Set(fm.virtualDisk.keys.filter { $0.hasPrefix("/src/") || $0.hasPrefix("/dst/") })
            snapshot.withLock { $0 = keys }
        }
        let accesses = SharedAccess.allCases.count + 1
        for _ in 0..<accesses { await awaitSignal(started, "an access never started") }

        // Gives an unlocked access the time it would need (microseconds once its thread runs). A
        // locked access can't finish here however long this waits, so for a correct mock the
        // length decides nothing.
        for _ in 0..<10 where done.withLock({ $0 }) < accesses {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        released.withLock { $0 = true }
        gate.release.signal()
        for _ in 0..<accesses { await awaitSignal(finished, "an access never finished once the move was released") }

        try #require(!gate.releasedByTimeout, "the park expired on its own, so nothing here was held")
        #expect(early.withLock { $0 }.isEmpty,
                "finished while a move held the mock's lock: \(early.withLock { $0 }.sorted())")
        #expect(snapshot.withLock { $0 } == ["/dst/project", "/dst/project/notes.txt"],
                "the snapshot saw the move half done or not at all: \(snapshot.withLock { $0 }?.sorted() ?? [])")
    }

    /// One access to each locked collection, a read and a write. Writes touch `/elsewhere` only, so
    /// none of them changes what the parked move does once it resumes.
    enum SharedAccess: String, CaseIterable, Sendable {
        case readVirtualDisk, writeVirtualDisk
        case readDanglingSymlinks, writeDanglingSymlinks
        case readUnlistableDirectories, writeUnlistableDirectories
        case readFailMoveToPathsOnce, writeFailMoveToPathsOnce
        case readMovedInto, writeMovedInto
        case readTrashedPaths, writeTrashedPaths
        case readFailRemovePathsOnce, writeFailRemovePathsOnce
        case readAttemptedRemovePaths, writeAttemptedRemovePaths

        func perform(on fm: MockFileManager) {
            switch self {
            case .readVirtualDisk: _ = fm.virtualDisk["/elsewhere"]
            case .writeVirtualDisk:
                fm.virtualDisk["/elsewhere"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            case .readDanglingSymlinks: _ = fm.danglingSymlinks.contains("/elsewhere")
            case .writeDanglingSymlinks: fm.danglingSymlinks.insert("/elsewhere")
            case .readUnlistableDirectories: _ = fm.unlistableDirectories.contains("/elsewhere")
            case .writeUnlistableDirectories: fm.unlistableDirectories.insert("/elsewhere")
            case .readFailMoveToPathsOnce: _ = fm.failMoveToPathsOnce.contains("/elsewhere")
            case .writeFailMoveToPathsOnce: fm.failMoveToPathsOnce.insert("/elsewhere")
            case .readMovedInto: _ = fm.movedInto.contains("/elsewhere")
            case .writeMovedInto: fm.movedInto.insert("/elsewhere")
            case .readTrashedPaths: _ = fm.trashedPaths.count
            case .writeTrashedPaths: fm.trashedPaths.append("/elsewhere")
            case .readFailRemovePathsOnce: _ = fm.failRemovePathsOnce.contains("/elsewhere")
            case .writeFailRemovePathsOnce: fm.failRemovePathsOnce.insert("/elsewhere")
            case .readAttemptedRemovePaths: _ = fm.attemptedRemovePaths.count
            case .writeAttemptedRemovePaths: fm.attemptedRemovePaths.append("/elsewhere")
            }
        }
    }
}
