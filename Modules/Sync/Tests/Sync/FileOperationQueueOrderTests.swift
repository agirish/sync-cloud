import Testing
import Foundation
@testable import Sync

/// **`enqueueFileOperation` is the serial queue every user file operation reaches the disk
/// through, and the order it runs them in is a safety property.**
///
/// The undo stack is where that matters most. A merge's ⌘Z pops two registrations in a
/// deliberate order — restore the redundant copies out of the Trash FIRST, delete the folded
/// files out of the keeper SECOND — so that a restore which fails (its location reoccupied, its
/// Trash backup gone) still leaves the folded files in the keeper rather than leaving the user
/// with neither copy. Both handlers run synchronously inside `undo()` and each spawns a `Task`
/// that calls `enqueueFileOperation`. Registration order and task-start order are both
/// deterministic; the queue was the link that was not.
///
/// It ran `await MainActor.run { … }` before claiming its slot in `fileOperationTask`. That
/// method is already `@MainActor`, so the block bought no isolation — but `MainActor.run` is a
/// *nonisolated* async function, so awaiting it from the main actor hops off to the generic
/// executor and back (SE-0338). Two callers that entered in a fixed order returned from that
/// round trip in whatever order the pool released them, and the later one could read
/// `fileOperationTask` before the earlier one had written it — chaining both operations on the
/// same predecessor, so they ran concurrently or in reverse.
///
/// This suite is the pin. It is a repeat-trial test on purpose: the defect was a race with a
/// measured rate of ~3% per pair on an IDLE machine (8/300 and 12/300 in two runs before the
/// fix), so a single pair would have passed 97% of the time and pinned nothing. 300 pairs put
/// the miss probability at roughly 0.97^300 ≈ 1e-4 while costing a few seconds.
@Suite struct FileOperationQueueOrderTests {

    /// Two operations requested in a fixed order, from two main-actor tasks spawned in that
    /// order — exactly the shape `undo()` produces — must RUN in that order, and must not
    /// overlap.
    ///
    /// Both halves are asserted because the same race produces both: the loser of the
    /// `fileOperationTask` read/write can either land ahead of the winner (inversion) or chain
    /// on the same predecessor as it (overlap, which is the serialization itself failing). The
    /// bodies mark entry and exit and take a `Task.yield()` in between — a queue turn, never a
    /// wall-clock window — so an overlap has somewhere to show itself.
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
            // the undo/redo handlers' own shape, copied deliberately: the counter has to move
            // before the task is scheduled, so the drain wait below is a real gate rather than
            // the quiescence it would otherwise be.
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
            // Counted separately from the log-shape reading above, and reported separately: one
            // trial can fail both readings (an interleaved log AND two bodies inside at once),
            // and adding them into one counter let the message claim more overlapping pairs than
            // there were pairs.
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

    /// **The order held across a deliberately INVERTED, off-the-main-actor enqueue.**
    ///
    /// The test above pins the order for callers that are already on the main actor, which every
    /// call site is today — but nothing in `enqueueFileOperation` enforces that, and the guarantee
    /// it rests on ("equal-priority main-actor jobs are FIFO", plus the caller's isolation) is not
    /// checkable at a call site. A `Task.detached { await manager.enqueueFileOperation { … } }`
    /// reinstates the hop, and with it the race, without a word.
    ///
    /// `claimFileOperationSlot()` is what makes the order structural: it is synchronous, so the
    /// caller fixes its position in its own main-actor turn, before the `Task` that runs the work
    /// exists. This test claims slot 1 then slot 2 and then enqueues them from detached tasks in
    /// the WRONG order — slot 2's body handed over first, from off the main actor, which is the
    /// worst case the old shape could produce — and the operations must still run 1 then 2.
    ///
    /// 300 trials for the same reason as above: the defect this shape exists to make impossible
    /// had a measured rate of ~3% per pair, and a single pair would have passed 97% of the time.
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

    /// The safety valve on the claim: a slot that is never enqueued must not wedge the queue
    /// behind it forever. Dropping the reference releases the position.
    ///
    /// Without this, `claimFileOperationSlot` would be a primitive whose misuse is unbounded —
    /// one early `return` between the claim and the enqueue and every later file operation in the
    /// session hangs, with no error and nothing to see.
    @MainActor
    @Test func aClaimedSlotThatIsNeverEnqueuedReleasesTheQueue() async throws {
        let manager = FileSyncManager(fileManager: FileManager.default)
        let ran = LockedBox<Bool>(false)

        // Claimed and immediately abandoned — the scope is what drops it.
        do {
            _ = manager.claimFileOperationSlot()
            manager.cancelPreCountedFileOperation()   // the claim counted; nothing will decrement it
        }

        // Spawned rather than awaited directly: the failure mode this pins is a queue that never
        // moves, and `await enqueueFileOperation` on a wedged queue HANGS. A bounded wait turns
        // that into a named failure in seconds instead of a stalled suite.
        let queued = Task { await manager.enqueueFileOperation { ran.withLock { $0 = true } } }
        await waitUntil("the operation queued after the abandoned claim runs") { ran.withLock { $0 } }
        #expect(ran.withLock { $0 } == true,
                "an operation queued after an abandoned claim never ran — the dropped slot is holding the queue")
        queued.cancel()
        await waitUntil("the queue drains") { manager.activeFileOperationsCount == 0 }
    }
}
