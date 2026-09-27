import Foundation
import Testing
import Events
import EventsTestSupport

/// What `LogCapture` promises every test that reads a log line through it.
///
/// The shared buffer keeps the newest 1,000 lines, so a line other suites have logged past is gone
/// from `Logger.shared.entries`, while a capture opened before it still holds it. That is the whole
/// reason the capture exists — "A log assertion reading a window that has already rolled" in
/// `docs/flaky-tests.md` — and none of the suites that use it can show it, because in a quiet run
/// nothing rolls. These roll the buffer on purpose.
///
/// **Members of `EventsTests`, not a suite of their own.** That suite empties `Logger.shared` with
/// `clearLogs()`, which also drops lines still queued for it, and then counts what the buffer holds
/// after one line. Measured 2026-09-27 as a suite of their own: 10 runs in 12 went red — these lost
/// a line cleared before it was published in 3, and `testLoggerInfo` counted the flood in 7 — and
/// with the clears taken out these failed in none of 12. Its `.serialized` keeps the two apart.
extension EventsTests {

    @MainActor
    @Test func aLineTheBufferHasEvictedIsStillCaptured() async {
        let probe = "log-capture probe \(UUID().uuidString)"
        let log = LogCapture()
        await Logger.shared.info(probe).value
        // More than the cap, in ONE flush: `flushPendingEntries` appends and then trims, and the
        // capture has to have taken every line from the append before the trim publishes.
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
