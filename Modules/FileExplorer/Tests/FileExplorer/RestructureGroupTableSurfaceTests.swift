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
            "Immigration/H-1B/2023": ["Petition", "Approval", "Correspondence"],
            "Immigration/H-1B/2024": ["Petition", "Approval"],
            "Immigration/H-4": ["2023"],
            "Immigration/H-4/2023": ["Application", "Approval", "Correspondence"],
            "Immigration/H-4 EAD": ["2023"],
            "Immigration/H-4 EAD/2023": ["Application", "Approval"],
        ]
        return RestructureTreeView(childFolders: { children[$0] }, files: { _ in [] },
                                   fileCount: { _ in 1 })
    }

    private static func sheet() -> RestructurePlanSheet {
        let finding = StructureFinding(
            family: "Immigration/H-1B",
            schemes: [.init(vocabulary: ["petition", "approval"], members: ["2024"]),
                      .init(vocabulary: ["petition", "approval", "correspondence"],
                            members: ["2023"])])
        return RestructurePlanSheet(
            finding: finding, family: "Immigration/H-1B", members: ["2023", "2024"],
            tree: trio(), profileId: "p", accent: .blue,
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

    /// The whole sheet lays out with a group present — the state that grew a grid, a checkbox and
    /// a per-family review block, all inside a fixed-width sheet.
    @Test func theSheetLaysOutWithAGroupPresent() throws {
        let rep = try #require(RestructureRender.raster(Self.sheet(), width: 620, height: 900))
        #expect(RestructureRender.inkedPixels(rep) > 2000)
    }

    /// **The mapping's sources widen to the group.** This is the rule the toggle drives, checked
    /// where it is decided: planning H-1B alone maps three names, and planning the trio together
    /// maps four — the fourth being `Application`, which only the siblings have and which is
    /// exactly the name a plan for H-1B alone would leave them disagreeing about.
    @Test func planningTogetherWidensTheSourcesToTheWholeGroup() {
        let families = ["Immigration/H-1B", "Immigration/H-4", "Immigration/H-4 EAD"]
        let alone = RestructurePlanner.distinctSources(family: "Immigration/H-1B",
                                                       members: ["2023", "2024"], in: Self.trio())
        #expect(alone == ["Approval", "Correspondence", "Petition"])

        let together = RestructurePlanner.groupSources(families: families, in: Self.trio())
        #expect(together == ["Application", "Approval", "Correspondence", "Petition"])
        #expect(Set(together).isSuperset(of: alone), "nothing the family had is lost")
    }
}
