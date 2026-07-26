import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The differences table's folder sections. The whole point of this type is that it must not
/// reorder what the column sort just ordered, so most of these assert ORDER rather than membership.
@Suite struct DifferenceGroupingTests {

    private func diff(_ relativePath: String) -> FileDifference {
        FileDifference(
            relativePath: relativePath,
            leftItemPath: "/l/\(relativePath)",
            rightItemPath: "/r/\(relativePath)",
            type: .missingOnRight,
            action: .copyToRight,
            description: "test"
        )
    }

    // MARK: Folder key

    @Test func testFolderIsTheFirstPathComponentNotTheWholeParent() {
        // Grouping by the whole parent path would turn a real comparison into ~one section per
        // row. The top-level folder is the unit a person decides about.
        #expect(DifferenceGrouping.folder(for: diff("Immigration/Authorization/H-1B/form.pdf")) == "Immigration")
        #expect(DifferenceGrouping.folder(for: diff("Work/report.docx")) == "Work")
    }

    @Test func testRootLevelItemsGetTheRootLabel() {
        #expect(DifferenceGrouping.folder(for: diff("loose.pdf")) == DifferenceGrouping.rootLabel)
    }

    @Test func testLeadingSlashDoesNotProduceANamelessSection() {
        // `parentPath` is relative and should never start with "/", but a nameless section is a
        // visible, confusing failure and the fallback costs one line.
        let folder = DifferenceGrouping.folder(for: diff("/Immigration/form.pdf"))
        #expect(!folder.isEmpty)
    }

    // MARK: Section building

    @Test func testSectionsAppearInTheOrderTheirFirstRowDoes() {
        // The load-bearing property. Sorting by size descending must put the section holding the
        // biggest file first — if sections were ordered alphabetically instead, the groups and the
        // rows would sort by different keys and the table would read as broken.
        let sorted = [diff("Work/a.pdf"), diff("Immigration/b.pdf"), diff("Work/c.pdf"), diff("Scans/d.pdf")]
        let sections = DifferenceGrouping.sections(sorted)
        #expect(sections.map(\.folder) == ["Work", "Immigration", "Scans"])
    }

    @Test func testRowsKeepTheirRelativeOrderInsideASection() {
        let sorted = [diff("Work/a.pdf"), diff("Immigration/b.pdf"), diff("Work/c.pdf"), diff("Work/e.pdf")]
        let work = DifferenceGrouping.sections(sorted).first { $0.folder == "Work" }
        #expect(work?.rows.map(\.fileName) == ["a.pdf", "c.pdf", "e.pdf"])
    }

    @Test func testEveryRowLandsInExactlyOneSection() {
        // No row may be dropped or duplicated — the grouped table has to show the same set the
        // flat one did, or a difference silently stops being actionable.
        let sorted = [diff("Work/a.pdf"), diff("Immigration/b.pdf"), diff("loose.pdf"),
                      diff("Work/c.pdf"), diff("Scans/d.pdf")]
        let sections = DifferenceGrouping.sections(sorted)
        let regrouped = sections.flatMap(\.rows)
        #expect(regrouped.count == sorted.count)
        #expect(Set(regrouped.map(\.id)) == Set(sorted.map(\.id)))
    }

    @Test func testSectionCountMatchesItsRows() {
        let sections = DifferenceGrouping.sections([diff("Work/a.pdf"), diff("Work/b.pdf"), diff("Scans/c.pdf")])
        #expect(sections.map(\.count) == [2, 1])
    }

    @Test func testEmptyInputProducesNoSections() {
        #expect(DifferenceGrouping.sections([]).isEmpty)
    }

    // MARK: The fall-back-to-flat gate

    @Test func testASingleSectionIsNotWorthGrouping() {
        // One header saying the same thing about every row is pure chrome. Falling back to flat
        // here is what lets grouping default ON without making small comparisons noisier.
        let sections = DifferenceGrouping.sections([diff("Work/a.pdf"), diff("Work/b.pdf")])
        #expect(sections.count == 1)
        #expect(!DifferenceGrouping.isWorthGrouping(sections))
    }

    @Test func testNoSectionsIsNotWorthGrouping() {
        #expect(!DifferenceGrouping.isWorthGrouping(DifferenceGrouping.sections([])))
    }

    @Test func testTwoSectionsIsWorthGrouping() {
        let sections = DifferenceGrouping.sections([diff("Work/a.pdf"), diff("Scans/b.pdf")])
        #expect(DifferenceGrouping.isWorthGrouping(sections))
    }

    /// Root-level rows and foldered rows coexisting: the case where a wrong `folder(for:)` would
    /// quietly merge everything loose into one bucket named "".
    @Test func testRootRowsFormTheirOwnNamedSection() {
        let sections = DifferenceGrouping.sections([diff("loose.pdf"), diff("Work/a.pdf"), diff("other.txt")])
        #expect(sections.map(\.folder) == [DifferenceGrouping.rootLabel, "Work"])
        #expect(sections.first?.count == 2)
    }
}
