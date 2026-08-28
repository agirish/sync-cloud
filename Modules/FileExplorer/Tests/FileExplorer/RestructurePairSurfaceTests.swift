import Foundation
import SwiftUI
import Sync
import Testing
@testable import FileExplorer

/// `Plan…` on the merge kinds (the audit's G2): the lens's gate follows the route, the trigger's
/// promise matches the surface it opens, and the cross-parent confirm sheet renders what the
/// planner derived.
@MainActor
@Suite struct RestructurePairSurfaceTests {

    private static func mirroredFinding() -> StructureFinding {
        StructureFinding(kind: .mirroredInbox, family: "Health/TODO",
                         subject: "Health/TODO/Dental",
                         detail: .mirroredInbox(destination: "Health/Dental"))
    }

    private static func echoFinding() -> StructureFinding {
        StructureFinding(kind: .echoName, family: "Finance/Income Tax/2023/Forms",
                         subject: "Finance/Income Tax/2023/Forms/Form W2",
                         detail: .echoName(
                            counterpart: "Finance/Income Tax/2023/Forms/Form W-2",
                            relation: .sibling))
    }

    private static func tree(_ contents: [String: (folders: [String], files: [String])])
        -> RestructureTreeView {
        RestructureTreeView(childFolders: { contents[$0]?.folders },
                            files: { contents[$0]?.files },
                            fileCount: { contents[$0]?.files.count })
    }

    // MARK: The trigger

    /// The help text describes the surface that opens, and the three surfaces are different. All
    /// of them end with the same promise, because that is the one claim a person acts on.
    @Test func theTriggerPromisesTheSurfaceItOpens() {
        let shape = StructureFinding(kind: .shape, family: "Family/Events",
                                     subject: "Family/Events",
                                     schemes: [.init(vocabulary: ["photos"], members: ["A"])])
        let shapeHelp = RestructureLens.planHelp(for: shape)
        let seededHelp = RestructureLens.planHelp(for: Self.echoFinding())
        let pairHelp = RestructureLens.planHelp(for: Self.mirroredFinding())
        #expect(shapeHelp.contains("Choose the target shape"))
        #expect(seededHelp.contains("already filled in"))
        #expect(!seededHelp.contains("Choose the target shape"),
                "a pair has no shape to choose — the seeded row IS the mapping")
        #expect(pairHelp.contains("two folders"))
        for help in [shapeHelp, seededHelp, pairHelp] {
            #expect(help.contains("Opening the sheet moves nothing"),
                    "the safety half is said on every route")
        }
    }

    /// A report-only kind must not grow a trigger from this change — the gate is the route, and
    /// the route says no.
    @Test func aReportOnlyKindStillOffersNoPlan() {
        let loose = StructureFinding(kind: .looseAboveSeries, family: "Tax", subject: "Tax",
                                     detail: .looseAboveSeries(looseFiles: 4, seriesFolders: 3))
        #expect(!RestructurePlanRouting.carriesPlanSurface(loose))
    }

    /// A pair whose parent is a TOP-LEVEL folder makes the seeded family the empty string, since
    /// the family is the pair's grandparent. Everything downstream that renders it has to survive
    /// that: the sheet's header would otherwise be a blank line over the mapping.
    @Test func aTopLevelPairStillNamesItsFolderEverywhere() {
        let echo = StructureFinding(
            kind: .echoName, family: "Travel", subject: "Travel/Reciepts",
            detail: .echoName(counterpart: "Travel/Receipts", relation: .sibling))
        guard case .seededMapping(let family, let member, _, _)?
                = RestructurePlanRouting.route(for: echo) else {
            Issue.record("a sibling echo must seed the mapping")
            return
        }
        #expect(family.isEmpty, "the grandparent of a top-level folder is the tree itself")
        #expect(RestructurePlanSheet.headerPath(family: family, members: [member]) == "Travel")
        #expect(RestructureLens.familyHeading(family) == "Across the tree")
    }

    /// A family mapping keeps naming the family — the single-member spelling is for the seeded
    /// pair, and a shape finding always has more than one member.
    @Test func aFamilyMappingHeaderStillNamesTheFamily() {
        #expect(RestructurePlanSheet.headerPath(family: "Finance/US/Income Tax",
                                                members: ["2013", "2014"])
                    == "Finance/US/Income Tax")
    }

    // MARK: The confirm sheet

    @Test func thePairSheetNamesBothFolders() {
        #expect(RestructurePairMergeSheet.title(source: "Health/TODO/Dental",
                                                destination: "Health/Dental")
                    == "Merge Dental into Dental",
                "matching last components are told apart by the paths under the title")
        #expect(RestructurePairMergeSheet.title(source: "Work/Badge",
                                                destination: "Work/MapR/Badge")
                    == "Merge Badge into Badge")
    }

    /// A refusal is a sentence. An empty operation list with no explanation reads as "nothing to
    /// do", which is a different claim from "this could not be derived".
    @Test func everyRefusalHasWords() {
        let refusals: [RestructurePlanner.PlanRefusal] = [
            .nothingMapped,
            .unknownFiles(source: "A/Inbox"),
            .duplicateMappingRows(source: "Forms"),
            .unresolvableOrder(member: "A"),
            .conflictingTargets("Forms", "forms"),
            .targetTakenByCase(target: "Forms", standing: "forms", member: "2013"),
        ]
        for refusal in refusals {
            let text = RestructurePairMergeSheet.refusalText(refusal, source: "A")
            #expect(text.count > 20, "\(refusal) has no sentence")
        }
        #expect(RestructurePairMergeSheet.refusalText(.unknownFiles(source: "A/Inbox"),
                                                      source: "A").contains("A/Inbox"))
    }

    /// The operation verbs are the words the cards use, not the schema's wire values — a review
    /// screen reading `move-file` is showing its serialization.
    @Test func theOperationVerbsAreWordsNotRawValues() {
        for kind in [RestructureManifest.ActionKind.createDir, .renameDir, .moveDir,
                     .moveFile, .keep, .removeEmptyDir] {
            let verb = RestructurePairMergeSheet.verb(kind)
            #expect(!verb.contains("-"), "\(kind.rawValue) leaked its raw value")
        }
        #expect(RestructurePairMergeSheet.verb(.moveFile) == "move file")
    }

    @Test func thePairSheetRendersItsDerivedOperations() {
        let sheet = RestructurePairMergeSheet(
            source: "Health/TODO/Dental",
            destination: "Health/Dental",
            kind: .mirroredInbox,
            tree: Self.tree([
                "Health/TODO/Dental": (["Claims"], ["invoice.pdf"]),
                "Health/TODO/Dental/Claims": ([], ["claim.pdf"]),
                "Health/Dental": ([], ["other.pdf"]),
            ]),
            profileId: "p", accent: .blue,
            rationale: "A plan here merges the mirror into its destination — files would move.",
            onExport: { _ in .saved(filename: "f.json") },
            onApply: { _ in .applied(summary: "2 moved") },
            onClose: {})
        let hosting = NSHostingView(rootView: sheet.frame(width: 560, height: 420))
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 420)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width > 0)
    }

    // MARK: The call site

    /// The routing rule is testable on its own, and a revert that went back to gating on
    /// `finding.kind == .shape` would leave every test above green while five kinds lost their
    /// button again. This pins the wiring.
    @Test func theLensAndTheHostBothRouteThroughTheRule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FileExplorer (tests)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Modules/FileExplorer
            .appendingPathComponent("Sources/FileExplorer")
        let lens = try String(contentsOf: sources.appendingPathComponent("RestructureLens.swift"),
                              encoding: .utf8)
        #expect(lens.contains("RestructurePlanRouting.carriesPlanSurface(finding)"),
                "the trigger's gate is the route, not the kind")
        #expect(!lens.contains("finding.kind == .shape"),
                "gating on the kind is the shipped narrowing this change removes")

        let host = try String(
            contentsOf: sources.appendingPathComponent("LensWorkspaceView.swift"),
            encoding: .utf8)
        #expect(host.contains("RestructurePlanRouting.route(for: finding)"),
                "the host picks its sheet from the same rule the lens gates on")
        #expect(host.contains("RestructurePairMergeSheet("),
                "the cross-parent route has to reach a sheet")
    }
}
