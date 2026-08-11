import Testing
@testable import FileExplorer

/// The overview card's trailing count wears the C1 mini pill, built from the headline's own
/// count + unit. `headlineUnit` must slice exactly the unit run — and must refuse a headline
/// that doesn't lead with the count, so the pill can never render "79 79 folders".
@Suite struct OverviewHeadlinePillTests {

    @Test func unitIsTheRunAfterTheCount() {
        #expect(OrganizeOverview.headlineUnit(count: 79, headline: "79 folders") == "folders")
        #expect(OrganizeOverview.headlineUnit(count: 1, headline: "1 finding") == "finding")
    }

    @Test func headlineNotLedByThisCountRefuses() {
        // A reworded headline must fall back to drawing the whole string, not double the count.
        #expect(OrganizeOverview.headlineUnit(count: 79, headline: "folders: 79") == nil)
        #expect(OrganizeOverview.headlineUnit(count: 7, headline: "79 folders") == nil)
    }
}
