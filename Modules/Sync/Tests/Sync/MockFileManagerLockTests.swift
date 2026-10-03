import Testing
import Foundation
@testable import Sync

/// The mock's disk is shared between a test and the operation the test starts, so the test's own
/// reads and writes of ``MockFileManager/virtualDisk`` must wait for an operation's lock just as
/// the operation's accesses do. An unlocked read crashed `testUndoRegisterTrashItems` on
/// 2026-10-02 — "An unlocked read of the mock's disk lands inside the write the test is waiting
/// for" in `docs/flaky-tests.md`.
@Suite struct MockFileManagerLockTests {

    /// A worker parks INSIDE a mock call, holding the lock — an operation caught mid-write. A read
    /// and a write from two other threads must not finish until the test lets it go.
    ///
    /// Each access records whether it finished before the release, so the verdict needs no
    /// timing: a locked access cannot finish earlier. The 50 polls only give an UNLOCKED access
    /// time to show itself — it would finish microseconds after its thread starts. The read and
    /// the write get a thread each, because one would block on the other's lock and hide it.
    @Test(.parksAThread) func theDiskWaitsForAnOperationHoldingTheLock() async throws {
        let fm = MockFileManager()
        fm.virtualDisk["/a"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)

        let gate = ParkGate()
        fm.onFileExists = { _ in
            fm.onFileExists = nil
            gate.park()
        }
        Thread { _ = fm.fileExists(atPath: "/a") }.start()
        await awaitSignal(gate.entered, "the worker never took the lock — there is no operation to wait for")

        let released = LockedBox(false)
        let readEarly = LockedBox<Bool?>(nil)
        let wroteEarly = LockedBox<Bool?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = fm.virtualDisk["/a"]
            readEarly.withLock { $0 = !released.withLock { $0 } }
            finished.signal()
        }
        DispatchQueue.global().async {
            fm.virtualDisk["/b"] = MockFileManager.FileStub(isDirectory: false, attributes: nil, contents: nil)
            wroteEarly.withLock { $0 = !released.withLock { $0 } }
            finished.signal()
        }

        var polls = 0
        while readEarly.withLock({ $0 }) == nil || wroteEarly.withLock({ $0 }) == nil, polls < 50 {
            polls += 1
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        released.withLock { $0 = true }
        gate.release.signal()
        await awaitSignal(finished, "the read never finished once the lock was released")
        await awaitSignal(finished, "the write never finished once the lock was released")

        try #require(!gate.releasedByTimeout, "the park expired on its own, so nothing here was held")
        #expect(readEarly.withLock { $0 } == false, "a read of the disk finished while an operation held the lock")
        #expect(wroteEarly.withLock { $0 } == false, "a write to the disk finished while an operation held the lock")
        #expect(fm.virtualDisk["/b"] != nil)
    }
}
