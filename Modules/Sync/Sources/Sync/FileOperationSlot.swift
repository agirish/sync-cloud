import Foundation

/// A position already claimed in `FileSyncManager`'s serial file-operation queue, handed out by
/// `claimFileOperationSlot()` and spent by exactly one `enqueueFileOperation(slot:)`.
///
/// The queue order is fixed when the caller claims, in its own synchronous stretch, so it can't
/// depend on how the operation is later dispatched (a spawned `Task` would rely on main-actor jobs
/// running FIFO). A class on purpose: `deinit` releases the position, so a claim dropped without
/// being enqueued (an early `return`, a thrown error) can't wedge every operation behind it.
public final class FileOperationSlot: @unchecked Sendable {

    /// The operation this one queues behind — the chain as it stood at claim time.
    let predecessor: Task<Void, Swift.Error>

    /// Signalled when this slot's operation has finished (body plus its main-actor cleanup), which
    /// is what the next claim waits on.
    let released = OneShotSignal()

    init(predecessor: Task<Void, Swift.Error>) {
        self.predecessor = predecessor
    }

    /// Hands the position on. Idempotent, so the explicit release at the end of an operation and
    /// the `deinit` below cannot double-count.
    func release() {
        released.finish()
    }

    deinit {
        released.finish()
    }
}

/// A one-shot "it's done" signal any number of tasks can await. It can be signalled from any
/// isolation, including a `deinit`, so it is a lock around continuations, not an actor. A second
/// `finish()` is a no-op and `wait()` after `finish()` returns at once, so neither must be first.
final class OneShotSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let pending = waiters
        waiters = []
        lock.unlock()
        // Resumed outside the lock: a continuation can run its task inline, and that task may
        // reach code that signals or awaits another slot.
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
