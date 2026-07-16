import Testing
import Foundation
@testable import Dashboard

/// Coverage for the pane header's scan-freshness pill: the relative-age buckets and the stale flag.
@Suite struct ScanFreshnessTests {

    private let base = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

    @Test func relativeBuckets() {
        #expect(ScanFreshness.relative(0) == "just now")
        #expect(ScanFreshness.relative(30) == "just now")
        #expect(ScanFreshness.relative(60) == "1m ago")
        #expect(ScanFreshness.relative(4 * 60) == "4m ago")
        #expect(ScanFreshness.relative(60 * 60) == "1h ago")
        #expect(ScanFreshness.relative(3 * 3600) == "3h ago")
        #expect(ScanFreshness.relative(26 * 3600) == "1 day ago")
        #expect(ScanFreshness.relative(3 * 86_400) == "3 days ago")
    }

    /// Pins the unit seams: labels floor, so they can never contradict the next coarser unit.
    @Test func unitBoundariesNeverContradictTheCoarserUnit() {
        // just now → 1m: continuous at 45s.
        #expect(ScanFreshness.relative(44) == "just now")
        #expect(ScanFreshness.relative(45) == "1m ago")

        // No "1m → 2m" jump at 90s (only 1.5 minutes elapsed); 2m starts when 2 minutes have.
        #expect(ScanFreshness.relative(89) == "1m ago")
        #expect(ScanFreshness.relative(90) == "1m ago")
        #expect(ScanFreshness.relative(119) == "1m ago")
        #expect(ScanFreshness.relative(120) == "2m ago")

        // Minutes cap at 59: 3570–3599s must not read "60m ago".
        #expect(ScanFreshness.relative(3570) == "59m ago")
        #expect(ScanFreshness.relative(3599) == "59m ago")
        #expect(ScanFreshness.relative(3600) == "1h ago")
        #expect(ScanFreshness.relative(7199) == "1h ago")
        #expect(ScanFreshness.relative(7200) == "2h ago")

        // Hours cap at 23: just shy of a day must not read "24h ago".
        #expect(ScanFreshness.relative(86_399) == "23h ago")
        #expect(ScanFreshness.relative(86_400) == "1 day ago")
        #expect(ScanFreshness.relative(2 * 86_400 - 1) == "1 day ago")
        #expect(ScanFreshness.relative(2 * 86_400) == "2 days ago")
    }

    @Test func describeMarksStalePastTheThreshold() {
        let fresh = ScanFreshness.describe(scanDate: base, now: at(4 * 60))
        #expect(fresh.text == "Scanned 4m ago")
        #expect(fresh.isStale == false)

        let stale = ScanFreshness.describe(scanDate: base, now: at(2 * 3600))
        #expect(stale.text == "Scanned 2h ago")
        #expect(stale.isStale == true)

        // Exactly at the threshold counts as stale.
        #expect(ScanFreshness.describe(scanDate: base, now: at(ScanFreshness.staleAfter)).isStale == true)
    }

    @Test func aClockSkewIntoTheFutureClampsToJustNow() {
        // now < scanDate (clock adjustment) must not produce a negative age.
        let r = ScanFreshness.describe(scanDate: at(100), now: base)
        #expect(r.text == "Scanned just now")
        #expect(r.isStale == false)
    }
}
