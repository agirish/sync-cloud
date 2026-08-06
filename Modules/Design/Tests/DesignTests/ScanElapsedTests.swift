import Foundation
import Testing
@testable import Design

/// The Compare scan's running clock. Pure formatting, so every case is a fixture — and each one
/// here exists because it is a boundary the naive version got wrong.
@Suite struct ScanElapsedTests {

    /// A fixed instant rather than `Date()`: a clock read inside the test would make every
    /// expectation below a race against the second hand.
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func text(after seconds: TimeInterval) -> String {
        ScanElapsed.text(since: start, now: start.addingTimeInterval(seconds))
    }

    /// Seconds are counted, not bucketed. `ScanFreshness` floors the first half-minute to "0s ago"
    /// because it answers "is this fresh?"; this is read by someone waiting, and a clock that sits
    /// on 0 for thirty seconds looks stopped.
    @Test func testItCountsEverySecondBeforeTheFirstMinute() {
        #expect(text(after: 0) == "0s")
        #expect(text(after: 1) == "1s")
        #expect(text(after: 12) == "12s")
        #expect(text(after: 59) == "59s")
    }

    /// The seam. 60s is the first minute — not "60s", which would contradict the minute form that
    /// takes over one second later.
    @Test func testTheMinuteSeamDoesNotRepeatItself() {
        #expect(text(after: 60) == "1m 00s")
        #expect(text(after: 61) == "1m 01s")
        #expect(text(after: 119) == "1m 59s")
        #expect(text(after: 120) == "2m 00s")
    }

    /// Zero-padded so the string keeps ONE width for a whole minute. Unpadded, a `monospacedDigit`
    /// label still changes width at :09→:10 and back at :59→:00, nudging the layout twice a minute.
    @Test func testMinutesKeepAConstantWidth() {
        #expect(text(after: 63).count == text(after: 73).count)
        #expect(text(after: 660) == "11m 00s")
        #expect(text(after: 669) == "11m 09s")
    }

    /// No hour form: a Compare scan running for over an hour is a fault, and "73m 20s" says so
    /// where "1h 13m" reads like a job that expects to finish.
    @Test func testLongRunsStayInMinutes() {
        #expect(text(after: 4400) == "73m 20s")
    }

    /// A clock change mid-scan makes `now` earlier than `start`. Clamped, or the busy state counts
    /// up from a negative number.
    @Test func testAClockGoingBackwardsDoesNotProduceANegativeCount() {
        #expect(text(after: -5) == "0s")
    }
}
