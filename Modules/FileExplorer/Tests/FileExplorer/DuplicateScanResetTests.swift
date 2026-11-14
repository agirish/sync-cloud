import Testing
@testable import FileExplorer

/// Pins what a fresh Duplicates scan retires: nothing aimed at the previous results survives into
/// the new ones. A surviving type filter would pre-filter the next scan, showing a partial list
/// with no visible cause, or a "Nothing matches" that blames a search that isn't set.
@Suite struct DuplicateScanResetTests {

    /// Every filter kind, each with a stale search and session credit: each filter hides most
    /// groups, so any one surviving a rescan is the same defect, and "… freed this session" must
    /// only ever count the current results' work.
    @Test func aFreshDuplicatesScanClearsEveryNarrowing() {
        for stale: DuplicateMatchFilter in DuplicateMatchFilter.allCases {
            var filter = stale
            var query = "kind:pdf"
            var reclaim = ReclaimTally()
            reclaim.credit(4_096)
            DuplicateScanReset.duplicatesScanStarted(filter: &filter, searchQuery: &query, reclaim: &reclaim)
            #expect(filter == .all, "\(stale) survived a fresh scan")
            #expect(query.isEmpty)
            #expect(reclaim.totalBytes == 0)
        }
    }
}
