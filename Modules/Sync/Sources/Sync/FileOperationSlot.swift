import Foundation

/// A position already claimed in `FileSyncManager`'s serial file-operation queue, handed out by
/// `claimFileOperationSlot()` and spent by exactly one `enqueueFileOperation(slot:)`.
///
/// The queue's order used to be a property of WHERE `enqueueFileOperation` was called from: it
/// claims its position without a suspension in front of it, so callers already on the main actor
/// claim in call order — and callers that spawn a `Task` first additionally depend on
/// equal-priority main-actor jobs being FIFO. A slot makes the order a property of when the CALLER
/// decided, in its own synchronous stretch, which is checkable at the site and cannot be undone by
/// how the operation is eventually dispatched.
///
/// Reference type on purpose: the slot's `deinit` releases the position, so a claim that is
/// dropped without ever being enqueued (an early `return`, a thrown error, a future refactor) lets
/// the queue move on instead of wedging every operation behind it forever.
public final class FileOperationSlot: @unchecked Sendable {

    /// The operation this one queues behind — the chain as it stood at claim time.
    let predecessor: Task<Void, Swift.Error>

    /// Signalled when this slot's operation has finished (body plus its main-actor cleanup), which
    /// is what the NEXT claim is waiting on.
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

/// A one-shot "it's done" signal that any number of tasks can await, and that can be signalled
/// from any isolation — including a `deinit`, which is why this is a lock around continuations
/// rather than anything actor-isolated.
///
/// `finish()` after the fact is a no-op, and `wait()` after `finish()` returns immediately, so
/// neither side has to be first.
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
