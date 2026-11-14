import Testing
import Foundation
@testable import FileExplorer

/// `LensWorkspaceView.RailCounts`: the six scoped counts, resolved once per render. Each is a
/// filtering pass with path math over lists that reach hundreds of duplicate groups and over a
/// thousand rename plans, in a header that re-renders on every manager publish, hover and defaults
/// change, so the width arithmetic and the rail items share one set.
///
/// Tested here: the mapping from lens to number, and the badge arithmetic the rail's width
/// reservation depends on.
@Suite struct OrganizeRailCountsTests {

    static let counts = LensWorkspaceView.RailCounts(
        toFile: 24, duplicates: 722, names: 3, renames: 126, restructure: 2, rules: 8)

    @Test func everyLensReadsItsOwnNumber() {
        // A subscript over six near-identical cases is exactly where a copy-paste puts `renames`
        // on `.restructure`. Every value here is distinct so a swapped pair cannot hide.
        let c = Self.counts
        #expect(c[.toFile] == 24)
        #expect(c[.duplicates] == 722)
        // Renames' badge counts its whole list: folder rows and the risky-name to-fix rows. 126
        // folders + 3 names (`names` is its own stored count); distinct addends prove the sum.
        #expect(c[.renames] == 126 + 3)
        #expect(c[.restructure] == 2)
        #expect(c[.rules] == 8)
        // And the six are genuinely distinct, so the assertions above discriminate.
        #expect(Set(OrganizeLens.allCases.map { c[$0] }).count == OrganizeLens.allCases.count)
    }

    @Test func badgeAnswersForTheItemsThatWouldDrawOne() {
        // `OrganizeRailMetrics` sizes the rail from these, so a wrong answer truncates the lens's
        // own controls. The value, not a count of them: a badge is as wide as its digits, and a
        // flat figure per badge would let row 1 overrun.
        //
        // Four: `.rules` and `.storage` never carry a badge (`carriesBadge` is false).
        #expect(OrganizeLens.allCases.count { Self.counts.badge($0) != nil } == 4)
        // And each one carries its own list's size rather than some shared truthy marker.
        for lens in OrganizeLens.allCases where lens.carriesBadge {
            #expect(Self.counts.badge(lens) == Self.counts[lens])
        }
    }

    @Test func aZeroDrawsNoBadge() {
        // Absent at zero, never a greyed "0".
        let none = LensWorkspaceView.RailCounts()
        #expect(OrganizeLens.allCases.allSatisfy { none.badge($0) == nil })
        // The pre-scan state: nothing counted, nothing claimed.
        #expect(OrganizeLens.allCases.allSatisfy { none[$0] == 0 })
        let one = LensWorkspaceView.RailCounts(toFile: 1)
        #expect(one.badge(.toFile) == 1)
        #expect(OrganizeLens.allCases.count { one.badge($0) != nil } == 1)
    }

    /// The backlog's readout counts the same list its badge does, through the subscript, or the
    /// badge says 129 beside a readout saying "of 126". Source-level, because the numerals are a
    /// `Text` in a header no test can read back. `LensHeaderReadoutTests` covers the rows half by
    /// render; this is the denominator half.
    @Test func theBacklogReadoutUsesTheFoldedTotal() throws {
        let body = try SourceText.body(
            of: "private func lensTrailing(rows: FilteredRows, counts: RailCounts) -> some View {",
            in: try SourceText.fileExplorer("LensWorkspaceView.swift"))
        let code = SourceText.codeOnly(body)
        #expect(code.contains("ofMLabel(rows.renames.count + rows.risky.count, counts[.renames])"),
                "the backlog's readout is not counting the folded list at both ends")
        #expect(!code.contains("counts.renames"),
                "the backlog's readout is back on the plans-only total the badge does not use")
    }
}
