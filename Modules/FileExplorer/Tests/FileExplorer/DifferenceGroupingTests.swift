import Testing
import Foundation
import Sync
@testable import FileExplorer

/// The differences table's folder sections. The type must not reorder what the column sort just
/// ordered, so most of these assert order rather than membership.
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

    // MARK: Section building

    @Test func testSectionsAppearInTheOrderTheirFirstRowDoes() {
        // The load-bearing property: sorting by size descending puts the section holding the
        // biggest file first. Alphabetical sections would sort groups and rows by different keys.
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
        // No row may be dropped or duplicated: the grouped table shows the same set as the flat
        // one, or a difference silently stops being actionable.
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
        // lets grouping default on without making small comparisons noisier.
        let sections = DifferenceGrouping.sections([diff("Work/a.pdf"), diff("Work/b.pdf")])
        #expect(sections.count == 1)
        #expect(!DifferenceGrouping.isWorthGrouping(sections))
    }

    @Test func testNoSectionsIsNotWorthGrouping() {
        #expect(!DifferenceGrouping.isWorthGrouping(DifferenceGrouping.sections([])))
    }

    /// Two sections of one row each is not enough: "more than one section?" would allow nine
    /// headers over eleven rows. The gate asks whether the headers pay for their own height.
    @Test func testTwoSingleRowSectionsIsNotWorthGrouping() {
        let sections = DifferenceGrouping.sections([diff("Work/a.pdf"), diff("Scans/b.pdf")])
        #expect(sections.count == 2)
        #expect(!DifferenceGrouping.isWorthGrouping(sections))
    }

    /// Root-level rows beside foldered rows: a wrong `folder(for:)` would merge everything loose
    /// into one bucket named "".
    @Test func testRootRowsFormTheirOwnNamedSection() {
        let sections = DifferenceGrouping.sections([diff("loose.pdf"), diff("Work/a.pdf"), diff("other.txt")])
        #expect(sections.map(\.folder) == [DifferenceGrouping.rootKey, "Work"])
        #expect(sections.map(\.title) == [DifferenceGrouping.rootLabel, "Work"])
        #expect(sections.first?.count == 2)
    }

    /// A real folder named exactly like the root label must not swallow the loose rows. If the
    /// bucket key were the label, both would land in one section, and selecting the header would
    /// also select a file not in the folder. Asserted on the sections, because the property is two
    /// buckets with the right rows in each.
    @Test func testARealFolderNamedLikeTheRootLabelKeepsItsOwnSection() {
        let sections = DifferenceGrouping.sections([
            diff("loose.pdf"),
            diff("\(DifferenceGrouping.rootLabel)/a.pdf"),
            diff("\(DifferenceGrouping.rootLabel)/b.pdf"),
        ])

        #expect(sections.count == 2, "the loose row merged into the folder's section")
        #expect(sections.map(\.count) == [1, 2])
        #expect(sections[0].folder == DifferenceGrouping.rootKey)
        #expect(sections[1].folder == DifferenceGrouping.rootLabel)
        // Both print the same words, which is why the identity has to differ.
        #expect(sections.map(\.title) == [DifferenceGrouping.rootLabel, DifferenceGrouping.rootLabel])
        #expect(sections[0].rows.map(\.relativePath) == ["loose.pdf"])
    }

    /// What makes the case above unrepresentable: the root key contains a separator, and `split`
    /// never hands back a component that does.
    @Test func testTheRootKeyCannotBeProducedByAnyPath() {
        #expect(DifferenceGrouping.rootKey.contains("/"))
        for path in ["a.pdf", "One/a.pdf", "/One/a.pdf", "One//Two/a.pdf", "One/Two/Three/a.pdf"] {
            let folder = DifferenceGrouping.folder(for: diff(path))
            #expect(folder == DifferenceGrouping.rootKey || !folder.contains("/"),
                    "path \(path) produced folder \(folder)")
        }
    }

    // MARK: Bucketing robustness over malformed parents

    /// `folder(for:)` produces a printable bucket for the whole input space, not just well-formed
    /// paths. Engine-built `relativePath`s never carry a leading or trailing slash or a "//", so a
    /// mishandling could sit unseen until a refactor made it live. A leading slash names the folder,
    /// not the raw parent ("/Immigration"), and never a nameless section; a parent of pure
    /// separators files under the root label, as a root-level item does.
    @Test func testMalformedParentsStillBucketPrintably() {
        let paths = [
            "Claude/Projects/Investing/notes.md", "Work/report.docx", "loose.pdf",
            "/Immigration/form.pdf", "/loose.pdf", "/Claude/Projects/notes.md",
            "Work//report.docx", "Claude///Projects/notes.md", "Immigration//",
            "/", "//", "///", "", "//loose.pdf",
        ]
        for path in paths {
            let d = diff(path)
            let folder = DifferenceGrouping.folder(for: d)
            // The bucket is the first non-empty component, or the root key. Computed with
            // `components(separatedBy:)`, not the implementation's `split`, so the expectation
            // doesn't restate the code under test.
            let expected = d.parentPath.components(separatedBy: "/").first { !$0.isEmpty }
                ?? DifferenceGrouping.rootKey
            #expect(folder == expected, "path \(path): folder=\(folder)")
            // Never a section with no name or named after a separator. Asserted on the title, what
            // a header prints: the root key is deliberately "/" (see `rootKey`), and
            // `Section.title` turns it into words.
            let title = DifferenceGrouping.Section(folder: folder, rows: [d]).title
            #expect(!folder.isEmpty, "path \(path)")
            #expect(!title.isEmpty, "path \(path)")
            #expect(!title.contains("/"), "path \(path): header would read \(title)")
        }
    }

    /// A leading slash must not split one folder into two sections: "/Work/a.pdf" and
    /// "Work/b.pdf" land in the same bucket.
    @Test func testLeadingSlashDoesNotSplitAFolderInTwo() {
        let sections = DifferenceGrouping.sections([diff("/Work/a.pdf"), diff("Work/b.pdf")])
        #expect(sections.map(\.folder) == ["Work"])
        #expect(sections.first?.count == 2)
    }

    // MARK: The worth-grouping gate

    @Test func testManyTinySectionsFallBackToFlat() {
        // Nine folders, one or two rows each: nine headers over eleven rows would nearly double
        // the list's height to restate the path, so this must not group.
        let rows = ["Family/a.pdf", "Family/b.pdf", "Legal/c.pdf", "Finance/d.pdf",
                    "Claude/e.pdf", "Claude/f.pdf", "Health/g.pdf", "Scans/h.pdf",
                    "Travel/i.pdf", "Work/j.pdf", "Home/k.pdf"].map(diff)
        let sections = DifferenceGrouping.sections(rows)
        #expect(sections.count == 9)
        #expect(!DifferenceGrouping.isWorthGrouping(sections))
    }

    @Test func testFewLargeSectionsDoGroup() {
        // Three folders averaging four rows each: the case grouping exists for.
        var rows: [FileDifference] = []
        for folder in ["Immigration", "Work", "Scans"] {
            rows += (0..<4).map { diff("\(folder)/file-\($0).pdf") }
        }
        let sections = DifferenceGrouping.sections(rows)
        #expect(sections.count == 3)
        #expect(DifferenceGrouping.isWorthGrouping(sections))
    }

    @Test func testTheGateIsExactlyTheAverageThreshold() {
        // Two sections at exactly the threshold group; one row fewer does not. Pins the boundary
        // so changing `minimumAverageRowsPerSection` is deliberate.
        let atThreshold = (0..<DifferenceGrouping.minimumAverageRowsPerSection).flatMap {
            [diff("A/file-\($0).pdf"), diff("B/file-\($0).pdf")]
        }
        #expect(DifferenceGrouping.isWorthGrouping(DifferenceGrouping.sections(atThreshold)))
        #expect(!DifferenceGrouping.isWorthGrouping(DifferenceGrouping.sections(atThreshold.dropLast())))
    }

    // MARK: Section header clicks

    private func section(_ folder: String, _ paths: [String]) -> DifferenceGrouping.Section {
        DifferenceGrouping.Section(folder: folder, rows: paths.map(diff))
    }

    @Test func testPlainClickReplacesTheWholeSelection() {
        #expect(SectionClickIntent.resolve(commandHeld: false, isFullySelected: false) == .replace)
        // Plain-clicking an already-selected section still replaces, so it is a reliable "just
        // this folder" gesture from any state.
        #expect(SectionClickIntent.resolve(commandHeld: false, isFullySelected: true) == .replace)
    }

    @Test func testCommandClickAddsThenRemoves() {
        // Easy to get backwards: ⌘-clicking a section whose rows are all selected takes them out
        // again, or the gesture is one-way.
        #expect(SectionClickIntent.resolve(commandHeld: true, isFullySelected: false) == .add)
        #expect(SectionClickIntent.resolve(commandHeld: true, isFullySelected: true) == .remove)
    }

    @Test func testSelectionAfterEachIntent() {
        let work = section("Work", ["Work/a.pdf", "Work/b.pdf"])
        let workIds = Set(work.rows.map(\.id))
        let stranger = UUID()

        #expect(DifferenceGrouping.selection(after: .replace, section: work, current: [stranger])
                == workIds)
        #expect(DifferenceGrouping.selection(after: .add, section: work, current: [stranger])
                == workIds.union([stranger]))
        #expect(DifferenceGrouping.selection(after: .remove, section: work,
                                             current: workIds.union([stranger]))
                == [stranger])
    }

    @Test func testFullySelectedNeedsEveryRow() {
        let work = section("Work", ["Work/a.pdf", "Work/b.pdf"])
        let all = Set(work.rows.map(\.id))
        #expect(DifferenceGrouping.isFullySelected(work, in: all))
        // One row short is not fully selected: the header unlights as soon as a row is ⌘-clicked
        // out, which is why it tracks the selection rather than remembering the click.
        #expect(!DifferenceGrouping.isFullySelected(work, in: [work.rows[0].id]))
        #expect(!DifferenceGrouping.isFullySelected(work, in: []))
    }

    @Test func testAnEmptySectionIsNeverFullySelected() {
        // Vacuous truth would light a header holding nothing and make ⌘-click a silent no-op.
        #expect(!DifferenceGrouping.isFullySelected(section("Empty", []), in: []))
    }

    // MARK: Collapsed direction summary

    @Test func testDirectionSummaryNamesBothWays() {
        var rows = (0..<11).map { diff("Claude/right-\($0).pdf") }
        rows += (0..<2).map { d -> FileDifference in
            let path = "Claude/left-\(d).pdf"
            return FileDifference(relativePath: path, leftItemPath: "/l/\(path)",
                                  rightItemPath: "/r/\(path)", type: .missingOnLeft,
                                  action: .copyToLeft, description: "test")
        }
        let claude = DifferenceGrouping.Section(folder: "Claude", rows: rows)
        #expect(claude.directionSummary(leftName: "iCloud", rightName: "Dropbox")
                == "11 → Dropbox · 2 → iCloud")
    }

    @Test func testDirectionSummaryOmitsAnEmptyHalf() {
        let scans = section("Scans", ["Scans/a.pdf", "Scans/b.pdf"])
        #expect(scans.directionSummary(leftName: "iCloud", rightName: "Dropbox") == "2 → Dropbox")
    }

    @Test func testDirectionSummaryIsEmptyWithNothingToSay() {
        // No stray separator on a section that somehow has neither direction.
        #expect(section("Empty", []).directionSummary(leftName: "iCloud", rightName: "Dropbox") == "")
    }
}
