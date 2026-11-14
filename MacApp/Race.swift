import Foundation

/// The first of a read, a timer and a stop to finish, handed to the one continuation waiting for it
/// — whether the stop comes before the continuation is there or after.
final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    /// What the first finisher gave, while no continuation was there to take it.
    private var early: T??
    private var done = false

    func install(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(returning: early)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// The first call's `value` is the answer; later calls don't run theirs. True for that first call.
    @discardableResult
    func finish(_ value: () -> T?) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        let answer = value()
        guard let continuation else { early = .some(answer); lock.unlock(); return true }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: answer)
        return true
    }
}
