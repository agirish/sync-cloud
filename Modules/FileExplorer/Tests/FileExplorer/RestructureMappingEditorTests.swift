import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The plan sheet's mapping editor, made navigable: how many rows are mapped, a filter past a
/// dozen, and near-identical names sorted adjacent.
@MainActor
@Suite struct RestructureMappingEditorTests {

    private static func rows(_ names: [String]) -> [RestructureMapping.Row] {
        names.map { RestructureMapping.Row(source: $0) }
    }

    // MARK: The count

    /// Keep is the default, so "9 of 24" tells a half-made plan from one left mostly alone on
    /// purpose; a row mapped to its own name changes nothing and isn't counted.
    @Test func theCountCountsRowsThatWouldChangeSomething() {
        var rows = Self.rows(["A", "B", "C"])
        #expect(RestructurePlanSheet.mappedCount(rows).hasPrefix("0 of 3"))
        rows[0].target = "Forms"
        #expect(RestructurePlanSheet.mappedCount(rows).hasPrefix("1 of 3"))
        rows[1].target = "B"
        #expect(RestructurePlanSheet.mappedCount(rows).hasPrefix("1 of 3"),
                "a row pointed at its own name is the vocabulary agreeing with itself")
        #expect(RestructurePlanSheet.mappedCount(rows).contains("keep their name"))
    }

    // MARK: The similar-name key

    /// The pairs this exists for: differing by punctuation, by case, or by a plural.
    @Test func nearIdenticalNamesShareAKey() {
        let key = RestructurePlanSheet.similarKey
        #expect(key("Payment") == key("Payments"))
        #expect(key("Form W-2") == key("Form W2"))
        #expect(key("form w2") == key("Form W-2"))
        #expect(key("DS-160 Form") == key("DS 160 Form"))
    }

    /// And the other direction: different names must not collapse, or the editor would sort
    /// unrelated rows together as one name.
    @Test func genuinelyDifferentNamesDoNot() {
        let key = RestructurePlanSheet.similarKey
        #expect(key("Payments") != key("Statements"))
        #expect(key("Forms") != key("Form W-2"))
        #expect(key("2013") != key("2014"))
        #expect(key("Bus") != key("Bu"), "the plural fold must not eat a real final s")
    }

    // MARK: Adjacency

    /// Similar rows become neighbours; everything else keeps the disk's order, so the list doesn't
    /// otherwise rearrange itself under the reader.
    @Test func similarRowsAreSortedAdjacentAndNothingElseMoves() {
        let ordered = RestructurePlanSheet.adjacentOrder(
            Self.rows(["Payment", "Receipts", "Payments", "Statements", "Receipt"]))
        #expect(ordered.map(\.source)
                    == ["Payment", "Payments", "Receipts", "Receipt", "Statements"])
    }

    @Test func aRowWithNoTwinIsNotMarked() {
        let rows = Self.rows(["Payment", "Payments", "Statements"])
        #expect(RestructurePlanSheet.hasSimilarNeighbour(rows[0], in: rows))
        #expect(RestructurePlanSheet.hasSimilarNeighbour(rows[1], in: rows))
        #expect(!RestructurePlanSheet.hasSimilarNeighbour(rows[2], in: rows))
    }

    /// The whole-list form and the per-row rule are the same rule. The editor asks once for the
    /// list, not once per row (O(rows²) per keystroke); if the two disagreed, the link marker
    /// would claim an adjacency the sort didn't make.
    @Test func theWholeListNeighbourSetAgreesWithThePerRowRule() {
        let names = ["Payment", "Payments", "Statements", "Form W-2", "Form W2", "Receipts",
                     "Bus", "Bu", "Taxes", "Tax"]
        let rows = Self.rows(names)
        let set = RestructurePlanSheet.sourcesWithSimilarNeighbour(rows)
        for row in rows {
            #expect(set.contains(row.source)
                        == RestructurePlanSheet.hasSimilarNeighbour(row, in: rows),
                    "\(row.source): the list form and the per-row rule disagree")
        }
        // And the answers themselves, since two wrong functions can still agree. The fixture holds
        // two pairs the plural fold doesn't make: `Bus`/`Bu` (the fold needs a real stem left) and
        // `Taxes`/`Tax` (`tax` is under the four-character bar).
        #expect(set == ["Payment", "Payments", "Form W-2", "Form W2"])
    }

    @Test func anEmptyOrSingletonListHasNoNeighbours() {
        #expect(RestructurePlanSheet.sourcesWithSimilarNeighbour([]).isEmpty)
        #expect(RestructurePlanSheet.sourcesWithSimilarNeighbour(Self.rows(["Only"])).isEmpty)
    }

    // MARK: The merge margin

    /// "merges into Forms in 3 members", derived in one pass for the plan rather than per row.
    /// The pass must get these right: the member is the first path component under the family and
    /// the source name the second, a `move-dir` counts as well as a `move-file`, and one source
    /// merging in three members counts three members, not its files.
    @Test func theMergeMarginTableCountsMembersNotFiles() {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shape,
            actions: [
                .init(action: .moveFile, src: "F/2013/State Tax/a.pdf", dst: "F/2013/Forms/a.pdf"),
                .init(action: .moveFile, src: "F/2013/State Tax/b.pdf", dst: "F/2013/Forms/b.pdf"),
                .init(action: .moveFile, src: "F/2014/State Tax/c.pdf", dst: "F/2014/Forms/c.pdf"),
                .init(action: .moveDir, src: "F/2015/State Tax/Sub", dst: "F/2015/Forms/Sub"),
                .init(action: .moveFile, src: "F/2013/Payments/d.pdf", dst: "F/2013/Forms/d.pdf"),
                // Not under the family, and a rename: neither is a merge.
                .init(action: .moveFile, src: "Other/2013/State Tax/e.pdf", dst: "X/e.pdf"),
                .init(action: .renameDir, src: "F/2016/State Tax", dst: "F/2016/Forms"),
                // One component deep: no member/source pair to read.
                .init(action: .moveFile, src: "F/loose.pdf", dst: "F/2013/Forms/loose.pdf"),
            ])
        let table = RestructurePlanSheet.mergeMembers(in: .success(manifest), family: "F")
        #expect(table["State Tax"] == 3, "three members, two of them from one file each")
        #expect(table["Payments"] == 1)
        #expect(table["loose.pdf"] == nil)
        #expect(table["Forms"] == nil, "a destination is not a source")
    }

    /// A top-level family has no prefix to strip, and a refused plan has no table at all.
    @Test func theMergeMarginTableHandlesATopLevelFamilyAndARefusal() {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "", kind: .shape,
            actions: [.init(action: .moveFile, src: "2013/State Tax/a.pdf",
                            dst: "2013/Forms/a.pdf")])
        #expect(RestructurePlanSheet.mergeMembers(in: .success(manifest), family: "")
                    == ["State Tax": 1])
        #expect(RestructurePlanSheet.mergeMembers(in: .failure(.nothingMapped), family: "F")
                    .isEmpty)
    }

    // MARK: The filter

    /// It narrows by the same key the sorting uses, so `w2` finds `Form W-2`: the pairs the editor
    /// reconciles are the ones a literal search would miss.
    @Test func theFilterMatchesAcrossPunctuationAndCase() {
        #expect(RestructurePlanSheet.matches("Form W-2", filter: "w2"))
        #expect(RestructurePlanSheet.matches("Form W-2", filter: "FORM"))
        #expect(!RestructurePlanSheet.matches("Statements", filter: "w2"))
    }

    /// An empty filter shows everything, including while it is being typed and cleared.
    @Test func anEmptyFilterHidesNothing() {
        #expect(RestructurePlanSheet.matches("anything", filter: ""))
        #expect(RestructurePlanSheet.matches("anything", filter: "   "))
        #expect(RestructurePlanSheet.matches("anything", filter: "-–-"),
                "punctuation alone reduces to nothing and must not hide every row")
    }

    /// The filter narrows the view, never the plan. `rows` stays canonical and complete, so the
    /// derived manifest is the same with a filter active; a filter that changed what Apply does
    /// would be the worst defect this feature could have.
    @Test func theFilterCannotReachTheDerivedManifest() throws {
        let text = try SourceText.fileExplorer("RestructurePlanSheet.swift")
        // The derivation reads `rows` whole...
        #expect(text.contains("mapping: RestructureMapping(rows: rows)"))
        // ...and the filter is applied only where rows are rendered.
        #expect(text.contains("if Self.matches(row.source, filter: filterText)"),
                "the filter is applied at the row, in the list")
        // The derivation's own body, sliced and read directly, rather than comparing file
        // offsets, which the render use sitting earlier in the file would satisfy.
        let body = try SourceText.body(of: "private var derived:", in: text)
        #expect(body.contains("rows"), "a positive control: the slice really is the derivation")
        #expect(!body.contains("filterText"),
                "the derivation must not consult the filter — Apply does not narrow with the view")
    }

    /// The filter narrows what the list draws, checked at the rule: the sheet's `filterText` is
    /// `@State` with no way in, so a render test could only produce one state. `matches` returning
    /// `true` unconditionally must fail this.
    @Test func theFilterHidesTheRowsItDoesNotMatch() {
        let rows = ["Payment", "Payments", "Transcripts", "Form W-2"]
        #expect(rows.filter { RestructurePlanSheet.matches($0, filter: "pay") }
                == ["Payment", "Payments"])
        #expect(rows.filter { RestructurePlanSheet.matches($0, filter: "w2") } == ["Form W-2"],
                "the key folds punctuation, so W2 finds W-2")
        #expect(rows.filter { RestructurePlanSheet.matches($0, filter: "") } == rows)
        #expect(rows.filter { RestructurePlanSheet.matches($0, filter: "zzz") }.isEmpty,
                "a filter matching nothing hides every row")
    }

    /// The whole sheet renders with a filter present.
    @Test func theEditorRendersFilteredAndUnfiltered() throws {
        let finding = StructureFinding(
            family: "F",
            schemes: [.init(vocabulary: ["forms"], members: ["2013"]),
                      .init(vocabulary: ["payments"], members: ["2014"])])
        var folders: [String: [String]] = ["F": ["2013", "2014"]]
        folders["F/2013"] = (1...14).map { "Name \($0)" }
        folders["F/2014"] = ["Payment", "Payments"]
        let tree = RestructureTreeView(
            childFolders: { folders[$0] ?? [] },
            files: { _ in [] },
            fileCount: { _ in 0 })
        let sheet = RestructurePlanSheet(
            finding: finding, family: "F", members: ["2013", "2014"], tree: tree,
            profileId: "p", accent: .blue,
            onExport: { _, _ in .saved(filename: "f.json") }, onClose: {})
        // An ink floor, not a width: `fittingSize.width > 0` holds for an empty `VStack`.
        let rep = try #require(RestructureRender.raster(sheet, width: 620, height: 700))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
    }
}
