import Foundation
import Observation

/// Runs a menu's cloud reads — Download's `lstat`, Keep Downloaded's `getxattr`s, the File Provider
/// domain of `~/Desktop` and `~/Documents` — off the main thread, and waits for them only so long.
///
/// **Why.** Those reads land inside a File Provider domain, and a wedged provider holds them:
/// `xattr -l ~/Documents` blocked for more than 8 s on 2026-07-30, which is why the Details sidebar
/// reads off main (`DetailsMetadataCache`). The row menu asks them on the main thread while it is
/// being built — measured 2026-10-28 on macOS 27: not with every row render, but at a row's first
/// right-click, before the menu appears, and from then on whenever that row renders again. On a
/// wedged provider a right-click froze the app.
///
/// **A bounded wait rather than a memo**, so the menu shows exactly what it showed before: the
/// answer as of the moment it is built, read fresh. A healthy read answers in microseconds and the
/// wait never shows. Only a read that outlives `deadline` changes anything: the menu is built
/// without the items that needed it, which is the truth — nothing could be found out — where the
/// app used to hang.
///
/// **One stuck read stops every later one.** It is left to finish on its own, and until it does,
/// `run` answers nil at once without starting another, so a wedge costs one `deadline` and one
/// thread rather than one of each per menu. Every provider shares `fileproviderd`, so a wedge in one
/// is rarely a wedge in one alone, and a local row never needs a read to answer. When the stuck read
/// returns, `recoveries` moves, and every menu built without its answer is built again.
///
/// Its own queue, never the cooperative pool (`DetailsMetadataCache.ioQueue` has the reason). Serial,
/// because no more than one read is ever outstanding: the caller waits for each, and none starts
/// while one is stuck. User-interactive, because the main thread is what waits on it.
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
        // Timed out — unless the read landed between the wait giving up and here.
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
