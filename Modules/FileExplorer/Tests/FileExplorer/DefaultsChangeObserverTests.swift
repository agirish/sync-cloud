import Testing
import Foundation
@testable import FileExplorer

@MainActor
struct DefaultsChangeObserverTests {
    @MainActor final class Rereads {
        var seen: [Int] = []
        var lateWriteLanded = false
    }

    /// **A burst of writes off the main thread queues one reread, and it reads the last write.**
    /// Each post used to schedule its own main-thread reread, so fifty writes in a row queued fifty
    /// per observer — and the signature store's decodes every saved signature. Main is held while
    /// they land, so every reread they schedule is queued before the first can run.
    ///
    /// A write that lands just after a reread has read must still be followed: the first reread
    /// makes one from another thread before it returns. The flag released only after the reread,
    /// or never, would swallow it and leave 50 on screen with 51 stored.
    @Test func aBurstOfWritesOffTheMainThreadQueuesOneRereadOfTheLastValue() async throws {
        let scratch = ScratchDefaults("DefaultsChangeObserverBurst")
        let rereads = Rereads()
        let change = observeDefaultsChanges(of: scratch) { [rereads] in
            rereads.seen.append(scratch.integer(forKey: "probe"))
            guard rereads.seen.count == 1 else { return }
            let landed = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                scratch.set(51, forKey: "probe")
                landed.signal()
            }
            rereads.lateWriteLanded = landed.wait(timeout: .now() + 5) == .success
        }
        defer { NotificationCenter.default.removeObserver(change) }

        let written = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            for value in 1...50 { scratch.set(value, forKey: "probe") }
            written.signal()
        }
        // The main thread, held, so nothing scheduled can run until the burst is over.
        #expect(holdingTheMainThread(until: written) == .success,
                "a background defaults write waited on the main thread")

        let end = Date().addingTimeInterval(15)
        while rereads.seen.count < 2, Date() < end { try? await Task.sleep(nanoseconds: 8_000_000) }
        // Anything else already queued runs before this sleep ends.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rereads.lateWriteLanded, "the write made during the reread waited on the main thread")
        #expect(rereads.seen == [50, 51],
                "\(rereads.seen.count) rereads, reading \(rereads.seen.prefix(3))…\(rereads.seen.suffix(2))")
    }

    /// Waits on the main thread without letting anything queued for it run — synchronous, since a
    /// semaphore wait is unavailable in an async test.
    private func holdingTheMainThread(until done: DispatchSemaphore) -> DispatchTimeoutResult {
        done.wait(timeout: .now() + 5)
    }
}
