import Foundation
import Testing
@testable import FileExplorer

/// The rules of `BoundedCloudRead`, on readers of the tests' own — a stuck read on the shared one
/// would stop every other suite's menus reading until it returned.
@MainActor
@Suite struct BoundedCloudReadTests {

    @Test func aReadThatAnswersInTimeIsAnswered() {
        let reads = BoundedCloudRead(deadline: .seconds(30))
        #expect(reads.run { 42 } == 42)
        #expect(reads.run { "again" } == "again")
    }

    /// A read that outlives the deadline answers nil, and no read starts until it returns: the
    /// second one below must never run, even once the first is let go — a reader that only queued it
    /// behind the stuck one would run it then.
    @Test func aStuckReadStopsLaterReadsUntilItReturns() async {
        let reads = BoundedCloudRead(deadline: .milliseconds(50))
        let release = DispatchSemaphore(value: 0)
        let ran = Flag()
        #expect(reads.run { release.wait(); return 1 } == nil)
        #expect(reads.run { ran.set(); return 2 } == nil)

        release.signal()
        #expect(await waitUntil { reads.recoveries == 1 }, "the stuck read never reported back")
        #expect(!ran.isSet, "a read was started while another was stuck")
        #expect(reads.run { 3 } == 3, "reads resume once the stuck one returns")
        #expect(reads.recoveries == 1)
    }

    /// The wait is what is bounded, not the read: a slow read that comes back in time is answered.
    @Test func aSlowReadInsideTheDeadlineIsAnswered() {
        let reads = BoundedCloudRead(deadline: .seconds(30))
        #expect(reads.run { usleep(100_000); return "slow" } == "slow")
        #expect(reads.recoveries == 0)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    private func waitUntil(_ timeout: Double = 15, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        return condition()
    }
}
