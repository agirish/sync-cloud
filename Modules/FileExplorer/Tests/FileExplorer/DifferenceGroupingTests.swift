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
        // …and it must name the FOLDER, not the raw string. The old fallback returned the whole
        // parent ("/Immigration") while `pathWithinSection` returned "Immigration", so the header
        // and every row under it said the same folder twice — the exact defect the prefix drop
        // exists to prevent, reintroduced through the edge case.
        #expect(folder == "Immigration")
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

    /// Two sections of one row each is NOT enough — it was under the first cut of this gate,
    /// which only asked "more than one section?", and a real 22-difference scan showed why that
    /// was wrong: nine headers over eleven rows. The gate now asks whether the headers pay for
    /// their own height.
    @Test func testTwoSingleRowSectionsIsNotWorthGrouping() {
        let sections = DifferenceGrouping.sections([diff("Work/a.pdf"), diff("Scans/b.pdf")])
        #expect(sections.count == 2)
        #expect(!DifferenceGrouping.isWorthGrouping(sections))
    }

    /// Root-level rows and foldered rows coexisting: the case where a wrong `folder(for:)` would
    /// quietly merge everything loose into one bucket named "".
    @Test func testRootRowsFormTheirOwnNamedSection() {
        let sections = DifferenceGrouping.sections([diff("loose.pdf"), diff("Work/a.pdf"), diff("other.txt")])
        #expect(sections.map(\.folder) == [DifferenceGrouping.rootLabel, "Work"])
        #expect(sections.first?.count == 2)
    }

    // MARK: Path shown inside a section

    @Test func testPathWithinSectionDropsTheFolderTheHeaderAlreadyNames() {
        // The defect this exists to stop: a header reading "Claude" over a row reading
        // "Claude/Projects/Investing/…", i.e. the folder said twice, in the one column that was
        // already truncating.
        #expect(DifferenceGrouping.pathWithinSection(diff("Claude/Projects/Investing/notes.md"))
                == "Projects/Investing")
        #expect(DifferenceGrouping.pathWithinSection(diff("Immigration/Authorization/H-1B/form.pdf"))
                == "Authorization/H-1B")
    }

    @Test func testPathWithinSectionIsEmptyWhenTheParentIsTheSectionFolder() {
        // A row sitting directly in the section folder has nothing left to say — it must render
        // no prefix at all, not a bare "/".
        #expect(DifferenceGrouping.pathWithinSection(diff("Work/report.docx")) == "")
    }

    @Test func testPathWithinSectionIsEmptyAtTheRoot() {
        #expect(DifferenceGrouping.pathWithinSection(diff("loose.pdf")) == "")
    }

    /// The prefix and the header must partition the parent path between them with nothing lost
    /// and nothing repeated — reassembling them has to give the original parent back.
    ///
    /// The malformed inputs below are the point. Engine-built `relativePath`s never carry a leading
    /// slash, a trailing slash or a "//", so the two functions could disagree about them for as long
    /// as they liked without anyone seeing it — and they did: "/Immigration" gave a header of
    /// "/Immigration" over rows of "Immigration/…". A latent disagreement between two halves of one
    /// partition is one refactor away from being live, so the invariant covers the whole input space
    /// rather than the well-formed corner of it.
    ///
    /// Expected values are built with `components(separatedBy:)` + an explicit non-empty filter,
    /// NOT with the `split` the implementation uses: an expectation that restates the code under
    /// test passes no matter what that code does.
    @Test func testFolderAndPathWithinSectionReassembleTheParent() {
        let paths = [
            // Well-formed.
            "Claude/Projects/Investing/notes.md", "Work/report.docx", "loose.pdf",
            "Immigration/Authorization/H-1B/form.pdf",
            // Leading slash — the case that was actually broken.
            "/Immigration/form.pdf", "/loose.pdf", "/Claude/Projects/notes.md",
            // Trailing slash and repeated slashes: empty components mid-path and at the end.
            "Work//report.docx", "Claude///Projects/notes.md", "Immigration//",
            // Nothing but separators, and nothing at all.
            "/", "//", "///", "",
        ]
        for path in paths {
            let d = diff(path)
            let folder = DifferenceGrouping.folder(for: d)
            let rest = DifferenceGrouping.pathWithinSection(d)
            let rejoined = [folder, rest]
                .filter { !$0.isEmpty && $0 != DifferenceGrouping.rootLabel }
                .joined(separator: "/")
            let expected = d.parentPath
                .components(separatedBy: "/")
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            #expect(rejoined == expected, "path \(path): folder=\(folder) rest=\(rest)")
            // Never a section with no name, and never one named after a separator.
            #expect(!folder.isEmpty, "path \(path)")
            #expect(!folder.contains("/"), "path \(path)")
            // Never a prefix that opens or closes on a bare separator — the Name cell appends "/".
            #expect(!rest.hasPrefix("/") && !rest.hasSuffix("/"), "path \(path)")
        }
    }

    /// The two functions must agree about where the boundary falls, not merely reassemble.
    ///
    /// Stated separately from the reassembly invariant because reassembly alone would tolerate the
    /// original bug in one direction: had `folder(for:)` kept returning the whole "/Immigration"
    /// while `pathWithinSection` returned "", the pieces would still rejoin — and the header would
    /// still be printing a leading slash the rows knew to drop.
    @Test func testTheTwoHalvesAgreeOnALeadingSlash() {
        let d = diff("/Immigration/form.pdf")
        #expect(DifferenceGrouping.folder(for: d) == "Immigration")
        // "" — the row sits directly in the section folder. Returning "Immigration" here is what
        // made the header and the row say the folder twice.
        #expect(DifferenceGrouping.pathWithinSection(d) == "")
    }

    /// A leading slash must not fragment one folder into two sections: "/Work/a.pdf" and
    /// "Work/b.pdf" name the same folder and have to land in the same bucket.
    @Test func testLeadingSlashDoesNotSplitAFolderInTwo() {
        let sections = DifferenceGrouping.sections([diff("/Work/a.pdf"), diff("Work/b.pdf")])
        #expect(sections.map(\.folder) == ["Work"])
        #expect(sections.first?.count == 2)
    }

    /// A parent of pure separators has no folder to name, so it files under the root label rather
    /// than minting a section whose header is blank or "/".
    @Test func testASeparatorOnlyParentFilesUnderTheRootLabel() {
        #expect(DifferenceGrouping.folder(for: diff("//loose.pdf")) == DifferenceGrouping.rootLabel)
        #expect(DifferenceGrouping.pathWithinSection(diff("//loose.pdf")) == "")
    }

    // MARK: The worth-grouping gate

    @Test func testManyTinySectionsFallBackToFlat() {
        // The shape a real 22-difference scan produced: eight folders, one or two rows each.
        // Eight headers heading eleven rows nearly doubled the list's height to restate what the
        // path prefix already said, so this must NOT group.
        let rows = ["Family/a.pdf", "Family/b.pdf", "Legal/c.pdf", "Finance/d.pdf",
                    "Claude/e.pdf", "Claude/f.pdf", "Health/g.pdf", "Scans/h.pdf",
                    "Travel/i.pdf", "Work/j.pdf", "Home/k.pdf"].map(diff)
        let sections = DifferenceGrouping.sections(rows)
        #expect(sections.count == 9)
        #expect(!DifferenceGrouping.isWorthGrouping(sections))
    }

    @Test func testFewLargeSectionsDoGroup() {
        // Three folders averaging four rows each — the case grouping exists for.
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
        // so a future tweak to `minimumAverageRowsPerSection` is a deliberate, visible change.
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
        // Plain-clicking an already-selected section still replaces — that is what makes it a
        // reliable "just this folder" gesture no matter what state you were in.
        #expect(SectionClickIntent.resolve(commandHeld: false, isFullySelected: true) == .replace)
    }

    @Test func testCommandClickAddsThenRemoves() {
        // The rule that is easy to implement backwards: ⌘-clicking a section whose rows are ALL
        // selected must take them out again, or the gesture is one-way and there is no way back
        // without clearing everything.
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
        // One row short is NOT fully selected — the header must unlight the moment a row is
        // ⌘-clicked back out, which is the whole reason it tracks the selection rather than
        // remembering that it was clicked.
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
