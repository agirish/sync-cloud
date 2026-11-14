import Testing
import Foundation
@testable import Sync

/// `enqueueFileOperation` is the serial queue every user file operation reaches the disk through,
/// and the order it runs them in is a safety property.
///
/// A merge's ⌘Z pops two registrations in a deliberate order: restore the redundant copies out of
/// the Trash first, delete the folded files out of the keeper second, so a failed restore still
/// leaves the folded files in the keeper rather than neither copy. Both handlers run inside
/// `undo()` and each spawns a `Task` that calls `enqueueFileOperation`, so the queue must keep
/// that order. Any hop off the main actor before the slot is claimed in `fileOperationTask` (even
/// `await MainActor.run { … }`, a nonisolated async function, SE-0338) lets two callers return in
/// either order and chain on the same predecessor, running concurrently or in reverse.
///
/// Repeat trials on purpose: that race hit about 3% of pairs on an idle machine, so one pair
/// proves nothing; 300 put the miss chance near 1e-4 for a few seconds.
@Suite struct FileOperationQueueOrderTests {

    /// Two operations requested in order from two main-actor tasks spawned in that order (the shape
    /// `undo()` produces) must run in that order without overlapping; one race causes both. Each
    /// body yields between entry and exit (a queue turn, never a wall-clock window) so an overlap
    /// has somewhere to show.
    @MainActor
    @Test func theOperationRequestedSecondNeverRunsFirstOrAlongsideTheFirst() async throws {
        let manager = FileSyncManager(fileManager: FileManager.default)
        let trials = 300
        var inversions = 0
        var overlapping = 0     // the log interleaved
        var concurrent = 0      // two bodies inside at once
        var completed = 0

        for _ in 0..<trials {
            let log = LockedBox<[String]>([])
            let inside = LockedBox<Int>(0)
            let maxInside = LockedBox<Int>(0)

            @Sendable func body(_ tag: Int) async {
                log.withLock { $0.append("in\(tag)") }
                let n = inside.withLock { $0 += 1; return $0 }
                maxInside.withLock { $0 = max($0, n) }
                await Task.yield()
                inside.withLock { $0 -= 1 }
                log.withLock { $0.append("out\(tag)") }
            }

            // `preCountFileOperation()` then `Task { enqueueFileOperation(alreadyCounted:) }` is
            // the undo/redo handlers' own shape: the counter moves before the task is scheduled,
            // so the drain wait below is a real gate.
            manager.preCountFileOperation()
            Task { await manager.enqueueFileOperation(alreadyCounted: true) { await body(1) } }
            manager.preCountFileOperation()
            Task { await manager.enqueueFileOperation(alreadyCounted: true) { await body(2) } }

            await waitUntil("both queued operations run") { log.withLock { $0.count } == 4 }
            await waitUntil("the queue drains") { manager.activeFileOperationsCount == 0 }

            let seen = log.withLock { $0 }
            guard seen.count == 4 else { continue }
            completed += 1
            if seen != ["in1", "out1", "in2", "out2"] {
                if seen.first == "in2" { inversions += 1 } else { overlapping += 1 }
            }
            // Counted apart from the log reading: one trial can fail both, and a single counter
            // would report more overlapping pairs than there were pairs.
            if maxInside.withLock({ $0 }) > 1 { concurrent += 1 }
        }
        let overlaps = max(overlapping, concurrent)

        // The trials themselves are the evidence, so a run that did not actually take them says
        // so instead of reporting a clean zero.
        #expect(completed == trials,
                "only \(completed) of \(trials) pairs completed, so the counts below describe nothing")
        #expect(inversions == 0,
                "the operation requested SECOND ran FIRST in \(inversions) of \(completed) pairs — a merge's ⌘Z would delete the folded files out of the keeper before restoring the originals")
        #expect(overlaps == 0,
                "two operations queued back-to-back overlapped in \(overlaps) of \(completed) pairs (\(overlapping) by interleaved log, \(concurrent) by two bodies inside at once) — the queue is not serializing them")
    }

    /// The order holds across an inverted enqueue from off the main actor. Nothing in
    /// `enqueueFileOperation` enforces main-actor callers, and a `Task.detached` enqueue would
    /// bring the race back silently. `claimFileOperationSlot()` makes the order structural: it is
    /// synchronous, so the caller fixes its position in its own main-actor turn, before the work's
    /// `Task` exists. Slots 1 and 2 are enqueued from detached tasks in the wrong order and must
    /// still run 1 then 2. 300 trials for the same reason as above.
    @MainActor
    @Test func slotsRunInClaimOrderEvenWhenEnqueuedOutOfOrderFromOffTheMainActor() async throws {
        let manager = FileSyncManager(fileManager: FileManager.default)
        let trials = 300
        var outOfOrder = 0
        var completed = 0

        for _ in 0..<trials {
            let log = LockedBox<[String]>([])

            @Sendable func body(_ tag: Int) async {
                log.withLock { $0.append("in\(tag)") }
                await Task.yield()
                log.withLock { $0.append("out\(tag)") }
            }

            // Claimed on the main actor, in order, with nothing between them.
            let first = manager.claimFileOperationSlot()
            let second = manager.claimFileOperationSlot()

            // Handed over in the opposite order, each from a detached task: neither the enqueue
            // order nor the caller's isolation may be allowed to matter now.
            Task.detached { await manager.enqueueFileOperation(slot: second) { await body(2) } }
            Task.detached { await manager.enqueueFileOperation(slot: first) { await body(1) } }

            await waitUntil("both slotted operations run") { log.withLock { $0.count } == 4 }
            await waitUntil("the queue drains") { manager.activeFileOperationsCount == 0 }

            let seen = log.withLock { $0 }
            guard seen.count == 4 else { continue }
            completed += 1
            if seen != ["in1", "out1", "in2", "out2"] { outOfOrder += 1 }
        }

        #expect(completed == trials,
                "only \(completed) of \(trials) pairs completed, so the count below describes nothing")
        #expect(outOfOrder == 0,
                "the slot claimed FIRST did not run first in \(outOfOrder) of \(completed) pairs — the queue order is following the enqueue, not the claim, so a caller off the main actor can still reorder a merge's ⌘Z pair")
    }

    /// The safety valve on the claim: a slot that is never enqueued must not wedge the queue behind
    /// it. Dropping the reference releases the position; otherwise one early `return` between the
    /// claim and the enqueue would hang every later file operation, silently.
    @MainActor
    @Test func aClaimedSlotThatIsNeverEnqueuedReleasesTheQueue() async throws {
        let manager = FileSyncManager(fileManager: FileManager.default)
        let ran = LockedBox<Bool>(false)

        // Claimed and immediately abandoned — the scope is what drops it.
        do {
            _ = manager.claimFileOperationSlot()
            manager.cancelPreCountedFileOperation()   // the claim counted; nothing will decrement it
        }

        // Spawned, not awaited: on a wedged queue `await enqueueFileOperation` hangs, and a bounded
        // wait turns that into a named failure instead of a stalled suite.
        let queued = Task { await manager.enqueueFileOperation { ran.withLock { $0 = true } } }
        await waitUntil("the operation queued after the abandoned claim runs") { ran.withLock { $0 } }
        #expect(ran.withLock { $0 } == true,
                "an operation queued after an abandoned claim never ran — the dropped slot is holding the queue")
        queued.cancel()
        await waitUntil("the queue drains") { manager.activeFileOperationsCount == 0 }
    }
}
