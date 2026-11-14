import Foundation
import Testing
import Events
import EventsTestSupport

/// A `LogCapture` opened before a line still holds it after the shared 1,000-line buffer rolls
/// past it ("A log assertion reading a window that has already rolled" in `docs/flaky-tests.md`).
/// A quiet run never rolls, so these roll it on purpose.
///
/// Members of `EventsTests`, not their own suite: that suite clears and counts `Logger.shared`,
/// so in parallel the two would clear and count each other's lines. `.serialized` keeps them apart.
extension EventsTests {

    @MainActor
    @Test func aLineTheBufferHasEvictedIsStillCaptured() async {
        let probe = "log-capture probe \(UUID().uuidString)"
        let log = LogCapture()
        await Logger.shared.info(probe).value
        // More than the cap, in one flush: `flushPendingEntries` appends and then trims, and the
        // capture must take every line from the append before the trim publishes.
        let flood = (0..<1_500).map { "log-capture flood \($0) \(probe)" }
        for line in flood { Logger.shared.debug(line) }

        let captured = await log.entries.map(\.message)
        // The buffer, read on purpose: this is the eviction the capture exists to survive.
        let stillBuffered = Logger.shared.entries.firstIndex { $0.message == probe } != nil
        #expect(!stillBuffered, "the buffer still holds the probe — nothing was evicted, so this proves nothing")
        #expect(captured.contains(probe), "the capture lost a line the buffer evicted")
        #expect(Set(flood).isSubset(of: captured), "the capture lost lines from a flush larger than the cap")
    }

    @MainActor
    @Test func aLineFromBeforeTheCaptureIsNotInIt() async {
        let before = "log-capture before \(UUID().uuidString)"
        await Logger.shared.info(before).value
        let log = LogCapture()
        let after = "log-capture after \(UUID().uuidString)"
        Logger.shared.info(after)

        let captured = await log.entries.map(\.message)
        #expect(captured.contains(after), "the capture missed a line written after it opened")
        #expect(!captured.contains(before), "the capture holds a line from before it opened")
    }
}
