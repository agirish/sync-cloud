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
