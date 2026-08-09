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
        #expect(c[.renames] == 126)
        #expect(c[.restructure] == 2)
        #expect(c[.rules] == 8)
        // And the six are genuinely distinct, so the assertions above discriminate.
        #expect(Set(OrganizeLens.allCases.map { c[$0] }).count == OrganizeLens.allCases.count)
    }

    @Test func badgedCountsTheItemsThatWouldDrawOne() {
        // This number is what `OrganizeRailMetrics.style` reserves width for, so an off-by-one
        // here mis-sizes the rail and truncates the lens's own controls — the failure
        // `OrganizeRailMetrics` exists to prevent.
        //
        // Five, not six: `.rules` never carries a badge (`carriesBadge` is false), because eight
        // rules is a configuration you keep rather than a result a scan turned up.
        #expect(Self.counts.badged == 5)
    }

    @Test func aZeroDrawsNoBadge() {
        // The surviving half of the chips' argument: absent at zero, never a greyed "0".
        let none = TidyView.RailCounts()
        #expect(none.badged == 0)
        let one = TidyView.RailCounts(toFile: 1)
        #expect(one.badged == 1)
    }

    @Test func rulesNeverBadgesEvenWhenItHasRules() {
        // The distinction the badge draws, asserted through the same arithmetic the rail uses
        // rather than by re-reading `carriesBadge`.
        let rulesOnly = TidyView.RailCounts(rules: 8)
        #expect(rulesOnly[.rules] == 8)
        #expect(rulesOnly.badged == 0)
    }

    @Test func theDefaultIsAllZeros() {
        // The pre-scan state: nothing counted, nothing claimed.
        let d = TidyView.RailCounts()
        #expect(OrganizeLens.allCases.allSatisfy { d[$0] == 0 })
    }
}
