import Sync

/// Pure tallies and predicates behind the DifferencesView action bar, extracted from the
/// view's computed properties so the rules are unit-testable.
///
/// Scoping rule worth knowing: the copy counts are computed over the *filtered* list because
/// the Copy/Move buttons act on that subset, while `anySyncing` and `verifiableCount` are
/// computed over *all* differences because syncing state and Verify All ignore the UI filter.
struct DifferencesSummary: Equatable {
    /// Items the "Copy N to Right" button would sync (respects the active filter).
    let copyToRightCount: Int
    /// Items the "Copy N to Left" button would sync (respects the active filter).
    let copyToLeftCount: Int
    /// True while any difference is mid-sync, filtered out or not.
    let anySyncing: Bool
    /// Items "Verify All" would checksum: date-only differences with matching sizes,
    /// regardless of the active filter.
    let verifiableCount: Int

    init(differences: [FileDifference], filter: DifferenceFilter) {
        let filtered = differences.filter { filter.matches($0) }
        copyToRightCount = filtered.filter { $0.action == .copyToRight }.count
        copyToLeftCount = filtered.filter { $0.action == .copyToLeft }.count
        anySyncing = differences.contains { $0.isSyncing }
        verifiableCount = differences.filter { $0.type == .differentDates && $0.sizesMatch }.count
    }

    /// Whether one row can offer its per-file "Verify" (checksum) action: only a date-only
    /// difference with matching sizes, and only while nothing else is verifying or syncing it.
    static func canVerify(_ difference: FileDifference, isRowVerifying: Bool, isVerifyAllInProgress: Bool) -> Bool {
        difference.type == .differentDates
            && difference.sizesMatch
            && !difference.isSyncing
            && !isRowVerifying
            && !isVerifyAllInProgress
    }
}
