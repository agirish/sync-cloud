import Foundation
import Sync

/// Pure query logic behind the Differences table: the combined type-filter + text-search
/// predicate, the bulk "ignore all" set operation, and the selection-vs-filtered action
/// target set. Kept free of SwiftUI so every rule is unit-testable.
enum DifferencesQuery {
    /// A difference is visible when it matches the active type filter AND (the search box is
    /// empty OR its `relativePath` contains the search text, case-insensitively).
    static func matches(_ difference: FileDifference, filter: DifferenceFilter, searchText: String) -> Bool {
        guard filter.matches(difference) else { return false }
        if searchText.isEmpty { return true }
        return difference.relativePath.range(of: searchText, options: .caseInsensitive) != nil
    }

    /// Single O(n) pass applying `matches` to the whole list — mirrors the one pass the view
    /// makes per render.
    static func filtered(_ differences: [FileDifference], filter: DifferenceFilter, searchText: String) -> [FileDifference] {
        differences.filter { matches($0, filter: filter, searchText: searchText) }
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

    /// The parent-path prefix dimmed ahead of the filename in the Name cell; empty at the root.
    var parentPath: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    /// Description with the folder roll-up ("… — includes N items") appended, shown in the
    /// Change column. Mirrors the former `DifferenceRow.descriptionText`.
    var rolledUpDescription: String {
        guard let count = enclosedItemCount, count > 0 else { return description }
        return "\(description) — includes \(count) item\(count == 1 ? "" : "s")"
    }

    /// The size to show and sort by: the source side that actually exists. Folders and unknown
    /// sizes are nil (rendered "—"); as an Optional key path, nil sorts before any real size.
    var displaySize: Int? {
        switch type {
        case .missingOnRight: return leftFileSize
        case .missingOnLeft: return rightFileSize
        case .differentDates: return action == .copyToRight ? leftFileSize : rightFileSize
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
        }
    }

    /// Rank for sorting the Copy-to column by direction.
    var copyToSortRank: Int {
        switch action {
        case .copyToLeft: return 0
        case .copyToRight: return 1
        }
    }
}
