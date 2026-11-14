import Testing
import Foundation
@testable import FileExplorer

/// `LensWorkspaceView.RailCounts`: the six scoped counts, resolved once per render because each is
/// a filtering pass over long lists in a header that re-renders constantly. Tested here: the lens
/// to number mapping, and the badge arithmetic the rail's width reservation depends on.
@Suite struct OrganizeRailCountsTests {

    static let counts = LensWorkspaceView.RailCounts(
        toFile: 24, duplicates: 722, names: 3, renames: 126, restructure: 2, rules: 8)

    @Test func everyLensReadsItsOwnNumber() {
// Every value distinct, so a copy-pasted pair cannot hide.
        let c = Self.counts
        #expect(c[.toFile] == 24)
        #expect(c[.duplicates] == 722)
// Renames' badge counts its folder rows plus the risky names; distinct addends prove the sum.
        #expect(c[.renames] == 126 + 3)
        #expect(c[.restructure] == 2)
        #expect(c[.rules] == 8)
        // And the six are genuinely distinct, so the assertions above discriminate.
        #expect(Set(OrganizeLens.allCases.map { c[$0] }).count == OrganizeLens.allCases.count)
    }

    @Test func badgeAnswersForTheItemsThatWouldDrawOne() {
// `OrganizeRailMetrics` sizes the rail from these, by value, since a badge is as wide as its
// digits. Four: `.rules` and `.storage` never carry one.
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

/// The backlog's readout counts the same list its badge does, through the subscript, or the badge
/// says 129 beside "of 126". Source-level: the numerals are a `Text` no test can read back.
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
