import Testing
import Foundation
@testable import Design

/// Coverage for the differences count pill's scan-freshness readout: the relative-age buckets,
/// the two spellings (`text` for a sentence, `age` for the pill's run), and the stale flag.
@Suite struct ScanFreshnessTests {

    private let base = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

    @Test func relativeBuckets() {
        #expect(ScanFreshness.relative(0) == "0s ago")
        #expect(ScanFreshness.relative(30) == "30s ago")
        #expect(ScanFreshness.relative(60) == "1m ago")
        #expect(ScanFreshness.relative(4 * 60) == "4m ago")
        #expect(ScanFreshness.relative(60 * 60) == "1h ago")
        #expect(ScanFreshness.relative(3 * 3600) == "3h ago")
        #expect(ScanFreshness.relative(26 * 3600) == "1 day ago")
        #expect(ScanFreshness.relative(3 * 86_400) == "3 days ago")
    }

    /// Pins the unit seams: labels floor, so they can never contradict the next coarser unit.
    @Test func unitBoundariesNeverContradictTheCoarserUnit() {
        // The sub-minute steps. The OLD ladder broke the floor invariant right here: "just now"
        // ran 0–44s and "1m ago" began at 45s, claiming a minute that had not elapsed. Now 30s
        // covers 30–59 and 1m starts at a genuine 60.
        #expect(ScanFreshness.relative(29) == "0s ago")
        #expect(ScanFreshness.relative(30) == "30s ago")
        #expect(ScanFreshness.relative(45) == "30s ago")
        #expect(ScanFreshness.relative(59) == "30s ago")
        #expect(ScanFreshness.relative(60) == "1m ago")

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

    /// The complete boundary table — every bucket edge cell in one place, so any future seam
    /// change (a new bucket, a rounding reintroduction, an off-by-one) flips a single test with
    /// the whole table in view. Includes the mid-bucket floor cells the seam test skips: 5400s
    /// (1.5h) must still read "1h ago" — the old ROUNDING behavior jumped to "2h" there.
    @Test func fullBoundaryTable() {
        let table: [(seconds: TimeInterval, label: String)] = [
            (0, "0s ago"),
            (29, "0s ago"), (30, "30s ago"),                     // 0s → 30s
            (59, "30s ago"), (60, "1m ago"),                     // 30s → 1m at a full minute
            (89, "1m ago"), (90, "1m ago"),                      // no rounding jump at 1.5m
            (119, "1m ago"), (120, "2m ago"),                    // 1m → 2m only at 2 full minutes
            (3599, "59m ago"), (3600, "1h ago"),                 // minutes cap at 59
            (5399, "1h ago"), (5400, "1h ago"),                  // no rounding jump at 1.5h
            (7199, "1h ago"), (7200, "2h ago"),                  // 1h → 2h only at 2 full hours
            (86_399, "23h ago"), (86_400, "1 day ago"),          // hours cap at 23
            (129_599, "1 day ago"), (129_600, "1 day ago"),      // no rounding jump at 1.5 days
            (172_799, "1 day ago"), (172_800, "2 days ago"),     // 1 day → 2 days at 2 full days
        ]
        for row in table {
            #expect(ScanFreshness.relative(row.seconds) == row.label,
                    "relative(\(row.seconds)) should be \(row.label)")
        }
        // Fractional seconds floor too: 29.9s is still "0s ago", 119.9s still "1m ago".
        #expect(ScanFreshness.relative(29.9) == "0s ago")
        #expect(ScanFreshness.relative(59.9) == "30s ago")
        #expect(ScanFreshness.relative(119.9) == "1m ago")
    }

    @Test func describeMarksStalePastTheThreshold() {
        let fresh = ScanFreshness.describe(scanDate: base, now: at(4 * 60))
        #expect(fresh.text == "Scanned 4m ago")
        #expect(fresh.isStale == false)

        let stale = ScanFreshness.describe(scanDate: base, now: at(2 * 3600))
        #expect(stale.text == "Scanned 2h ago")
        #expect(stale.isStale == true)

        // Exactly at the threshold counts as stale; one second shy does not.
        #expect(ScanFreshness.describe(scanDate: base, now: at(ScanFreshness.staleAfter)).isStale == true)
        #expect(ScanFreshness.describe(scanDate: base, now: at(ScanFreshness.staleAfter - 1)).isStale == false)
    }

    @Test func aClockSkewIntoTheFutureClampsToZeroSeconds() {
        // now < scanDate (clock adjustment) must not produce a negative age.
        let r = ScanFreshness.describe(scanDate: at(100), now: base)
        #expect(r.text == "Scanned 0s ago")
        #expect(r.isStale == false)
    }

    /// The ladder change was scoped to the sub-minute steps ONLY. Everything from 120s up must
    /// come out byte-identical to the previous implementation, which is asserted here against a
    /// verbatim copy of it rather than against a hand-written table — a table can agree with a
    /// mistake, an oracle cannot. This also covers the two cases deleted as redundant (`..<120`
    /// and `..<7200`): if `s / 60` and `s / 3600` did not already subsume them, this fails.
    @Test func everythingFromTwoMinutesUpIsUnchanged() {
        // The pre-change implementation, verbatim.
        func old(_ seconds: TimeInterval) -> String {
            let s = Int(seconds)
            switch s {
            case ..<45: return "just now"
            case ..<120: return "1m ago"
            case ..<3600: return "\(s / 60)m ago"
            case ..<7200: return "1h ago"
            case ..<86_400: return "\(s / 3600)h ago"
            default:
                let days = s / 86_400
                return days <= 1 ? "1 day ago" : "\(days) days ago"
            }
        }

        // Every second across three days, plus each bucket seam far above it.
        for s in stride(from: 120, through: 3 * 86_400, by: 1) {
            let t = TimeInterval(s)
            #expect(ScanFreshness.relative(t) == old(t),
                    "relative(\(s)) drifted from the previous ladder")
        }
        for s in [7 * 86_400, 30 * 86_400, 365 * 86_400] {
            let t = TimeInterval(s)
            #expect(ScanFreshness.relative(t) == old(t))
        }
    }

    /// Below 120s the change is deliberate, so the oracle above must NOT agree — a guard against
    /// the equivalence test silently covering the whole range and proving nothing.
    @Test func belowTwoMinutesTheLadderDeliberatelyDiffers() {
        #expect(ScanFreshness.relative(0) != "just now")
        #expect(ScanFreshness.relative(45) != "1m ago")
    }

    /// The two spellings must stay in lockstep: `text` is the sentence the tooltip and the
    /// all-in-sync placeholder use, `age` is the bare run that rides inside the count pill next to
    /// the pill's own "Differences" label. One is the other with a subject bolted on — if they ever
    /// come from different clocks, a pill and its tooltip would disagree about the same scan.
    @Test func ageIsTheSentenceWithoutItsSubject() {
        for offset in [0.0, 45, 90, 610, 4000, 90_000, 200_000] {
            let result = ScanFreshness.describe(scanDate: base, now: base.addingTimeInterval(offset))
            #expect(result.text == "Scanned \(result.age)", "offset \(offset)")
            #expect(result.age == ScanFreshness.relative(offset), "offset \(offset)")
        }
    }
}
