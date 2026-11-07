import Testing
@testable import FileExplorer

/// Pins what a fresh Duplicates scan retires: nothing aimed at the previous results survives into
/// the new ones. A surviving type filter would pre-filter the next scan, showing a partial list
/// with no visible cause, or a "Nothing matches" that blames a search that isn't set.
@Suite struct DuplicateScanResetTests {

    @Test func aFreshDuplicatesScanClearsEveryNarrowing() {
        var filter: DuplicateMatchFilter = .versions
        var query = "kind:pdf"
        var reclaim = ReclaimTally()
        reclaim.credit(4_096)

        DuplicateScanReset.duplicatesScanStarted(filter: &filter, searchQuery: &query, reclaim: &reclaim)

        // Results pre-narrowed by a choice made against the previous scan misstate what it found.
        #expect(filter == .all)
        #expect(query.isEmpty)
        // "… freed this session" must only ever count the current results' work.
        #expect(reclaim.totalBytes == 0)
    }

    /// The reset holds for every filter kind: each hides most groups, so any one surviving a rescan
    /// is the same defect. The `.all` pass is a clean session, which the reset leaves clean.
    @Test func everyFilterKindIsRetiredByAScan() {
        for stale: DuplicateMatchFilter in DuplicateMatchFilter.allCases {
            var filter = stale
            var query = ""
            var reclaim = ReclaimTally()
            DuplicateScanReset.duplicatesScanStarted(filter: &filter, searchQuery: &query, reclaim: &reclaim)
            #expect(filter == .all, "\(stale) survived a fresh scan")
            #expect(query.isEmpty && reclaim.totalBytes == 0)
        }
    }
}
