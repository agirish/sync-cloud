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
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "", failedIDs: []))
        // Empty search must not narrow the list at all.
        let list = [diff("a"), diff("b/c"), diff("d/e/f")]
        #expect(DifferencesQuery.filtered(list, filter: .all, searchText: "", failedIDs: []).count == 3)
    }

    @Test func testSearchIsCaseInsensitiveSubstringOfRelativePath() {
        let d = diff("Docs/Report.txt")
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "report", failedIDs: []))
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "DOCS", failedIDs: []))
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "s/R", failedIDs: []))
        #expect(!DifferencesQuery.matches(d, filter: .all, searchText: "missing", failedIDs: []))
    }

    @Test func testFilterAndSearchAreCombinedWithAnd() {
        // A missing-on-left item fails the missing-on-right filter regardless of search text.
        let d = diff("docs/report.txt", type: .missingOnLeft, action: .copyToLeft)
        #expect(!DifferencesQuery.matches(d, filter: .missingOnRight, searchText: "report", failedIDs: []))
        // Passes the filter but the search excludes it.
        let onRight = diff("docs/report.txt", type: .missingOnRight)
        #expect(!DifferencesQuery.matches(onRight, filter: .missingOnRight, searchText: "budget", failedIDs: []))
        // Passes both.
        #expect(DifferencesQuery.matches(onRight, filter: .missingOnRight, searchText: "report", failedIDs: []))
    }

    @Test func testFilteredCombinesBothInOnePass() {
        let list = [
            diff("keep/report.txt", type: .missingOnRight),
            diff("keep/budget.txt", type: .missingOnRight),
            diff("skip/report.txt", type: .missingOnLeft, action: .copyToLeft),
        ]
        let result = DifferencesQuery.filtered(list, filter: .missingOnRight, searchText: "report", failedIDs: [])
        #expect(result.map(\.relativePath) == ["keep/report.txt"])
    }

    // MARK: Per-filter menu counts

    @Test func testCountsTalliesEachFilterAndAllEqualsTotal() {
        let list = [
            diff("a", type: .missingOnRight, action: .copyToRight),
            diff("b", type: .missingOnRight, action: .copyToRight),
            diff("c", type: .missingOnLeft, action: .copyToLeft),
            diff("d", type: .differentDates, action: .copyToRight, leftSize: 1, rightSize: 1),
            diff("e", type: .differentDates, action: .copyToLeft, leftSize: 1, rightSize: 1),
            diff("f", type: .nameConflict, action: .copyToRight),
        ]
        let counts = DifferencesQuery.counts(list, failedIDs: [])
        #expect(counts[.all] == 6)
        #expect(counts[.missingOnRight] == 2)
        #expect(counts[.missingOnLeft] == 1)
        #expect(counts[.changedCopyToRight] == 1)
        #expect(counts[.changedCopyToLeft] == 1)
        #expect(counts[.nameConflicts] == 1)
        // The SHAPE filters partition the whole diff: they sum to `.all`. `.failed` is excluded
        // because it is not one of them — it asks what happened to a row rather than what the row
        // is, so a failed missing-on-right row is counted by both and the sum would exceed the
        // total. (It contributes 0 here anyway; excluding it by name states the rule rather than
        // relying on this fixture's empty failure set to hide the overlap.)
        let shapeSum = DifferenceFilter.allCases
            .filter { $0 != .all && $0 != .failed }
            .reduce(0) { $0 + (counts[$1] ?? 0) }
        #expect(shapeSum == counts[.all])
    }

    // MARK: The Failed filter

    /// The Failed filter selects exactly the ids the last bulk run could not transfer — and
    /// nothing else. The fixture deliberately makes the failed row IDENTICAL in shape to a
    /// passing one, so a rule that matched on `type` instead of on the id set cannot pass.
    @Test func testFailedFilterSelectsOnlyTheFailedRows() {
        let failed = diff("a", type: .missingOnRight)
        let sameShape = diff("b", type: .missingOnRight)
        let list = [failed, sameShape]

        let result = DifferencesQuery.filtered(list, filter: .failed, searchText: "",
                                               failedIDs: [failed.id])
        #expect(result.map(\.relativePath) == ["a"])
    }

    /// A stale set — every id regenerated by a rescan — selects nothing rather than resurrecting
    /// rows. That is what makes ids the right thing to store: the failure mode of forgetting to
    /// invalidate is an empty filter, not a wrong one.
    @Test func testFailedFilterWithUnknownIDsMatchesNothing() {
        let list = [diff("a"), diff("b")]
        let result = DifferencesQuery.filtered(list, filter: .failed, searchText: "",
                                               failedIDs: [UUID()])
        #expect(result.isEmpty)
    }

    /// The count the menu badges, and the gate that decides whether the row is offered at all.
    @Test func testFailedCountDrivesWhetherTheFilterIsOffered() {
        let failed = diff("a")
        let counts = DifferencesQuery.counts([failed, diff("b")], failedIDs: [failed.id])
        #expect(counts[.failed] == 1)
        #expect(DifferenceFilter.failed.isOffered(failedCount: 1))
        #expect(!DifferenceFilter.failed.isOffered(failedCount: 0))
        // ...and no OTHER filter is ever withheld, including at zero — a menu whose entries come
        // and go is harder to use than one with zeroes in it.
        for filter in DifferenceFilter.allCases where filter != .failed {
            #expect(filter.isOffered(failedCount: 0), "\(filter) must stay listed at zero")
        }
    }

    /// The Failed filter still ANDs with the search box, like every other filter — it narrows the
    /// same list rather than escaping the query.
    @Test func testFailedFilterCombinesWithSearch() {
        let a = diff("keep/report.txt")
        let b = diff("keep/budget.txt")
        let result = DifferencesQuery.filtered([a, b], filter: .failed, searchText: "report",
                                               failedIDs: [a.id, b.id])
        #expect(result.map(\.relativePath) == ["keep/report.txt"])
    }

    @Test func testCountsIgnoresSearchTextAndEmptyListYieldsZeroes() {
        // Counts reflect the whole diff (search is not a parameter), matching Tidy's menu.
        #expect(DifferencesQuery.counts([], failedIDs: []).isEmpty)
        // A single filter's count matches `filtered` with an empty search over the same list.
        let list = [
            diff("keep/report.txt", type: .missingOnRight),
            diff("skip/report.txt", type: .missingOnLeft, action: .copyToLeft),
        ]
        let counts = DifferencesQuery.counts(list, failedIDs: [])
        #expect(counts[.missingOnRight, default: 0]
            == DifferencesQuery.filtered(list, filter: .missingOnRight, searchText: "", failedIDs: []).count)
        #expect(counts[.all, default: 0] == list.count)
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

    @Test func testEnclosedItemsTextOnlyForFolderRollups() {
        // Folder roll-ups render their count in the Size column ("N items").
        #expect(diff("folder", enclosedItemCount: 3).enclosedItemsText == "3 items")
        #expect(diff("folder", enclosedItemCount: 1).enclosedItemsText == "1 item")
        // Grouped digits match Int.formatted() (locale-dependent, so compare against it).
        #expect(diff("folder", enclosedItemCount: 5301).enclosedItemsText == "\(5301.formatted()) items")
        // A real byte size always wins; files and unknown folders stay nil (the cell's "—").
        #expect(diff("file", leftSize: 2048, enclosedItemCount: 3).enclosedItemsText == nil)
        #expect(diff("file", leftSize: 2048).enclosedItemsText == nil)
        #expect(diff("folder").enclosedItemsText == nil)
        #expect(diff("folder", enclosedItemCount: 0).enclosedItemsText == nil)
    }

    // MARK: Bulk chip direction (row chips quiet when they match the list majority)

    @Test func testBulkCopyDirectionIsTheStrictMajority() {
        let rightHeavy = [
            diff("a", action: .copyToRight),
            diff("b", action: .copyToRight),
            diff("c", type: .missingOnLeft, action: .copyToLeft),
        ]
        #expect(DifferencesQuery.bulkCopyDirection(rightHeavy) == .copyToRight)
        let leftHeavy = [
            diff("a", type: .missingOnLeft, action: .copyToLeft),
            diff("b", type: .missingOnLeft, action: .copyToLeft),
            diff("c", action: .copyToRight),
        ]
        #expect(DifferencesQuery.bulkCopyDirection(leftHeavy) == .copyToLeft)
        // A single-direction list is trivially its own bulk.
        #expect(DifferencesQuery.bulkCopyDirection([diff("a", action: .copyToRight)]) == .copyToRight)
    }

    @Test func testBulkCopyDirectionIsNilOnTieOrEmpty() {
        // No majority → nil, every chip renders at full weight.
        let tie = [diff("a", action: .copyToRight), diff("b", type: .missingOnLeft, action: .copyToLeft)]
        #expect(DifferencesQuery.bulkCopyDirection(tie) == nil)
        #expect(DifferencesQuery.bulkCopyDirection([]) == nil)
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

    @Test func testDominantCopyDirectionFollowsTheLargerCount() {
        // The header renders the dominant direction's button prominent, the other bordered.
        let rightHeavy = [
            diff("a", action: .copyToRight),
            diff("b", action: .copyToRight),
            diff("c", type: .missingOnLeft, action: .copyToLeft),
        ]
        #expect(DifferenceActionTargets(filtered: rightHeavy, selection: []).dominantCopyDirection == .copyToRight)
        let leftHeavy = [
            diff("a", type: .missingOnLeft, action: .copyToLeft),
            diff("b", type: .missingOnLeft, action: .copyToLeft),
            diff("c", action: .copyToRight),
        ]
        #expect(DifferenceActionTargets(filtered: leftHeavy, selection: []).dominantCopyDirection == .copyToLeft)
    }

    @Test func testDominantCopyDirectionIsNilOnTieAndFollowsTheSelectionScope() {
        // Tie → nil: neither direction dominates, both buttons stay prominent.
        let tie = [diff("a", action: .copyToRight), diff("b", type: .missingOnLeft, action: .copyToLeft)]
        #expect(DifferenceActionTargets(filtered: tie, selection: []).dominantCopyDirection == nil)
        #expect(DifferenceActionTargets(filtered: [], selection: []).dominantCopyDirection == nil)
        // Selection-scoped like the counts it derives from: selecting the two left rows of a
        // right-heavy list flips the dominant direction along with the button labels.
        let a = diff("a", action: .copyToRight)
        let b = diff("b", action: .copyToRight)
        let c = diff("c", type: .missingOnLeft, action: .copyToLeft)
        let d = diff("d", type: .missingOnLeft, action: .copyToLeft)
        let scoped = DifferenceActionTargets(filtered: [a, b, c, d], selection: [c.id, d.id])
        #expect(scoped.dominantCopyDirection == .copyToLeft)
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
