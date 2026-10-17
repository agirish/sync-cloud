import Foundation
import os
import Sync

/// Holds `PDFKitSerialAccess`'s one lane until released, so a test can see what a reader does while
/// its parse is queued behind someone else's. Shared by the column preview's tests and File ▸
/// Print's.
///
/// The hold is queued like any parse, so `waitUntilHeld` returns only once it is really in the
/// lane — a parse that got there first runs to completion before it. **The wait polls rather
/// than blocking on a semaphore**: these tests are main-actor, and a main thread parked behind
/// another hold is a main thread that hold's owner needs in order to release it.
final class LaneHold: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let held = OSAllocatedUnfairLock(initialState: false)
    private let released = OSAllocatedUnfairLock(initialState: false)

    init() {
        Task.detached { [gate, held] in
            await PDFKitSerialAccess.perform { held.withLock { $0 = true }; gate.wait() }
        }
    }

    /// **Ten minutes, not thirty seconds.** The hold queues like any parse, so how long it waits is
    /// how busy the lane is — in a full package run, with other suites holding it in turn, that
    /// was measured past 30 s (CI, 2026-10-17), and the hold failed as if it were broken. A lane that
    /// never comes free still fails, after a wait no healthy run reaches. It polls with the lane
    /// NOT held, so its main-actor sleeps cost nobody else anything.
    static let patience: TimeInterval = 600

    func waitUntilHeld() async -> Bool {
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            if held.withLock({ $0 }) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    /// Idempotent, so a `defer` can always call it without stealing a later hold's signal.
    func release() {
        let first = released.withLock { done in defer { done = true }; return !done }
        if first { gate.signal() }
    }
}
