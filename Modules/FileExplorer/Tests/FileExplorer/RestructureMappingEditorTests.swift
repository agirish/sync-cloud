import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// §5.4's mapping editor, made navigable: how many rows are mapped, a filter past a dozen, and
/// near-identical names sorted adjacent (proposal O8).
@MainActor
@Suite struct RestructureMappingEditorTests {

    private static func rows(_ names: [String]) -> [RestructureMapping.Row] {
        names.map { RestructureMapping.Row(source: $0) }
    }

    // MARK: The count

    /// Keep is the default, so "9 of 24" is the difference between a plan half-made and one
    /// deliberately left mostly alone — and a row mapped to its OWN name changed nothing.
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

    /// And the discriminating direction — genuinely different names must NOT collapse, or the
    /// editor would sort unrelated rows together and claim they are the same name.
    @Test func genuinelyDifferentNamesDoNot() {
        let key = RestructurePlanSheet.similarKey
        #expect(key("Payments") != key("Statements"))
        #expect(key("Forms") != key("Form W-2"))
        #expect(key("2013") != key("2014"))
        #expect(key("Bus") != key("Bu"), "the plural fold must not eat a real final s")
    }

    // MARK: Adjacency

    /// Similar rows become neighbours; everything else keeps the disk's own order, so the list
    /// does not otherwise rearrange itself under the reader.
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

    /// **The whole-list form and the per-row rule are the SAME rule.** The editor drew the link
    /// marker by asking the per-row question once per row — O(rows²) similar-key reductions per
    /// render, per keystroke in the filter — and now asks once for the list. If the two ever
    /// answered differently, the marker would be claiming an adjacency the sort did not make.
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
        // And the answers themselves — an agreement between two functions that are both wrong is
        // still an agreement. Two pairs the plural fold deliberately does NOT make are in the
        // fixture: `Bus`/`Bu` (the fold needs a real stem left, so `Bus` does not become `Bu`)
        // and `Taxes`/`Tax` (`tax` is under the four-character bar, so nothing folds).
        #expect(set == ["Payment", "Payments", "Form W-2", "Form W2"])
    }

    @Test func anEmptyOrSingletonListHasNoNeighbours() {
        #expect(RestructurePlanSheet.sourcesWithSimilarNeighbour([]).isEmpty)
        #expect(RestructurePlanSheet.sourcesWithSimilarNeighbour(Self.rows(["Only"])).isEmpty)
    }

    // MARK: The merge margin

    /// **"merges into Forms in 3 members", derived once for the plan rather than once per row.**
    ///
    /// The margin used to walk every action in the manifest to answer for one row — the whole
    /// manifest re-scanned per visible row per render. The table is built in one pass, and these
    /// are the shapes that pass has to get right: the member is the FIRST path component under
    /// the family and the source name the second, a `move-dir` counts as well as a `move-file`,
    /// and one source merging in three members counts three, not three files.
    @Test func theMergeMarginTableCountsMembersNotFiles() {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "F", kind: .shape,
            actions: [
                .init(action: .moveFile, src: "F/2013/State Tax/a.pdf", dst: "F/2013/Forms/a.pdf"),
                .init(action: .moveFile, src: "F/2013/State Tax/b.pdf", dst: "F/2013/Forms/b.pdf"),
                .init(action: .moveFile, src: "F/2014/State Tax/c.pdf", dst: "F/2014/Forms/c.pdf"),
                .init(action: .moveDir, src: "F/2015/State Tax/Sub", dst: "F/2015/Forms/Sub"),
                .init(action: .moveFile, src: "F/2013/Payments/d.pdf", dst: "F/2013/Forms/d.pdf"),
                // Not under the family, and a rename — neither is a merge.
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

    /// It narrows by the same key the sorting uses, so typing `w2` finds `Form W-2` — the pair
    /// the editor exists to reconcile is exactly the one a literal search would miss.
    @Test func theFilterMatchesAcrossPunctuationAndCase() {
        #expect(RestructurePlanSheet.matches("Form W-2", filter: "w2"))
        #expect(RestructurePlanSheet.matches("Form W-2", filter: "FORM"))
        #expect(!RestructurePlanSheet.matches("Statements", filter: "w2"))
    }

    /// An empty filter shows everything — including while it is being typed and cleared.
    @Test func anEmptyFilterHidesNothing() {
        #expect(RestructurePlanSheet.matches("anything", filter: ""))
        #expect(RestructurePlanSheet.matches("anything", filter: "   "))
        #expect(RestructurePlanSheet.matches("anything", filter: "-–-"),
                "punctuation alone reduces to nothing and must not hide every row")
    }

    /// **The filter narrows the VIEW, never the plan.** `rows` stays canonical and complete, so
    /// the derived manifest is identical with a filter active — a filter that changed what
    /// Apply does would be the worst defect this feature could have.
    @Test func theFilterCannotReachTheDerivedManifest() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/RestructurePlanSheet.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // The derivation reads `rows` whole...
        #expect(text.contains("mapping: RestructureMapping(rows: rows)"))
        // ...and the filter is applied only where rows are RENDERED.
        #expect(text.contains("if Self.matches(row.source, filter: filterText)"),
                "the filter is applied at the row, in the list")
        // **The derivation's own body, read directly.** The previous form of this test compared
        // two file offsets with an `||`, and because the render use genuinely does sit earlier in
        // the file its first disjunct was always true — the half that checked anything never ran.
        // Slicing the property's body and looking inside it has no such escape.
        let derived = try #require(text.range(of: "private var derived:"))
        let afterDerived = text[derived.upperBound...]
        let bodyEnd = try #require(afterDerived.range(of: "\n    }\n"))
        let body = afterDerived[..<bodyEnd.lowerBound]
        #expect(body.contains("rows"), "a positive control: the slice really is the derivation")
        #expect(!body.contains("filterText"),
                "the derivation must not consult the filter — Apply does not narrow with the view")
    }

    /// **The filter narrows what the list draws** — checked at the rule, because the sheet's
    /// `filterText` is `@State` with no way in, so a render test naming two states could only
    /// ever produce one. The previous version of this did exactly that, and `matches` returning
    /// `true` unconditionally survived it.
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
        // An ink floor, not a width: `fittingSize.width > 0` is true of an empty
        // `VStack`, so it passed with the subject of this test deleted.
        let rep = try #require(RestructureRender.raster(sheet, width: 620, height: 700))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
    }
}
