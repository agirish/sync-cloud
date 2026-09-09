import Foundation
import Testing
@testable import Sync
@testable import FileExplorer

/// **What Compare forgot on every workspace switch — and the two resets that were quietly relying on
/// it forgetting.**
///
/// `DifferencesView` is mounted inside one arm of `ContentView`'s layout switch, so leaving Compare
/// destroyed it: the filter went back to All, the search closed and emptied, the sort back to
/// filename ascending, and every folder section re-expanded.
///
/// Hoisting that state is not the same change as Organize's, and this suite exists mostly for the
/// difference. Two of these values are retired by handlers that cannot fire while the view is not
/// mounted, so the rebuild WAS the reset — and a rescan started from Browse or from the Organize
/// rail happens with Compare torn down. Removing the rebuild without replacing that guarantee
/// reintroduces the two defects those handlers were written for: a remembered fold hiding
/// differences nobody has seen, and a `.failed` filter left standing over a table with nothing
/// failed in it.
@MainActor
@Suite struct DifferencesSessionTests {

    // MARK: What the reader set survives

    @Test func aSessionKeepsTheTablesNarrowing() {
        let session = DifferencesSession()
        session.selectedFilter = .missingOnRight
        session.searchText = "invoice"
        session.isSearchExpanded = true
        session.showItemCounts = true
        session.sortOrder = [KeyPathComparator(\FileDifference.fileName,
                                               comparator: .localizedStandard, order: .reverse)]

        #expect(session.selectedFilter == .missingOnRight)
        #expect(session.searchText == "invoice")
        #expect(session.isSearchExpanded)
        #expect(session.showItemCounts)
        #expect(session.sortOrder.first?.order == .reverse)
    }

    // MARK: The folds, and the scan they describe

    /// **The rule the arrival guard implements**, as a value: folds are kept while the comparison
    /// they describe is the one on screen, and dropped the moment it is not.
    ///
    /// Expressed against the stored scan date rather than by mounting the view, because what is
    /// being pinned is the decision — "do these folds belong to this scan" — and a rendered table
    /// cannot be asked that question directly.
    @Test func foldsAreKeptForTheirOwnScanAndDroppedForAnyOther() {
        let firstScan = Date(timeIntervalSince1970: 1_000)
        let session = DifferencesSession()
        session.collapsedSections = ["Documents", "Photos"]
        session.collapsedSectionsScanDate = firstScan

        // Coming back to the same comparison: the folds are still about these rows.
        #expect(session.collapsedSectionsScanDate == firstScan)
        #expect(session.collapsedSections.count == 2)

        // A rescan happened while Compare was off screen. The stored date no longer matches, which
        // is the whole signal the arrival guard reads.
        let secondScan = Date(timeIntervalSince1970: 2_000)
        #expect(session.collapsedSectionsScanDate != secondScan,
                "a new comparison was mistaken for the one the folds belong to")
    }

    /// A session that has never seen a scan does not claim to match one.
    ///
    /// This is the launch case, and it has to clear rather than keep: `nil != someDate`, so the
    /// first arrival drops an empty set, which costs nothing and keeps the guard total.
    @Test func aFreshSessionMatchesNoScan() {
        #expect(DifferencesSession().collapsedSectionsScanDate == nil)
    }

    // MARK: The guards, which nothing rendered would notice going missing

    private static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/\(file)")
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(file) — every scan here would be vacuous")
        try #require(text.count > 500, "\(file) read as \(text.count) characters — truncated?")
        return text
    }

    /// **The folds' retirement is asked on ARRIVAL, not only on a change.**
    ///
    /// Without `initial: true` the handler fires only when the scan date moves while Compare is
    /// watching — which is exactly the case that was already covered — and never in the case this
    /// change created. The suite would stay green and the folds would outlive their comparison.
    @Test func theFoldRetirementIsAskedOnArrival() throws {
        let view = try Self.source("DifferencesView.swift")
        #expect(view.contains(".onChange(of: syncManager.lastScanDate, initial: true)"),
                "the fold retirement no longer runs on arrival — folds from a previous comparison survive a switch")
        #expect(view.contains("session.collapsedSectionsScanDate = date"),
                "the folds no longer record which scan they belong to, so the guard cannot answer")
    }

    /// **A `.failed` filter is resolved on arrival.**
    ///
    /// It is set when a partial run publishes failures and cleared when they go, both by `.onChange`
    /// — so failures clearing while Compare is off screen used to be covered by the rebuild putting
    /// the filter back to `.all`. Standing, it filters a table with nothing failed in it down to
    /// nothing, with a Picker selection matching no tag and no visible way back.
    @Test func aStrandedFailedFilterIsResolvedOnArrival() throws {
        let view = try Self.source("DifferencesView.swift")
        #expect(view.contains("if selectedFilter == .failed, syncManager.lastTransferFailures == nil"),
                "nothing resolves a stranded .failed filter on arrival — Compare can open on an empty table with no way out")
    }

    /// **The row selections stay in the view**, and that is a decision rather than an oversight: an
    /// ID names a row in one comparison, and the review cursor rides `reviewSelection`. Carrying
    /// either across a rescan points it at rows that no longer exist.
    @Test func theRowSelectionsAreNotHoisted() throws {
        let view = try Self.source("DifferencesView.swift")
        #expect(view.contains("@State private var selection = Set<FileDifference.ID>()"),
                "the table selection was hoisted — it is keyed by row id and a rescan replaces the rows")
        #expect(view.contains("@State private var reviewSelection = Set<FileDifference.ID>()"),
                "the review cursor was hoisted — same hazard, and it also drives the guided session")
    }
}
