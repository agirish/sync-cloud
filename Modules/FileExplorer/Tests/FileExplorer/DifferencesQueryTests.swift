import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Coverage for the pure query logic behind the Differences table: the combined
/// type-filter + text-search predicate, the sort keys the Table's columns order by, the
/// selection-vs-filtered action targets, and the bulk "ignore all" set operation.
@Suite struct DifferencesQueryTests {

    private func diff(
        _ relativePath: String,
        id: UUID = UUID(),
        type: FileDifference.DifferenceType = .missingOnRight,
        action: FileDifference.SyncAction = .copyToRight,
        isSyncing: Bool = false,
        leftSize: Int? = nil,
        rightSize: Int? = nil,
        enclosedItemCount: Int? = nil,
        description: String = "test"
    ) -> FileDifference {
        FileDifference(
            id: id,
            relativePath: relativePath,
            leftItemPath: "/l/\(relativePath)",
            rightItemPath: "/r/\(relativePath)",
            type: type,
            action: action,
            description: description,
            isSyncing: isSyncing,
            leftFileSize: leftSize,
            rightFileSize: rightSize,
            enclosedItemCount: enclosedItemCount
        )
    }

    // MARK: Filter + search predicate

    @Test func testEmptySearchPassesEverythingMatchingTheFilter() {
        let d = diff("docs/report.txt")
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: ""))
        // Empty search must not narrow the list at all.
        let list = [diff("a"), diff("b/c"), diff("d/e/f")]
        #expect(DifferencesQuery.filtered(list, filter: .all, searchText: "").count == 3)
    }

    @Test func testSearchIsCaseInsensitiveSubstringOfRelativePath() {
        let d = diff("Docs/Report.txt")
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "report"))
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "DOCS"))
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "s/R"))
        #expect(!DifferencesQuery.matches(d, filter: .all, searchText: "missing"))
    }

    @Test func testFilterAndSearchAreCombinedWithAnd() {
        // A missing-on-left item fails the missing-on-right filter regardless of search text.
        let d = diff("docs/report.txt", type: .missingOnLeft, action: .copyToLeft)
        #expect(!DifferencesQuery.matches(d, filter: .missingOnRight, searchText: "report"))
        // Passes the filter but the search excludes it.
        let onRight = diff("docs/report.txt", type: .missingOnRight)
        #expect(!DifferencesQuery.matches(onRight, filter: .missingOnRight, searchText: "budget"))
        // Passes both.
        #expect(DifferencesQuery.matches(onRight, filter: .missingOnRight, searchText: "report"))
    }

    @Test func testFilteredCombinesBothInOnePass() {
        let list = [
            diff("keep/report.txt", type: .missingOnRight),
            diff("keep/budget.txt", type: .missingOnRight),
            diff("skip/report.txt", type: .missingOnLeft, action: .copyToLeft),
        ]
        let result = DifferencesQuery.filtered(list, filter: .missingOnRight, searchText: "report")
        #expect(result.map(\.relativePath) == ["keep/report.txt"])
    }

    // MARK: Sort keys (driven by the Table's KeyPathComparator sortOrder)

    @Test func testNameSortAscendingAndDescending() {
        let list = [diff("z/apple.txt"), diff("a/mango.txt"), diff("m/banana.txt")]
        let asc = list.sorted(using: [KeyPathComparator(\.fileName, comparator: .localizedStandard, order: .forward)])
        #expect(asc.map(\.fileName) == ["apple.txt", "banana.txt", "mango.txt"])
        let desc = list.sorted(using: [KeyPathComparator(\.fileName, comparator: .localizedStandard, order: .reverse)])
        #expect(desc.map(\.fileName) == ["mango.txt", "banana.txt", "apple.txt"])
    }

    @Test func testNameSortIsCaseInsensitiveAndNumberAware() {
        // The Name column sorts with `.localizedStandard` (Finder-style): case doesn't shove
        // capitals above lowercase, and numbers order numerically (File2 before File10).
        let list = [diff("z/File2.txt"), diff("z/file10.txt"), diff("z/apple.txt"), diff("z/File1.txt")]
        let asc = list.sorted(using: [KeyPathComparator(\.fileName, comparator: .localizedStandard, order: .forward)])
        #expect(asc.map(\.fileName) == ["apple.txt", "File1.txt", "File2.txt", "file10.txt"])
    }

    @Test func testSizeSortHandlesUnknownSizes() {
        let list = [
            diff("big", leftSize: 5000),
            diff("folder", enclosedItemCount: 3),   // no byte size -> unknown
            diff("small", leftSize: 10),
        ]
        let asc = list.sorted(using: [KeyPathComparator(\.displaySizeSort, order: .forward)])
        // Unknown sizes (-1) sort below every real size.
        #expect(asc.map(\.relativePath) == ["folder", "small", "big"])
        let desc = list.sorted(using: [KeyPathComparator(\.displaySizeSort, order: .reverse)])
        #expect(desc.map(\.relativePath) == ["big", "small", "folder"])
    }

    @Test func testChangeSortGroupsTheThreeTypesStably() {
        let list = [
            diff("a", type: .differentDates, action: .copyToRight, leftSize: 1, rightSize: 1),
            diff("b", type: .missingOnRight),
            diff("c", type: .missingOnLeft, action: .copyToLeft),
            diff("d", type: .differentDates, action: .copyToRight, leftSize: 1, rightSize: 1),
        ]
        let asc = list.sorted(using: [KeyPathComparator(\.changeSortRank, order: .forward)])
        // Rank order: missingOnLeft (0), missingOnRight (1), differentDates (2); within a type,
        // input order is preserved (stable sort), so the two date diffs stay a-before-d.
        #expect(asc.map(\.relativePath) == ["c", "b", "a", "d"])
    }

    @Test func testCopyToSortOrdersByAction() {
        let list = [
            diff("r1", type: .missingOnRight, action: .copyToRight),
            diff("l1", type: .missingOnLeft, action: .copyToLeft),
            diff("r2", type: .missingOnRight, action: .copyToRight),
        ]
        let asc = list.sorted(using: [KeyPathComparator(\.copyToSortRank, order: .forward)])
        // copyToLeft (0) before copyToRight (1); stable within each action.
        #expect(asc.map(\.relativePath) == ["l1", "r1", "r2"])
    }

    // MARK: Display helpers

    @Test func testFileNameAndParentPathSplit() {
        let nested = diff("a/b/c.txt")
        #expect(nested.fileName == "c.txt")
        #expect(nested.parentPath == "a/b")
        let root = diff("top.txt")
        #expect(root.fileName == "top.txt")
        #expect(root.parentPath == "")
    }

    @Test func testDisplaySizeUsesTheSourceSide() {
        #expect(diff("x", type: .missingOnRight, leftSize: 100, rightSize: 200).displaySize == 100)
        #expect(diff("x", type: .missingOnLeft, action: .copyToLeft, leftSize: 100, rightSize: 200).displaySize == 200)
        #expect(diff("x", type: .differentDates, action: .copyToRight, leftSize: 100, rightSize: 200).displaySize == 100)
        #expect(diff("x", type: .differentDates, action: .copyToLeft, leftSize: 100, rightSize: 200).displaySize == 200)
    }

    @Test func testUnknownSizeIsNilAndSortsAsNegativeOne() {
        // Folders/unknown sizes are nil (the cell renders "—") and sort below every real size.
        let folder = diff("folder", enclosedItemCount: 4)
        #expect(folder.displaySize == nil)
        #expect(folder.displaySizeSort == -1)
    }

    @Test func testRolledUpDescriptionAppendsFolderCount() {
        #expect(diff("f", enclosedItemCount: 3, description: "Missing on right").rolledUpDescription
            == "Missing on right — includes 3 items")
        #expect(diff("f", enclosedItemCount: 1, description: "Missing on right").rolledUpDescription
            == "Missing on right — includes 1 item")
        // No roll-up when there is no enclosed count.
        #expect(diff("f", description: "Missing on right").rolledUpDescription == "Missing on right")
        #expect(diff("f", enclosedItemCount: 0, description: "Missing on right").rolledUpDescription == "Missing on right")
    }

    // MARK: Selection-driven action targets

    @Test func testEmptySelectionTargetsTheWholeFilteredSet() {
        let filtered = [
            diff("a", action: .copyToRight),
            diff("b", type: .missingOnLeft, action: .copyToLeft),
            diff("c", type: .differentDates, action: .copyToRight, leftSize: 5, rightSize: 5),
        ]
        let targets = DifferenceActionTargets(filtered: filtered, selection: [])
        #expect(!targets.isSelectionScoped)
        #expect(targets.targets.count == 3)
        #expect(targets.copyToRightCount == 2)
        #expect(targets.copyToLeftCount == 1)
        #expect(targets.verifiableCount == 1)
    }

    @Test func testNonEmptySelectionTargetsTheIntersectionWithFiltered() {
        let a = diff("a", action: .copyToRight)
        let b = diff("b", type: .missingOnLeft, action: .copyToLeft)
        let c = diff("c", action: .copyToRight)
        let filtered = [a, b, c]
        let targets = DifferenceActionTargets(filtered: filtered, selection: [a.id, b.id])
        #expect(targets.isSelectionScoped)
        #expect(Set(targets.targets.map(\.relativePath)) == ["a", "b"])
        #expect(targets.copyToRightCount == 1)
        #expect(targets.copyToLeftCount == 1)
    }

    @Test func testSelectionMatchingNoVisibleRowFallsBackToFilteredSet() {
        // A selection that resolves to no visible row — a rescan replaced every id, the synced
        // rows were removed, or a filter now hides them — must fall back to the full filtered
        // set so the header keeps actionable buttons instead of going dead.
        let visible = diff("visible", action: .copyToRight)
        let stale = diff("stale", action: .copyToRight)
        let targets = DifferenceActionTargets(filtered: [visible], selection: [stale.id])
        #expect(!targets.isSelectionScoped)
        #expect(targets.targets.map(\.relativePath) == ["visible"])
        #expect(targets.copyToRightCount == 1)
    }

    @Test func testPartlyStaleSelectionKeepsOnlyVisibleRows() {
        // One selected row is gone (e.g. already synced and dropped), one is still visible:
        // stay scoped to the surviving visible row.
        let a = diff("a", action: .copyToRight)
        let removed = diff("removed", action: .copyToRight)
        let targets = DifferenceActionTargets(filtered: [a], selection: [a.id, removed.id])
        #expect(targets.isSelectionScoped)
        #expect(targets.targets.map(\.relativePath) == ["a"])
        #expect(targets.copyToRightCount == 1)
    }

    @Test func testVerifiableCountRequiresDateTypeAndMatchingSizes() {
        let filtered = [
            diff("match", type: .differentDates, action: .copyToRight, leftSize: 10, rightSize: 10),
            diff("mismatch", type: .differentDates, action: .copyToRight, leftSize: 10, rightSize: 20),
            diff("missing", type: .missingOnRight, leftSize: 10, rightSize: 10),
        ]
        let targets = DifferenceActionTargets(filtered: filtered, selection: [])
        #expect(targets.verifiableCount == 1)
    }

    // MARK: Bulk ignore

    @Test func testIgnoringAllInsertsEveryRelativePath() {
        let selected = [diff("a/x.txt"), diff("b/y.txt")]
        let updated = DifferencesQuery.ignoringAll(selected, in: ["keep"])
        #expect(updated == ["keep", "a/x.txt", "b/y.txt"])
        // The inserted targets satisfy the same predicate applyFilters() drops rows by.
        #expect(FileSyncManager.isIgnoredPath("a/x.txt", ignored: updated))
    }
}
