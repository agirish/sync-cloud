import Foundation
import Sync

/// Pure query logic behind the Differences table: the combined type-filter + text-search
/// predicate, the bulk "ignore all" set operation, and the selection-vs-filtered action
/// target set. Kept free of SwiftUI so every rule is unit-testable.
enum DifferencesQuery {
    /// A difference is visible when it matches the type filter and the search query: tokens
    /// (`kind:`, size, `only:`) plus free text over what the table shows, `relativePath` and the
    /// anchored Path-column text. `pathRootName` is the anchor the cells render with, with no
    /// default, so searching "Home" finds the rows whose Path column reads "Home/Legal".
    static func matches(_ difference: FileDifference, filter: DifferenceFilter, searchText: String,
                        pathRootName: String?, failedIDs: Set<UUID>) -> Bool {
        guard filter.matches(difference, failedIDs: failedIDs) else { return false }
        return DifferenceSearch.parse(searchText).matches(difference, pathRootName: pathRootName)
    }

    /// One O(n) pass over the whole list, with the query parsed once rather than per row.
    static func filtered(_ differences: [FileDifference], filter: DifferenceFilter, searchText: String,
                         pathRootName: String?, failedIDs: Set<UUID>) -> [FileDifference] {
        let query = DifferenceSearch.parse(searchText)
        return differences.filter {
            filter.matches($0, failedIDs: failedIDs) && query.matches($0, pathRootName: pathRootName)
        }
    }

    /// Per-filter row counts for the filter menu, tallied in one pass so the header can label every
    /// row without running each filter per render. The search is ignored on purpose: the counts
    /// cover the whole diff, as the Duplicates lens's menu does. Filters with no matches are
    /// absent; read with a `0` default.
    static func counts(_ differences: [FileDifference], failedIDs: Set<UUID>) -> [DifferenceFilter: Int] {
        var tally: [DifferenceFilter: Int] = [:]
        for difference in differences {
            for filter in DifferenceFilter.allCases where filter.matches(difference, failedIDs: failedIDs) {
                tally[filter, default: 0] += 1
            }
        }
        return tally
    }

    /// What the Path column prints for a row whose parent (relative to the compare roots) is
    /// `parentPath`: the compared folder's name ("Home") at the root, "Home/Legal" when nested, so
    /// no row shows an empty location. `rootName` is nil or empty when the two compared folders
    /// have different names, since either would misname the other side; the text is then the bare
    /// parent, with `DifferenceGrouping.rootLabel` for the root itself.
    static func pathColumnText(parentPath: String, rootName: String?) -> String {
        // Engine-built relativePaths never lead with "/", but one would print "Home//Immigration"
        // here, so drop leading slashes.
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

    /// What Space previews when it arrives at the Differences table, which is nearly always with
    /// the bottom pane open: the table holds key focus and a pane row click doesn't take it.
    ///
    /// **Not on `DifferencesView`:** a `static` there is `@MainActor`-isolated, and calling it from
    /// a plain test traps at runtime (SIGTRAP) instead of failing to compile. Split out of the
    /// `.onKeyPress` closure so tests can check which surface is asked, since the test host can't
    /// make a window key.
    ///
    /// `rows` is the filtered, sorted table. **`Table` doesn't prune its selection binding when
    /// rows disappear**, so a row that syncs away leaves a stale id; looking it up in `rows` yields
    /// nil and falls through to the pane. No `singleSource` parameter: `.differences` maps to
    /// `.compare` in `TopPaneVisibility.mode(for:)`, so the single-source rail is never on screen
    /// with this table.
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
/// Works on the already-filtered list. `anySyncing`, which disables the buttons while any sync is
/// in flight, filtered out or not, is a separate read over all differences (`DifferencesSummary`).
struct DifferenceActionTargets: Equatable {
    /// The differences the header buttons would act on.
    let targets: [FileDifference]
    /// True when a non-empty selection scoped the targets; false when acting on the full filtered set.
    let isSelectionScoped: Bool
    /// Items "Copy/Move to Right" would sync (subset of `targets`) — `transferItems(.copyToRight)`.
    let copyToRightCount: Int
    /// Items "Copy/Move to Left" would sync (subset of `targets`) — `transferItems(.copyToLeft)`.
    let copyToLeftCount: Int
    /// Items "Verify" would checksum: date-only differences with matching sizes within `targets`.
    let verifiableCount: Int
    /// Held rows within `targets` (`FileDifference.heldBack`), either direction: the rows no Copy or
    /// Move here takes, which the header counts out loud (`heldText`) so they are not simply absent.
    let heldCount: Int

    init(filtered: [FileDifference], selection: Set<FileDifference.ID>) {
        // Resolve the selection against the visible rows. One that matches none (a rescan gave
        // fresh ids, synced rows left the list, a filter hides them) falls back to the whole
        // filtered set, so the header's buttons don't go dead until the next click.
        let matched = selection.isEmpty ? [] : filtered.filter { selection.contains($0.id) }
        let scoped = !matched.isEmpty
        let targets = scoped ? matched : filtered
        self.targets = targets
        self.isSelectionScoped = scoped
        // One pass for every count: this runs once per Differences render, which during a bulk
        // sync is once per file over the whole filtered set.
        var right = 0, left = 0, verifiable = 0, held = 0
        for difference in targets {
            if Self.headerTransfers(difference, .copyToRight) { right += 1 }
            if Self.headerTransfers(difference, .copyToLeft) { left += 1 }
            if difference.type == .differentDates && difference.sizesMatch { verifiable += 1 }
            if difference.heldBack != nil { held += 1 }
        }
        self.copyToRightCount = right
        self.copyToLeftCount = left
        self.verifiableCount = verifiable
        self.heldCount = held
    }

    /// What the header says about the held rows it won't copy ("2 need your decision"), or nil
    /// when there are none, so held rows are never silently absent from "Copy 3 →".
    var heldText: String? {
        switch heldCount {
        case 0: return nil
        case 1: return "1 needs your decision"
        default: return "\(heldCount) need your decision"
        }
    }

    /// The held rows a Copy/Move in `direction` leaves out, handed to the run beside
    /// `transferItems` so its banner can say how many it left and why (`FileSyncManager.syncAll`
    /// filters them out itself and names them).
    func heldItems(_ direction: FileDifference.SyncAction) -> [FileDifference] {
        targets.filter { $0.action == direction && $0.heldBack != nil }
    }

    /// What the header's Copy/Move in `direction` acts on: the rows its count counts.
    ///
    /// **A held row is never among them** (`FileDifference.heldBack`): its direction is the user's
    /// call, and with one row targeted the header goes through `syncFile`, which copies whatever
    /// it is handed. A held row is copied from its own right-click menu
    /// (`DifferenceRowMenu.copyDirections`), or selected alone with ⌘← / ⌘→ the way its guess
    /// points; ⌘→ and the bulk menu over a larger selection leave it out too
    /// (`DifferencesShortcutRules.transferItems`).
    func transferItems(_ direction: FileDifference.SyncAction) -> [FileDifference] {
        targets.filter { Self.headerTransfers($0, direction) }
    }

    /// The one rule behind both the counts and `transferItems`, so the label cannot promise a
    /// different set than the button sends.
    private static func headerTransfers(_ difference: FileDifference, _ direction: FileDifference.SyncAction) -> Bool {
        difference.action == direction && difference.heldBack == nil
    }

    /// The direction carrying strictly more of the targets: the header draws that copy button
    /// prominent and the other bordered, so a lopsided split shows in visual weight. Nil on a tie,
    /// where both stay prominent.
    var dominantCopyDirection: FileDifference.SyncAction? {
        if copyToRightCount > copyToLeftCount { return .copyToRight }
        if copyToLeftCount > copyToRightCount { return .copyToLeft }
        return nil
    }
}

/// How Review's "Copy Remaining N" sends what is still pending: one decided row through
/// `syncFile` (whose failure alert carries Retry), anything else through `syncAll`.
///
/// A held row never takes the single path: `syncFile(confirmed: true)` would copy it, while
/// `syncAll` leaves held rows out and names them. So one held row goes to `syncAll` too, and the
/// button never decides a guess by how many rows are left.
enum CopyRemainingRoute: Equatable {
    case single(FileDifference)
    case bulk

    static func route(_ remaining: [FileDifference]) -> CopyRemainingRoute {
        if remaining.count == 1, let only = remaining.first, only.heldBack == nil { return .single(only) }
        return .bulk
    }

    /// The N the button names: the pending rows it will copy, the held ones left out.
    static func copyableCount(_ remaining: [FileDifference]) -> Int {
        remaining.filter { $0.heldBack == nil }.count
    }
}

/// Display strings and sort keys for the Differences table's four columns. Exposed as
/// computed properties on `FileDifference` so the Table's `sortOrder` (KeyPathComparator) can
/// order rows by them and the same keys stay unit-testable without SwiftUI.
extension FileDifference {
    /// The file or folder name in the Name column, and its sort key. Sliced at the last "/" rather
    /// than `split`, since the Table reads it O(n log n) times per sort and an array per
    /// comparison would dominate.
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
    /// shows the bare `description` with this as its hover help; the count itself is in the Size
    /// column (`enclosedItemsText`), where it can't truncate away.
    var rolledUpDescription: String {
        guard let count = enclosedItemCount, count > 0 else { return description }
        return "\(description) — includes \(count) item\(count == 1 ? "" : "s")"
    }

    /// The folder roll-up count as Size-column text ("5,301 items"), the number that says how big
    /// a folder copy is, in the fixed-width column where it can't truncate. Nil when a real byte
    /// size exists or no count is known, so files are untouched.
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
