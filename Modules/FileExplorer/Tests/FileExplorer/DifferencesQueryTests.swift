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
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "", pathRootName: nil))
        // Empty search must not narrow the list at all.
        let list = [diff("a"), diff("b/c"), diff("d/e/f")]
        #expect(DifferencesQuery.filtered(list, filter: .all, searchText: "", pathRootName: nil).count == 3)
    }

    @Test func testSearchIsCaseInsensitiveSubstringOfRelativePath() {
        let d = diff("Docs/Report.txt")
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "report", pathRootName: nil))
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "DOCS", pathRootName: nil))
        #expect(DifferencesQuery.matches(d, filter: .all, searchText: "s/R", pathRootName: nil))
        #expect(!DifferencesQuery.matches(d, filter: .all, searchText: "missing", pathRootName: nil))
    }

    @Test func testFilterAndSearchAreCombinedWithAnd() {
        // A missing-on-left item fails the missing-on-right filter regardless of search text.
        let d = diff("docs/report.txt", type: .missingOnLeft, action: .copyToLeft)
        #expect(!DifferencesQuery.matches(d, filter: .missingOnRight, searchText: "report", pathRootName: nil))
        // Passes the filter but the search excludes it.
        let onRight = diff("docs/report.txt", type: .missingOnRight)
        #expect(!DifferencesQuery.matches(onRight, filter: .missingOnRight, searchText: "budget", pathRootName: nil))
        // Passes both.
        #expect(DifferencesQuery.matches(onRight, filter: .missingOnRight, searchText: "report", pathRootName: nil))
    }

    @Test func testFilteredCombinesBothInOnePass() {
        let list = [
            diff("keep/report.txt", type: .missingOnRight),
            diff("keep/budget.txt", type: .missingOnRight),
            diff("skip/report.txt", type: .missingOnLeft, action: .copyToLeft),
        ]
        let result = DifferencesQuery.filtered(list, filter: .missingOnRight, searchText: "report", pathRootName: nil)
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
        let counts = DifferencesQuery.counts(list)
        #expect(counts[.all] == 6)
        #expect(counts[.missingOnRight] == 2)
        #expect(counts[.missingOnLeft] == 1)
        #expect(counts[.changedCopyToRight] == 1)
        #expect(counts[.changedCopyToLeft] == 1)
        #expect(counts[.nameConflicts] == 1)
        // The specific-filter counts partition the whole diff: they sum to `.all`.
        let specificsSum = DifferenceFilter.allCases
            .filter { $0 != .all }
            .reduce(0) { $0 + (counts[$1] ?? 0) }
        #expect(specificsSum == counts[.all])
    }

    @Test func testCountsIgnoresSearchTextAndEmptyListYieldsZeroes() {
        // Counts reflect the whole diff (search is not a parameter), matching Tidy's menu.
        #expect(DifferencesQuery.counts([]).isEmpty)
        // A single filter's count matches `filtered` with an empty search over the same list.
        let list = [
            diff("keep/report.txt", type: .missingOnRight),
            diff("skip/report.txt", type: .missingOnLeft, action: .copyToLeft),
        ]
        let counts = DifferencesQuery.counts(list)
        #expect(counts[.missingOnRight, default: 0]
            == DifferencesQuery.filtered(list, filter: .missingOnRight, searchText: "", pathRootName: nil).count)
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

    @Test func testPathSortOrdersByParentAndKeepsRootRowsFirst() {
        let list = [
            diff("Legal/lease.pdf"),
            diff("visa.pdf"),
            diff("HOA/2024/report.pdf"),
        ]
        let asc = list.sorted(using: [KeyPathComparator(\.parentPath, comparator: .localizedStandard, order: .forward)])
        // Root rows ("" parent) first, then folders in name order — siblings end up adjacent.
        #expect(asc.map(\.relativePath) == ["visa.pdf", "HOA/2024/report.pdf", "Legal/lease.pdf"])
    }

    // MARK: Path column text (where a row's file lives, anchored at the compared folder)

    @Test func testPathColumnAnchorsAtTheRootName() {
        // The root-level row is the one this column exists for: it used to show NOTHING (empty
        // prefix, no section header) — the exact row the user could not place.
        #expect(DifferencesQuery.pathColumnText(parentPath: "", rootName: "Home") == "Home")
        #expect(DifferencesQuery.pathColumnText(parentPath: "Legal", rootName: "Home") == "Home/Legal")
        #expect(DifferencesQuery.pathColumnText(parentPath: "HOA/2024", rootName: "Home") == "Home/HOA/2024")
    }

    @Test func testPathColumnTextDropsLeadingSeparators() {
        // Engine-built parents never lead with "/" — but this join is the second place that
        // assumption became load-bearing (DifferenceGrouping records the first), and unguarded
        // it would print "Home//Immigration".
        #expect(DifferencesQuery.pathColumnText(parentPath: "/Immigration", rootName: "Home")
                == "Home/Immigration")
        #expect(DifferencesQuery.pathColumnText(parentPath: "//", rootName: "Home") == "Home")
        #expect(DifferencesQuery.pathColumnText(parentPath: "/", rootName: nil)
                == DifferenceGrouping.rootLabel)
    }

    @Test func testPathColumnWithoutARootNameFallsBackToTheBareParent() {
        // rootName is nil when the two compared folders carry different names — anchoring at
        // either would misname the other side — and empty is the same answer by another spelling.
        for root in [nil, ""] {
            #expect(DifferencesQuery.pathColumnText(parentPath: "Legal", rootName: root) == "Legal")
            // The root row still never reads as blank: the grouping's root label stands in.
            #expect(DifferencesQuery.pathColumnText(parentPath: "", rootName: root)
                    == DifferenceGrouping.rootLabel)
        }
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
