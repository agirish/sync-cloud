import Foundation
import Testing
@testable import Sync
@testable import FileExplorer

/// Compare's table state (filter, search, sort, folds) lives in `DifferencesSession`, so it survives
/// a workspace switch that tears `DifferencesView` down.
///
/// Two of those values are retired by handlers that can't fire while the view is unmounted, and a
/// rescan from Browse or Organize happens with Compare torn down. So both are also resolved on
/// arrival; otherwise a remembered fold could hide differences nobody has seen, and a `.failed`
/// filter could stand over a table with nothing failed in it.
@MainActor
@Suite struct DifferencesSessionTests {

    // MARK: What the reader set survives

    /// Ask Claude's “show me the ones only on Dropbox”: the filter, the selection asked for, and
    /// nothing left that would hide a selected row.
    @Test func showingRowsNarrowsTheTableAndAsksForTheirSelection() {
        let session = DifferencesSession()
        session.searchText = "invoice"
        session.isSearchExpanded = true
        session.collapsedSections = ["2019-2022"]
        let ids: Set<UUID> = [UUID(), UUID()]
        session.show(.missingOnLeft, selecting: ids)
        #expect(session.selectedFilter == .missingOnLeft)
        #expect(session.requestedSelection == ids)
        #expect(session.searchText.isEmpty && !session.isSearchExpanded && session.collapsedSections.isEmpty)
    }

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

    /// The rule the arrival guard implements: folds are kept while the comparison they describe is
    /// on screen, and dropped once it is not. Checked against the stored scan date, because a
    /// rendered table can't be asked whether its folds belong to this scan.
    @Test func foldsAreKeptForTheirOwnScanAndDroppedForAnyOther() {
        let firstScan = Date(timeIntervalSince1970: 1_000)
        let session = DifferencesSession()
        session.collapsedSections = ["Documents", "Photos"]
        session.collapsedSectionsScanDate = firstScan

        // Coming back to the same comparison: the folds are still about these rows.
        #expect(session.collapsedSectionsScanDate == firstScan)
        #expect(session.collapsedSections.count == 2)

        // A rescan while Compare was off screen: the stored date no longer matches, which is the
        // signal the arrival guard reads.
        let secondScan = Date(timeIntervalSince1970: 2_000)
        #expect(session.collapsedSectionsScanDate != secondScan,
                "a new comparison was mistaken for the one the folds belong to")
    }

    /// A session that has never seen a scan does not claim to match one. At launch `nil !=
    /// someDate`, so the first arrival drops an empty set, which costs nothing.
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

    /// The folds' retirement runs on arrival, not only on a change. Without `initial: true` the
    /// handler fires only when the scan date moves while Compare is on screen, and folds would
    /// outlive a comparison replaced while it was away.
    @Test func theFoldRetirementIsAskedOnArrival() throws {
        let view = try Self.source("DifferencesView.swift")
        #expect(view.contains(".onChange(of: syncManager.lastScanDate, initial: true)"),
                "the fold retirement no longer runs on arrival — folds from a previous comparison survive a switch")
        #expect(view.contains("session.collapsedSectionsScanDate = date"),
                "the folds no longer record which scan they belong to, so the guard cannot answer")
    }

    /// The count pill ages the comparison by the walks it compared, not by when the scan ran. A
    /// scan from cached trees can compare a walk hours old, and aged from `lastScanDate` the pill
    /// would say "just now" over it. The age and the tick anchor read `lastScanReadAt`; the fold
    /// reset stays on `lastScanDate`, the scan's identity.
    @Test func theCountPillAgesTheComparisonByItsWalks() throws {
        let view = try Self.source("DifferencesView.swift")
        #expect(view.contains("let scanDate = syncManager.lastScanReadAt ?? completed"),
                "the pill's age is the scan's again — a comparison of an hours-old walk reads as just scanned")
        #expect(view.contains("TimelineView(ScanFreshnessSchedule(anchor: syncManager.lastScanReadAt ?? completed,"),
                "the pill ticks from the scan, not from the date its age is measured from — the stale flip lands off the threshold")
    }

    /// A `.failed` filter is resolved on arrival. It is set and cleared by `.onChange`, which can't
    /// see failures clear while Compare is off screen. Left standing, it filters the table to
    /// nothing, with a Picker selection matching no tag and no visible way back.
    @Test func aStrandedFailedFilterIsResolvedOnArrival() throws {
        let view = try Self.source("DifferencesView.swift")
        #expect(view.contains("if selectedFilter == .failed, syncManager.lastTransferFailures == nil"),
                "nothing resolves a stranded .failed filter on arrival — Compare can open on an empty table with no way out")
    }

    /// The row selections stay in the view on purpose: an ID names a row in one comparison, and the
    /// review cursor rides `reviewSelection`. Carried across a rescan, either would point at rows
    /// that no longer exist.
    @Test func theRowSelectionsAreNotHoisted() throws {
        let view = try Self.source("DifferencesView.swift")
        #expect(view.contains("@State private var selection = Set<FileDifference.ID>()"),
                "the table selection was hoisted — it is keyed by row id and a rescan replaces the rows")
        #expect(view.contains("@State private var reviewSelection = Set<FileDifference.ID>()"),
                "the review cursor was hoisted — same hazard, and it also drives the guided session")
    }
}
