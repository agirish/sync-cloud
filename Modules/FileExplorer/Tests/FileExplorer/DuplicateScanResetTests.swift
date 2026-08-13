import Testing
@testable import FileExplorer

/// Pins what a fresh Duplicates scan retires. The rule is "nothing aimed at the previous results
/// survives into the new ones", and it was broken by omission: the search query and the reclaim
/// tally were cleared on scan start but the type filter was not, so a "Versions" pick silently
/// pre-filtered the next scan — showing a partial list with no visible cause, or the "Nothing
/// matches" dead end, which blames the *search* and offers to clear one that isn't even set.
@Suite struct DuplicateScanResetTests {

    @Test func aFreshDuplicatesScanClearsEveryNarrowing() {
        var filter: DuplicateMatchFilter = .versions
        var query = "kind:pdf"
        var reclaim = ReclaimTally()
        reclaim.credit(4_096)

        DuplicateScanReset.duplicatesScanStarted(filter: &filter, searchQuery: &query, reclaim: &reclaim)

        // The filter is the one that used to survive — a scan whose results are pre-narrowed by a
        // choice made against the PREVIOUS scan is a lie about what it found.
        #expect(filter == .all)
        #expect(query.isEmpty)
        // "… freed this session" must only ever count the current results' work (H5).
        #expect(reclaim.totalBytes == 0)
    }

    @Test func resettingAnAlreadyCleanSessionIsANoOp() {
        var filter: DuplicateMatchFilter = .all
        var query = ""
        var reclaim = ReclaimTally()

        DuplicateScanReset.duplicatesScanStarted(filter: &filter, searchQuery: &query, reclaim: &reclaim)

        #expect(filter == .all)
        #expect(query.isEmpty)
        #expect(reclaim.totalBytes == 0)
    }

    /// The filter reset has to hold for every kind, not just the one that prompted the report —
    /// each of these hides most groups, and any of them surviving a rescan is the same defect.
    @Test func everyFilterKindIsRetiredByAScan() {
        for stale: DuplicateMatchFilter in DuplicateMatchFilter.allCases {
            var filter = stale
            var query = ""
            var reclaim = ReclaimTally()
            DuplicateScanReset.duplicatesScanStarted(filter: &filter, searchQuery: &query, reclaim: &reclaim)
            #expect(filter == .all, "\(stale) survived a fresh scan")
        }
    }
}
