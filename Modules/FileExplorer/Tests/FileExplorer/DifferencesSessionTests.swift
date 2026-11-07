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

    /// What Compare opens on before anyone narrows it, and what it forgot on every workspace switch
    /// before the session held it.
    @Test func aFreshSessionHasTheDefaults() {
        let session = DifferencesSession()
        #expect(session.selectedFilter == .all)
        #expect(session.searchText.isEmpty && !session.isSearchExpanded)
        #expect(session.sortOrder.count == 1 && session.sortOrder.first?.keyPath == \FileDifference.fileName
                && session.sortOrder.first?.order == .forward)
        #expect(!session.showItemCounts)
        // Nil, so the first arrival drops an empty fold set rather than claiming to match a scan.
        #expect(session.collapsedSections.isEmpty && session.collapsedSectionsScanDate == nil)
        #expect(session.requestedSelection == nil)
    }

    // MARK: The guards, which nothing rendered would notice going missing

    private static func source(_ file: String) throws -> String { try SourceText.fileExplorer(file) }

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
