import Foundation
import Observation

/// Runs a menu's cloud reads (Download's `lstat`, Keep Downloaded's `getxattr`s, the File Provider
/// domain of `~/Desktop` and `~/Documents`) off the main thread, and waits for them only so long.
///
/// Those reads land inside a File Provider domain, and a wedged provider can hold them for seconds
/// (the reason the Details sidebar reads off main, `DetailsMetadataCache`). The row menu asks them
/// on the main thread while it is built, at a row's first right-click and whenever that row renders
/// again, so on a wedged provider an unbounded read would freeze the app.
///
/// A bounded wait rather than a memo, so the menu shows the answer as of the moment it is built. A
/// healthy read answers in microseconds and the wait never shows; a read that outlives `deadline`
/// builds the menu without the items that needed it, which is the truth: nothing could be found
/// out.
///
/// One stuck read stops every later one: it is left to finish, and until it does `run` answers nil
/// at once, so a wedge costs one `deadline` and one thread, not one of each per menu. Every
/// provider shares `fileproviderd`, so a wedge is rarely in one provider alone, and a local row
/// never needs a read. When the stuck read returns, `recoveries` moves and every menu built without
/// its answer is built again.
///
/// Its own queue, never the cooperative pool (`DetailsMetadataCache.ioQueue` has the reason).
/// Serial, because at most one read is ever outstanding. User-interactive, because the main thread
/// is what waits on it.
@MainActor @Observable
final class BoundedCloudRead {
    /// The one every menu shares. 200 ms, under the 250 ms at which macOS counts a hang.
    static let shared = BoundedCloudRead(deadline: .milliseconds(200))

    @ObservationIgnored private let deadline: DispatchTimeInterval
    @ObservationIgnored private let queue = DispatchQueue(label: "com.synccloud.menu-cloud-reads", qos: .userInteractive)
    @ObservationIgnored private var isStuck = false

    /// Bumped each time a stuck read returns. A menu built without an answer reads it, so it is
    /// rebuilt then rather than at its row's next render.
    private(set) var recoveries = 0

    init(deadline: DispatchTimeInterval) {
        self.deadline = deadline
    }

    /// `read`'s answer, or nil when it did not come back within the deadline or an earlier read is
    /// still stuck.
    func run<T: Sendable>(_ read: @escaping @Sendable () -> T) -> T? {
        guard !isStuck else {
            _ = recoveries
            return nil
        }
        let slot = Slot<T>()
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            if slot.finish(read()) {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.recover() } }
            }
            done.signal()
        }
        if done.wait(timeout: .now() + deadline) == .success { return slot.value }
        // Timed out, unless the read landed between the wait giving up and here.
        if let value = slot.abandon() { return value }
        isStuck = true
        _ = recoveries
        return nil
    }

    private func recover() {
        isStuck = false
        recoveries += 1
    }

    /// One read's hand-off from the queue, and whether the caller stopped waiting for it.
    private final class Slot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: T?
        private var abandoned = false

        var value: T? { lock.withLock { answer } }

        /// Stores the answer; true when nobody is waiting for it any more.
        func finish(_ value: T) -> Bool {
            lock.withLock {
                answer = value
                return abandoned
            }
        }

        /// Gives up on the read: nil, or its answer if it came in after all.
        func abandon() -> T? {
            lock.withLock {
                if answer == nil { abandoned = true }
                return answer
            }
        }
    }
}
