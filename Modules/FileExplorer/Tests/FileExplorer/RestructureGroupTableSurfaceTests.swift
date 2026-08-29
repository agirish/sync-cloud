import AppKit
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// The group table and batch planning on the sheet (proposal O17).
///
/// The rules are next door in `Sync`; what only a render can answer is whether the grid is drawn,
/// whether it stays out of the way until asked for, and whether turning the toggle on visibly
/// changes what the mapping covers.
@MainActor
@Suite struct RestructureGroupTableSurfaceTests {

    private static func trio() -> RestructureTreeView {
        let children: [String: [String]] = [
            "Immigration": ["H-1B", "H-4", "H-4 EAD"],
            "Immigration/H-1B": ["2023", "2024"],
            "Immigration/H-1B/2023": ["Petition", "Approval", "Correspondence", "Receipts"],
            "Immigration/H-1B/2024": ["Petition", "Approval"],
            "Immigration/H-4": ["2023"],
            "Immigration/H-4/2023": ["Application", "Approval", "Correspondence", "Receipts"],
            "Immigration/H-4 EAD": ["2023"],
            "Immigration/H-4 EAD/2023": ["Application", "Approval", "Correspondence",
                                         "Receipts"],
        ]
        return RestructureTreeView(childFolders: { children[$0] }, files: { _ in [] },
                                   fileCount: { _ in 1 })
    }

    private static func sheet(tree: RestructureTreeView? = nil) -> RestructurePlanSheet {
        let finding = StructureFinding(
            family: "Immigration/H-1B",
            schemes: [.init(vocabulary: ["petition", "approval"], members: ["2024"]),
                      .init(vocabulary: ["petition", "approval", "correspondence"],
                            members: ["2023"])])
        return RestructurePlanSheet(
            finding: finding, family: "Immigration/H-1B", members: ["2023", "2024"],
            tree: tree ?? trio(), profileId: "p", accent: .blue,
            onExport: { _, _ in .saved(filename: "f.json") },
            onApply: { _ in .applied(summary: "done") },
            onClose: {})
    }

    /// **The collapsed header carries the number that decides whether to open it.** A group
    /// that already agrees says so, rather than offering a grid under a count of zero — the
    /// sentence IS the answer there, and the table would only confirm it row by row.
    @Test func theHeaderStatesHowFarApartTheFamiliesAre() {
        #expect(RestructurePlanSheet.groupHeaderText(disagreements: 3, families: 3)
                    == "3 names are not shared by all 3")
        #expect(RestructurePlanSheet.groupHeaderText(disagreements: 1, families: 2)
                    == "1 name is not shared by all 2")
        #expect(RestructurePlanSheet.groupHeaderText(disagreements: 0, families: 3)
                    == "These 3 families already agree on every name")
    }

    /// **The grid and its checkbox are actually drawn.** The first version of this test asserted
    /// an ink floor on a sheet whose fixture never cleared `parallelFamilies`' three-shared-names
    /// bar — so it rendered no group at all, and passed at 146,125 inked pixels against a bar of
    /// 2,000 with the entire feature absent. The comparison is against the same sheet over a tree
    /// whose siblings share too little to be a group, which is the only difference between them.
    @Test func theGroupTableAndItsCheckboxAreDrawn() throws {
        let lonely: [String: [String]] = [
            "Immigration": ["H-1B", "H-4"],
            "Immigration/H-1B": ["2023", "2024"],
            "Immigration/H-1B/2023": ["Petition", "Approval", "Correspondence", "Receipts"],
            "Immigration/H-1B/2024": ["Petition", "Approval"],
            // One shared name only — under the bar, so no group forms.
            "Immigration/H-4": ["2023"],
            "Immigration/H-4/2023": ["Approval", "Deportation"],
        ]
        let lonelyTree = RestructureTreeView(childFolders: { lonely[$0] }, files: { _ in [] },
                                             fileCount: { _ in 1 })
        #expect(RestructurePlanner.parallelFamilies(of: "Immigration/H-1B", in: Self.trio())
                    .isEmpty == false,
                "a positive control: the subject fixture really does form a group")
        #expect(RestructurePlanner.parallelFamilies(of: "Immigration/H-1B", in: lonelyTree)
                    .isEmpty,
                "and the comparison tree really does not")

        let withGroup = try #require(RestructureRender.raster(Self.sheet(),
                                                              width: 620, height: 900))
        let withoutGroup = try #require(RestructureRender.raster(Self.sheet(tree: lonelyTree),
                                                                 width: 620, height: 900))
        #expect(RestructureRender.inkedPixels(withoutGroup) > 2000, "both sheets drew")
        #expect(RestructureRender.differingPixels(withGroup, withoutGroup) > 500,
                "the pointer sentence, the disclosure header and the checkbox are on the sheet")
    }

    /// **The mapping's sources widen to the group.** This is the rule the toggle drives, checked
    /// where it is decided: planning H-1B alone maps three names, and planning the trio together
    /// maps four — the fourth being `Application`, which only the siblings have and which is
    /// exactly the name a plan for H-1B alone would leave them disagreeing about.
    @Test func planningTogetherWidensTheSourcesToTheWholeGroup() {
        let families = ["Immigration/H-1B", "Immigration/H-4", "Immigration/H-4 EAD"]
        let alone = RestructurePlanner.distinctSources(family: "Immigration/H-1B",
                                                       members: ["2023", "2024"], in: Self.trio())
        #expect(alone == ["Approval", "Correspondence", "Petition", "Receipts"])

        let together = RestructurePlanner.groupSources(families: families, in: Self.trio())
        #expect(together == ["Application", "Approval", "Correspondence", "Petition",
                             "Receipts"])
        #expect(Set(together).isSuperset(of: alone), "nothing the family had is lost")
    }

    // MARK: Toggling the group must not eat typed work

    /// **A target chosen for a sibling-only name survives the round trip.** Narrowing the mapping
    /// back to one family drops that row, so a version that rebuilt the memory from `rows` on the
    /// way in lost it: toggle off, toggle on, and the choice is gone with no undo.
    @Test func aTargetForASiblingOnlyNameSurvivesTogglingTheGroupOffAndOn() throws {
        let groupSources = ["Application", "Approval", "Correspondence", "Petition"]
        let familySources = ["Approval", "Correspondence", "Petition"]

        // Planning together, the user maps two names — one of them a name only the siblings have.
        let wide = RestructurePlanSheet.rewidened(
            rows: groupSources.map { RestructureMapping.Row(source: $0) },
            to: groupSources, remembering: [:])
        var edited = wide.rows.map { row -> RestructureMapping.Row in
            switch row.source {
            case "Application": return RestructureMapping.Row(source: row.source,
                                                              target: "Petition")
            case "Correspondence": return RestructureMapping.Row(source: row.source,
                                                                 target: "Letters")
            default: return row
            }
        }

        // Toggle OFF: `Application` leaves the list entirely.
        let narrow = RestructurePlanSheet.rewidened(rows: edited, to: familySources,
                                                    remembering: wide.remembered)
        #expect(narrow.rows.map(\.source).sorted() == familySources)
        #expect(narrow.rows.first { $0.source == "Correspondence" }?.target == "Letters",
                "a name that stayed keeps its target")

        // Toggle back ON: the sibling-only choice is still there.
        edited = narrow.rows
        let again = RestructurePlanSheet.rewidened(rows: edited, to: groupSources,
                                                   remembering: narrow.remembered)
        #expect(again.rows.first { $0.source == "Application" }?.target == "Petition",
                "the target chosen while the group was open came back with it")
        #expect(again.rows.first { $0.source == "Correspondence" }?.target == "Letters")
        #expect(again.rows.first { $0.source == "Approval" }?.target == nil,
                "a name never mapped is still keep")
    }

    /// The other direction: setting a row back to *keep* must be remembered as keep, or a source
    /// that leaves and returns would resurrect a target the user deliberately cleared.
    @Test func clearingATargetIsRememberedAsClearing() throws {
        let sources = ["Approval", "Petition"]
        let mapped = RestructurePlanSheet.rewidened(
            rows: [RestructureMapping.Row(source: "Approval", target: "Forms"),
                   RestructureMapping.Row(source: "Petition")],
            to: sources, remembering: [:])
        #expect(mapped.remembered["Approval"] == "Forms")

        let cleared = RestructurePlanSheet.rewidened(
            rows: mapped.rows.map { RestructureMapping.Row(source: $0.source) },
            to: sources, remembering: mapped.remembered)
        #expect(cleared.remembered["Approval"] == nil)
        #expect(cleared.rows.allSatisfy { $0.target == nil })
    }
}
