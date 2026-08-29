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

    /// The whole sheet renders with a filter present and with one applied.
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
