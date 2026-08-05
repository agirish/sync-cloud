import Foundation
import Sync

/// Pure query logic behind the Differences table: the combined type-filter + text-search
/// predicate, the bulk "ignore all" set operation, and the selection-vs-filtered action
/// target set. Kept free of SwiftUI so every rule is unit-testable.
enum DifferencesQuery {
    /// A difference is visible when it matches the active type filter AND the search query — which
    /// is the structured token search (`kind:`, size, `only:`) plus free-text substring over the
    /// text the table SHOWS: `relativePath` and the anchored Path-column text. `pathRootName` is
    /// the same anchor the cells render with (no default — the caller must pass what it displays),
    /// so a user who reads "Home/Legal" in the Path column and searches "Home" finds rows instead
    /// of a silent empty result.
    static func matches(_ difference: FileDifference, filter: DifferenceFilter, searchText: String,
                        pathRootName: String?) -> Bool {
        guard filter.matches(difference) else { return false }
        return DifferenceSearch.parse(searchText).matches(difference, pathRootName: pathRootName)
    }

    /// Single O(n) pass over the whole list. The search query is parsed ONCE here (not per row) and
    /// reused, so the token grammar costs nothing per difference.
    static func filtered(_ differences: [FileDifference], filter: DifferenceFilter, searchText: String,
                         pathRootName: String?) -> [FileDifference] {
        let query = DifferenceSearch.parse(searchText)
        return differences.filter { filter.matches($0) && query.matches($0, pathRootName: pathRootName) }
    }

    /// Per-filter row counts for the filter menu (the `Identical (312)` parity ask): how many
    /// differences each `DifferenceFilter` would show, tallied in ONE pass over the whole diff so
    /// the header can label every dropdown row without running the filter predicate once per
    /// filter per render. `searchText` is intentionally ignored — the counts reflect the entire
    /// diff regardless of the search box, matching Tidy's filter menu. Filters with no matches are
    /// absent from the dictionary; read with a `0` default.
    static func counts(_ differences: [FileDifference]) -> [DifferenceFilter: Int] {
        var tally: [DifferenceFilter: Int] = [:]
        for difference in differences {
            for filter in DifferenceFilter.allCases where filter.matches(difference) {
                tally[filter, default: 0] += 1
            }
        }
        return tally
    }

    /// What the Path column prints for a row whose parent (relative to the compare roots) is
    /// `parentPath`: the compared folder's own name ("Home") for a root-level row, and
    /// "Home/Legal" for a nested one — so no row ever shows an empty location, which is exactly
    /// the row that used to be unplaceable (a single root-level file draws no section header
    /// and used to draw no prefix). `rootName` is nil or empty when the two compared folders
    /// carry DIFFERENT names — anchoring at either would misname the other side — and the text
    /// then falls back to the bare parent, with `DifferenceGrouping.rootLabel` standing in for
    /// the root itself.
    static func pathColumnText(parentPath: String, rootName: String?) -> String {
        // Engine-built relativePaths never lead with "/", but this is the second place that
        // assumption gets load-bearing (DifferenceGrouping.split records the first going wrong),
        // and here it would print "Home//Immigration". Dropping leading slashes is the whole
        // defence — cheaper than sharing the grouping's splitter for one cosmetic join.
        let parent = String(parentPath.drop(while: { $0 == "/" }))
        guard let rootName, !rootName.isEmpty else {
            return parent.isEmpty ? DifferenceGrouping.rootLabel : parent
        }
        return parent.isEmpty ? rootName : rootName + "/" + parent
    }

    /// Inserts every difference's `relativePath` into the ignore set (the bulk "Ignore all"
    /// menu action), using the exact target `DifferenceRowMenu` toggles a single row against.
    static func ignoringAll(_ differences: [FileDifference], in ignoredPaths: Set<String>) -> Set<String> {
        var updated = ignoredPaths
        for difference in differences {
            updated.insert(difference.relativePath)
        }
        return updated
    }

    /// What Space previews when it arrives at the Differences table — which, with the bottom pane
    /// open, is very nearly always, because that table holds key focus and a pane row click does
    /// not take it away.
    ///
    /// Lives here rather than on `DifferencesView` for two reasons. It is pure query logic, which
    /// is what this type is for; and a `static` on the View is `@MainActor`-isolated along with it,
    /// so calling it from a plain test traps at runtime (SIGTRAP) rather than failing to compile —
    /// a pure function has no business demanding the main actor.
    ///
    /// Split out of the `.onKeyPress` closure so the *composition* is testable and not just
    /// `CurrentSelection`'s arithmetic: the bug this fixes was never in the arithmetic, it was in
    /// which surface the app asked about. A mounted key-window test is not available here (the
    /// test host cannot make a window key), so this function is the seam that stands in for it.
    ///
    /// `rows` is the filtered+sorted table, and resolving the selection through it is load-bearing:
    /// SwiftUI's `Table` does NOT prune its selection binding when rows disappear (measured), so a
    /// difference that syncs away leaves a stale id behind. Looking the id up in `rows` yields nil
    /// for a stale one, which falls through to the pane rather than previewing a row that is no
    /// longer on screen.
    ///
    /// `singleSource` is deliberately not a parameter: `.differences` maps to `.compare` in
    /// `TopPaneVisibility.mode(for:)`, so the Tidy rail and this table can never be on screen at
    /// once and the hidden-right-pane case cannot reach here.
    static func spaceQuickLookTarget(
        lastInteracted: SelectionSurface?,
        leftSelection: Set<String>,
        rightSelection: Set<String>,
        rows: [FileDifference],
        selection: Set<FileDifference.ID>
    ) -> String? {
        CurrentSelection.quickLookPath(
            lastInteracted: lastInteracted,
            panePath: CurrentSelection.primaryPanePath(left: leftSelection, right: rightSelection),
            differencesPath: rows.first(where: { selection.contains($0.id) })?.reviewSourcePath
        )
    }
}

/// Selection-aware action targets for the header's Copy / Move / Verify buttons: the selected
/// rows when any are selected (intersected with the current filter), otherwise the whole
/// filtered list. The counts drive both the button labels and their enabled state.
///
/// Scoping note: this operates purely on the already-filtered list. `anySyncing` (which
/// disables the buttons while *any* sync is in flight, filtered out or not) stays a separate
/// read over all differences — see `DifferencesSummary`.
struct DifferenceActionTargets: Equatable {
    /// The differences the header buttons would act on.
    let targets: [FileDifference]
    /// True when a non-empty selection scoped the targets; false when acting on the full filtered set.
    let isSelectionScoped: Bool
    /// Items "Copy/Move to Right" would sync (subset of `targets`).
    let copyToRightCount: Int
    /// Items "Copy/Move to Left" would sync (subset of `targets`).
    let copyToLeftCount: Int
    /// Items "Verify" would checksum: date-only differences with matching sizes within `targets`.
    let verifiableCount: Int

    init(filtered: [FileDifference], selection: Set<FileDifference.ID>) {
        // Resolve the selection against the *visible* rows. A selection that resolves to no
        // visible row — because a rescan replaced every id with a fresh UUID, the synced rows
        // were removed from the list, or a filter now hides them all — falls back to the whole
        // filtered set, so the header keeps actionable buttons instead of going dead until the
        // next click.
        let matched = selection.isEmpty ? [] : filtered.filter { selection.contains($0.id) }
        let scoped = !matched.isEmpty
        let targets = scoped ? matched : filtered
        self.targets = targets
        self.isSelectionScoped = scoped
        // One pass for all three counts. This initializes once per Differences render, which
        // during a bulk sync happens per file over the whole filtered set, so folding three
        // reduces into a single loop drops two extra O(n) walks of the targets each frame.
        var right = 0, left = 0, verifiable = 0
        for difference in targets {
            if difference.action == .copyToRight { right += 1 }
            if difference.action == .copyToLeft { left += 1 }
            if difference.type == .differentDates && difference.sizesMatch { verifiable += 1 }
        }
        self.copyToRightCount = right
        self.copyToLeftCount = left
        self.verifiableCount = verifiable
    }

    /// The direction carrying strictly more of the targets: the header renders that copy
    /// button prominent and the other bordered, so a 559-vs-17 split shows in visual weight
    /// instead of two equal solid primaries. Nil on a tie — neither dominates, both stay
    /// prominent.
    var dominantCopyDirection: FileDifference.SyncAction? {
        if copyToRightCount > copyToLeftCount { return .copyToRight }
        if copyToLeftCount > copyToRightCount { return .copyToLeft }
        return nil
    }
}

/// Display strings and sort keys for the Differences table's four columns. Exposed as
/// computed properties on `FileDifference` so the Table's `sortOrder` (KeyPathComparator) can
/// order rows by them and the same keys stay unit-testable without SwiftUI.
extension FileDifference {
    /// The file/folder name shown in the Name column and used as the Name sort key. Sliced off the
    /// last "/" rather than `split`, since this is the sort key the Table re-reads O(n log n) times
    /// per sort — allocating a `[Substring]` array on every comparison would dominate the sort.
    var fileName: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return relativePath }
        return String(relativePath[relativePath.index(after: slash)...])
    }

    /// The Path column's display source (via `pathColumnText`) and its sort key; empty at the root.
    var parentPath: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    /// Description with the folder roll-up ("… — includes N items") appended. The Change cell
    /// shows the bare `description` and keeps this full sentence as its hover help — the count
    /// itself renders in the Size column (`enclosedItemsText`), where it can't truncate away.
    var rolledUpDescription: String {
        guard let count = enclosedItemCount, count > 0 else { return description }
        return "\(description) — includes \(count) item\(count == 1 ? "" : "s")"
    }

    /// The folder roll-up count as Size-column text ("5,301 items") — the one number that says
    /// how big a folder copy is, moved out of the flexing Change column (where it truncated
    /// mid-number) into the fixed Size column that used to show "—" for folders. Nil whenever
    /// a real byte size exists or no roll-up count is known, so files are untouched.
    var enclosedItemsText: String? {
        guard displaySize == nil, let count = enclosedItemCount, count > 0 else { return nil }
        return "\(count.formatted()) item\(count == 1 ? "" : "s")"
    }

    /// The size to show and sort by: the source side that actually exists. Folders and unknown
    /// sizes are nil (rendered "—"); as an Optional key path, nil sorts before any real size.
    var displaySize: Int? {
        switch type {
        case .missingOnRight: return leftFileSize
        case .missingOnLeft: return rightFileSize
        case .differentDates, .nameConflict: return action == .copyToRight ? leftFileSize : rightFileSize
        }
    }

    /// Non-optional Size sort key for the Table column. Unknown/folder sizes (nil) sort as `-1`,
    /// grouping them below every real size (first ascending, last descending).
    var displaySizeSort: Int {
        displaySize ?? -1
    }

    /// Stable rank for sorting the Change column by difference type.
    var changeSortRank: Int {
        switch type {
        case .missingOnLeft: return 0
        case .missingOnRight: return 1
        case .differentDates: return 2
        case .nameConflict: return 3
        }
    }

}
