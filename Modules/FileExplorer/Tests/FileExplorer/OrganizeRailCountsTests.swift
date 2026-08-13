import Testing
import Foundation
@testable import FileExplorer

/// `TidyView.RailCounts` — the six scoped counts, resolved once per render.
///
/// It exists because scoping turned six `Array.count` reads into six filtering passes with path
/// math in the predicate, over lists that reach 722 duplicate groups and 1,192 rename plans on the
/// real profile — and they were being run **twice over**, once for the width arithmetic and once
/// per rail item. Twelve scoped passes per render of a header that re-renders on every manager
/// publish, hover and defaults change.
///
/// What is testable here is the part that would silently go wrong: the mapping from lens to number,
/// and the badge arithmetic the rail's width reservation depends on.
@Suite struct OrganizeRailCountsTests {

    static let counts = TidyView.RailCounts(
        toFile: 24, duplicates: 722, names: 3, renames: 126, restructure: 2, rules: 8)

    @Test func everyLensReadsItsOwnNumber() {
        // A subscript over six near-identical cases is exactly where a copy-paste puts `renames`
        // on `.restructure`. Every value here is distinct so a swapped pair cannot hide.
        let c = Self.counts
        #expect(c[.toFile] == 24)
        #expect(c[.duplicates] == 722)
        #expect(c[.names] == 3)
        // The folded lens's badge counts its whole list — folder rows AND the to-fix rows the
        // Names fold moved in (P10). 126 folders + 3 names; the distinct addends above prove
        // the sum is a sum and not one of them.
        #expect(c[.renames] == 126 + 3)
        #expect(c[.restructure] == 2)
        #expect(c[.rules] == 8)
        // And the six are genuinely distinct, so the assertions above discriminate.
        #expect(Set(OrganizeLens.allCases.map { c[$0] }).count == OrganizeLens.allCases.count)
    }

    @Test func badgeAnswersForTheItemsThatWouldDrawOne() {
        // These are what `OrganizeRailMetrics` sizes the rail from, so a wrong answer here
        // mis-measures it and truncates the lens's own controls — the failure
        // `OrganizeRailMetrics` exists to prevent. **The VALUE, not a count of them**: a badge is
        // as wide as its digits, and charging a flat figure per badge is what let row 1 overrun.
        //
        // Five, not six: `.rules` never carries a badge (`carriesBadge` is false), because eight
        // rules is a configuration you keep rather than a result a scan turned up.
        #expect(OrganizeLens.allCases.count { Self.counts.badge($0) != nil } == 5)
        // And each one carries its own list's size rather than some shared truthy marker.
        for lens in OrganizeLens.allCases where lens.carriesBadge {
            #expect(Self.counts.badge(lens) == Self.counts[lens])
        }
    }

    @Test func aZeroDrawsNoBadge() {
        // The surviving half of the chips' argument: absent at zero, never a greyed "0".
        let none = TidyView.RailCounts()
        #expect(OrganizeLens.allCases.allSatisfy { none.badge($0) == nil })
        let one = TidyView.RailCounts(toFile: 1)
        #expect(one.badge(.toFile) == 1)
        #expect(OrganizeLens.allCases.count { one.badge($0) != nil } == 1)
    }

    @Test func rulesNeverBadgesEvenWhenItHasRules() {
        // The distinction the badge draws, asserted through the same arithmetic the rail uses
        // rather than by re-reading `carriesBadge`.
        let rulesOnly = TidyView.RailCounts(rules: 8)
        #expect(rulesOnly[.rules] == 8)
        #expect(rulesOnly.badge(.rules) == nil)
    }

    @Test func theDefaultIsAllZeros() {
        // The pre-scan state: nothing counted, nothing claimed.
        let d = TidyView.RailCounts()
        #expect(OrganizeLens.allCases.allSatisfy { d[$0] == 0 })
    }

    /// **"Clean" on the folded item vouches for BOTH of its lists.** The badge sums
    /// `renames + names` (the subscript above), and the two halves are filled by different
    /// passes — rename plans by the filing walk, risky names by `detectRiskyNames`, which that
    /// walk runs only when a name ruleset is supplied. So the folded item is scanned only when
    /// both halves ran; one half alone must read "not scanned", never "nothing here".
    ///
    /// The two half-fixtures discriminate the candidate rules: under "the rename half ran" the
    /// first passes and the second fails; under "either half ran" both fail; only "both halves
    /// ran" — the rule that can underclaim but never overclaim — answers all four.
    @Test func theFoldedItemIsNotCleanUntilBothHalvesHaveRun() {
        var counts = TidyView.RailCounts()
        counts.scanned = [.renames]      // filing walk ran without a name ruleset (CLI shape)
        #expect(counts.state(.renames) == .notScanned,
                "rename plans alone called the folded item clean — the names list was never computed")
        counts.scanned = [.names]        // names half ran and came back clean; plans never computed
        #expect(counts.state(.renames) == .notScanned,
                "a names-only pass called the whole folded item clean")
        counts.scanned = [.renames, .names]
        #expect(counts.state(.renames) == .clean)
        // Findings outrank the scan question — a badge is a badge whichever half found it.
        counts.names = 3
        counts.scanned = []
        #expect(counts.state(.renames) == .reporting(3))
    }

    /// **The backlog's readout counts the same list its badge does.**
    ///
    /// `126 + 3` is the badge's number, and the readout's denominator was the bare `renames` field:
    /// one screen with a badge saying 129, a readout saying "of 126", and a list holding both kinds
    /// of row. The subscript is what makes them one number, so the readout has to go through it.
    ///
    /// Source-level, because the numerals themselves are a `Text` in a header that no test can read
    /// back — pixels can see that a readout is there, never what it says. `TidyHeaderReadoutTests`
    /// covers the *rows* half of the same fix by render; this is the denominator half, and the two
    /// together are why a source scan is worth having here rather than being the whole story.
    @Test func theBacklogReadoutUsesTheFoldedTotal() throws {
        let body = try OrganizeScopeCallSiteTests.body(
            of: "private func lensTrailing(rows: FilteredRows, counts: RailCounts) -> some View {",
            in: try OrganizeScopeCallSiteTests.source("TidyView.swift"))
        let code = OrganizeScopeCallSiteTests.codeOnly(body)
        #expect(code.contains("ofMLabel(rows.renames.count + rows.risky.count, counts[.renames])"),
                "the backlog's readout is not counting the folded list at both ends")
        #expect(!code.contains("counts.renames"),
                "the backlog's readout is back on the plans-only total the badge does not use")
    }
}
