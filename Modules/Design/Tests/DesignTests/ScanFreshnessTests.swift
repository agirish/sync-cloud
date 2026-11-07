import Testing
import Foundation
@testable import Design

/// Coverage for the differences count pill's scan-freshness readout: the relative-age buckets,
/// the two spellings (`text` for a sentence, `age` for the pill's run), and the stale flag.
@Suite struct ScanFreshnessTests {

    private let base = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

    /// The spoken form is the only place staleness is put into words: elsewhere it is colour or a
    /// `.help` tooltip, and the age string is the same either way. Asserted as a pair either side
    /// of the threshold, so a version that always appended the warning fails.
    @Test func theSpokenFormSaysStaleOutLoudAndOnlyWhenStale() {
        let fresh = ScanFreshness.describe(scanDate: base, now: at(ScanFreshness.staleAfter - 1))
        let stale = ScanFreshness.describe(scanDate: base, now: at(ScanFreshness.staleAfter))

        #expect(fresh.isStale == false)
        #expect(fresh.spoken == "scanned 59 minutes ago")

        #expect(stale.isStale)
        #expect(stale.spoken == "scanned 1 hour ago, may be out of date")

        // Both carry the same age; only the spoken form tells them apart in words.
        #expect(fresh.age != stale.age || fresh.spoken != stale.spoken)
        #expect(stale.spoken.contains(stale.spokenAge))
    }

    /// VoiceOver is handed words, never the compact form, which it can read as "29 metres". Every
    /// bucket of the visible ladder has a spoken twin, and no spoken age carries a bare unit letter.
    @Test func theSpokenAgeIsInWordsBucketForBucket() {
        let table: [(seconds: TimeInterval, shown: String, spoken: String)] = [
            (0, "just now", "just now"),
            (30, "30s ago", "30 seconds ago"),
            (60, "1m ago", "1 minute ago"),
            (29 * 60, "29m ago", "29 minutes ago"),
            (3600, "1h ago", "1 hour ago"),
            (5 * 3600, "5h ago", "5 hours ago"),
            (86_400, "1d ago", "1 day ago"),
            (3 * 86_400, "3d ago", "3 days ago"),
        ]
        for row in table {
            let result = ScanFreshness.describe(scanDate: base, now: at(row.seconds))
            #expect(result.age == row.shown, "\(row.seconds)s")
            #expect(result.spokenAge == row.spoken, "\(row.seconds)s")
            #expect(result.spoken == "scanned \(row.spoken)"
                        + (result.isStale ? ", may be out of date" : ""))
        }
        for offset in stride(from: 0.0, through: 3 * 86_400, by: 97) {
            let spoken = ScanFreshness.describe(scanDate: base, now: at(offset)).spoken
            #expect(spoken.range(of: #"\d[smhd] "#, options: .regularExpression) == nil,
                    "compact unit spoken at \(offset)s: \(spoken)")
        }
    }

    /// Every bucket edge in one table, so a seam change (a new bucket, rounding, an off-by-one)
    /// fails one test with the whole table in view, mid-bucket cells included: 5400s (1.5h) must read
    /// "1h ago", which rounding would make "2h". Labels floor, so they never contradict the next
    /// coarser unit.
    @Test func fullBoundaryTable() {
        let table: [(seconds: TimeInterval, label: String)] = [
            (0, "just now"),
            (29, "just now"), (30, "30s ago"),                   // just now → 30s
            (45, "30s ago"),
            (59, "30s ago"), (60, "1m ago"),                     // 30s → 1m at a full minute
            (89, "1m ago"), (90, "1m ago"),                      // no rounding jump at 1.5m
            (119, "1m ago"), (120, "2m ago"),                    // 1m → 2m only at 2 full minutes
            (240, "4m ago"),
            (3570, "59m ago"),
            (3599, "59m ago"), (3600, "1h ago"),                 // minutes cap at 59
            (5399, "1h ago"), (5400, "1h ago"),                  // no rounding jump at 1.5h
            (7199, "1h ago"), (7200, "2h ago"),                  // 1h → 2h only at 2 full hours
            (10_800, "3h ago"),
            (86_399, "23h ago"), (86_400, "1d ago"),             // hours cap at 23
            (93_600, "1d ago"),
            (129_599, "1d ago"), (129_600, "1d ago"),            // no rounding jump at 1.5 days
            (172_799, "1d ago"), (172_800, "2d ago"),            // 1d → 2d at 2 full days
            (259_200, "3d ago"),
        ]
        for row in table {
            #expect(ScanFreshness.relative(row.seconds) == row.label,
                    "relative(\(row.seconds)) should be \(row.label)")
        }
        // Fractional seconds floor too: 29.9s is still "just now", 119.9s still "1m ago".
        #expect(ScanFreshness.relative(29.9) == "just now")
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

    /// Pins the threshold's value, which the test above can't: it spells `staleAfter` symbolically.
    /// The 45-minute case fails if the threshold drops to ten minutes. An hour because the app is
    /// left open for hours, and a shorter threshold keeps the pill stale so often the warning
    /// reads as furniture.
    @Test func theThresholdIsAnHourAndNotTheOldTenMinutes() {
        #expect(ScanFreshness.staleAfter == 3600)
        #expect(ScanFreshness.describe(scanDate: base, now: at(45 * 60)).isStale == false)
        #expect(ScanFreshness.describe(scanDate: base, now: at(90 * 60)).isStale == true)
    }

    @Test func aClockSkewIntoTheFutureClampsToZeroSeconds() {
        // now < scanDate (clock adjustment) must not produce a negative age.
        let r = ScanFreshness.describe(scanDate: at(100), now: base)
        #expect(r.text == "Scanned just now")
        #expect(r.isStale == false)
    }

    /// From 120s up to a day the ladder must match the earlier implementation exactly, checked
    /// against a verbatim copy rather than a hand-written table, which can agree with a mistake.
    /// It also proves `s / 60` and `s / 3600` subsume the old `..<120` and `..<7200` cases.
    @Test func everythingFromTwoMinutesUpIsUnchanged() {
        // The earlier ladder, verbatim, as the oracle.
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

        // Every second up to a day. From a day on, the oracle uses words ("1 day ago") where this
        // ladder stays compact ("1d ago"), deliberately; see the next test.
        for s in stride(from: 120, to: 86_400, by: 1) {
            let t = TimeInterval(s)
            #expect(ScanFreshness.relative(t) == old(t),
                    "relative(\(s)) drifted from the previous ladder")
        }
    }

    /// Below 120s and from a day on, the ladder deliberately differs from the oracle, so this
    /// guards the equivalence test against silently covering every range and proving nothing.
    @Test func belowTwoMinutesAndFromADayTheLadderDeliberatelyDiffers() {
        #expect(ScanFreshness.relative(30) != "just now")
        #expect(ScanFreshness.relative(45) != "1m ago")
        #expect(ScanFreshness.relative(86_400) != "1 day ago")
        #expect(ScanFreshness.relative(3 * 86_400) != "3 days ago")
    }

    /// `text` (the tooltip and all-in-sync sentence) must be `age` (the count pill's bare run) with
    /// a subject added. From different clocks, a pill and its tooltip would disagree about a scan.
    @Test func ageIsTheSentenceWithoutItsSubject() {
        for offset in [0.0, 45, 90, 610, 4000, 90_000, 200_000] {
            let result = ScanFreshness.describe(scanDate: base, now: base.addingTimeInterval(offset))
            #expect(result.text == "Scanned \(result.age)", "offset \(offset)")
            #expect(result.age == ScanFreshness.relative(offset), "offset \(offset)")
        }
    }

    /// A change on disk makes a fresh scan stale, in words as well as colour. Pinned as a pair at
    /// one instant, so a version that always appended the clause fails.
    @Test func aChangeOnDiskMakesAFreshScanStaleAndSaysWhy() {
        let quiet = ScanFreshness.describe(scanDate: base, now: at(120))
        let changed = ScanFreshness.describe(scanDate: base, now: at(120), changedOnDisk: true)

        #expect(!quiet.isStale && !quiet.changedOnDisk)
        #expect(quiet.text == "Scanned 2m ago")
        #expect(quiet.spoken == "scanned 2 minutes ago")

        #expect(changed.isStale && changed.changedOnDisk)
        #expect(changed.age == "2m ago", "the age is still the scan's age")
        #expect(changed.text == "Scanned 2m ago, changed since")
        #expect(changed.spoken == "scanned 2 minutes ago, changed on disk since")
    }

    /// Additive only: seeing no change never makes an old scan fresh. A watcher can miss changes
    /// (an idle Mac's iCloud, a Dropbox that isn't running), so the hour's warning must stand.
    @Test func noChangeSeenNeverMakesAnOldScanFresh() {
        let old = ScanFreshness.describe(scanDate: base, now: at(ScanFreshness.staleAfter), changedOnDisk: false)
        #expect(old.isStale)
        #expect(old.spoken == "scanned 1 hour ago, may be out of date")
        // Old AND changed: the change is the more specific reason, and the one said.
        let both = ScanFreshness.describe(scanDate: base, now: at(ScanFreshness.staleAfter), changedOnDisk: true)
        #expect(both.isStale)
        #expect(both.spoken == "scanned 1 hour ago, changed on disk since")
        #expect(both.text == "Scanned 1h ago, changed since")
    }
}
