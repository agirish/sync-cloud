import Testing
import Foundation
@testable import Sync

/// ``Elapsed`` — the load records' duration, measured on a clock that stops for a sleeping Mac and
/// a clock that does not.
///
/// **The case that motivated the type cannot be produced by waiting**: `~/sync-cloud.log` holds
/// `shallow first paint 19 nodes (walk 8887.98 s)` for a listing that takes 84 ms warm, alongside
/// 1.4 s, 25 s, 190 s and 990 s for the same walk. No test can sleep a Mac for two hours, so the
/// formatting is a pure function of two measured spans and that is what is asserted here — with a
/// call-site check that the live property still routes through it, because a rule extracted for
/// testability is one revert from being unused.
@Suite struct ElapsedSpanTests {

    /// The shape the log has always used, unchanged: `nnn.n ms` under a second, `n.nn s` above.
    /// Anything that parses these lines keys on it.
    @Test func theOrdinarySpanKeepsTheFormatTheLogAlreadyUses() {
        #expect(Elapsed.describe(active: 0.0594, wall: 0.0594) == "59.4 ms")
        #expect(Elapsed.describe(active: 1.74, wall: 1.74) == "1.74 s")
        #expect(Elapsed.describe(active: 73.61, wall: 73.61) == "73.61 s")
    }

    /// **A span the machine slept through says so, instead of reporting the sleep as work.**
    ///
    /// The two-and-a-half-hour walk is the fixture: 84 ms of walking with the lid shut across it.
    /// Reported as one number it is indistinguishable from a walk that genuinely took that long,
    /// which is the whole reason the real slow cases have been impossible to find.
    @Test func aSpanTheMachineSleptThroughNamesTheSleep() {
        let text = Elapsed.describe(active: 0.084, wall: 8887.98)
        #expect(text.hasPrefix("84.0 ms"), "the work is no longer the headline number: “\(text)”")
        #expect(text.contains("asleep"), "the sleep is folded into the duration: “\(text)”")
        #expect(text.contains("8887.90 s"), "the sleep is not reported: “\(text)”")
        // And the number that WAS printed is gone — that is the defect, not the wording.
        #expect(!text.hasPrefix("8887"),
                "the span still leads with wall-clock time: “\(text)”")
    }

    /// Below a tenth of a second the two clocks differ only by the skew of reading them separately,
    /// and a `+ 0.0 ms asleep` on every ordinary line would be noise that trains the reader to skip
    /// the clause that matters.
    @Test func ordinaryClockSkewIsNotReportedAsSleep() {
        #expect(!Elapsed.describe(active: 1.0, wall: 1.05).contains("asleep"))
        #expect(Elapsed.describe(active: 1.0, wall: 1.2).contains("asleep"),
                "a fifth of a second is above the threshold and should be reported")
    }

    /// A live span reports only work, because nothing slept during it. The one end-to-end check
    /// that the two clocks are actually read — `describe` could be perfect over a pair of constants
    /// nothing supplies.
    @Test func aLiveSpanReportsWorkAndNoSleep() async throws {
        let span = Elapsed()
        try await Task.sleep(nanoseconds: 20_000_000)   // Task.sleep is not system sleep
        let text = span.text
        #expect(!text.contains("asleep"),
                "an awake machine was reported as sleeping: “\(text)”")
        #expect(text.contains("ms") || text.contains("s"), "no duration at all: “\(text)”")
    }

    /// **And the live property routes through the tested function.** Without this the suite above
    /// could stay green while `text` grew its own second copy of the formatting — the failure mode
    /// an extracted rule always has.
    @Test func theLivePropertyUsesTheTestedFormatter() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FileSyncManager+Scanning.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read the source — this check would be vacuous")
        let body = try #require(source.range(of: "var text: String {"),
                                "`Elapsed.text` is gone — this check would be vacuous")
        let end = try #require(source[body.upperBound...].range(of: "\n    }"))
        #expect(String(source[body.upperBound..<end.lowerBound]).contains("Self.describe("),
                "`text` no longer calls `describe` — the assertions above stopped covering the log")
    }
}
