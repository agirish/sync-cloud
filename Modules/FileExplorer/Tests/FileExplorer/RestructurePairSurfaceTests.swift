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
            .invalidTargetName(target: "Tax/2024"),
            .targetTakenByFile(target: "Forms", member: "2013"),
        ]
        for refusal in refusals {
            let text = RestructurePairMergeSheet.refusalText(refusal, source: "A")
            #expect(text.count > 20, "\(refusal) has no sentence")
        }
        #expect(RestructurePairMergeSheet.refusalText(.unknownFiles(source: "A/Inbox"),
                                                      source: "A").contains("A/Inbox"))
        // The associated value, not the argument — they are the same on today's only route, so
        // a message naming the wrong folder would otherwise be undetectable.
        #expect(RestructurePairMergeSheet.refusalText(.unresolvableOrder(member: "Deep/Nested"),
                                                      source: "A").contains("Deep/Nested"))
    }

    /// The operation verbs are the words the cards use, not the schema's wire values — a review
    /// screen reading `move-file` is showing its serialization.
    @Test func theOperationVerbsAreWordsNotRawValues() {
        // Every one pinned: with only a no-hyphen check and one literal, five of the six could be
        // swapped for each other and nothing went red — a review list calling a create a rename
        // is worse than one showing the raw value.
        let expected: [RestructureManifest.ActionKind: String] = [
            .createDir: "create", .renameDir: "rename", .moveDir: "move folder",
            .moveFile: "move file", .keep: "keep", .removeEmptyDir: "remove",
        ]
        for kind in RestructureManifest.ActionKind.allCases {
            #expect(RestructurePairMergeSheet.verb(kind) == expected[kind])
            #expect(!RestructurePairMergeSheet.verb(kind).contains("-"))
        }
    }

    /// The card that opens this sheet says "Review 3 operations"; a button reading only "Apply"
    /// leaves the two disagreeing about what is about to happen.
    @Test func theApplyButtonCountsWhatItWouldRun() {
        let manifest = RestructureManifest(
            profileId: "p", manifestId: "m", createdAt: "t", family: "Work",
            kind: .looseBesideContainer,
            actions: [.init(action: .moveDir, src: "Work/Badge", dst: "Work/Acme/Badge")])
        #expect(RestructurePairMergeSheet.applyTitle(manifest: manifest, applying: false)
                    == "Apply 1 operation")
        // `keep` rows are the signature block. The card beside this button counts with
        // `operationCount`, so counting them here put "Apply 3 operations" under a card reading
        // "Review 1 operation" — the disagreement `applyTitle`'s own doc exists to prevent.
        var withKeeps = manifest
        withKeeps.actions += [.init(action: .keep, src: "a"), .init(action: .keep, src: "b")]
        #expect(RestructurePairMergeSheet.applyTitle(manifest: withKeeps, applying: false)
                    == "Apply 1 operation")
        #expect(withKeeps.operationCount == 1)

        var three = manifest
        three.actions += [.init(action: .moveFile, src: "x", dst: "y"),
                          .init(action: .moveFile, src: "p", dst: "q")]
        #expect(RestructurePairMergeSheet.applyTitle(manifest: three, applying: false)
                    == "Apply 3 operations")
        #expect(RestructurePairMergeSheet.applyTitle(manifest: three, applying: true)
                    == "Applying…")
        #expect(RestructurePairMergeSheet.applyTitle(manifest: nil, applying: false) == "Apply")
    }

    /// A parent/child echo is four of the five echo hits on the real tree, and both folders wear
    /// the same word — "Merge IRS into IRS" names neither.
    @Test func aTitleWhoseTwoNamesMatchStatesTheRelationInstead() {
        #expect(RestructurePairMergeSheet.title(source: "Finance/TODO/IRS/IRS",
                                                destination: "Finance/TODO/IRS")
                    == "Merge IRS into its parent")
        #expect(RestructurePairMergeSheet.title(source: "Work/Badge",
                                                destination: "Work/Acme/Badge")
                    == "Merge Badge into Acme/Badge")
        #expect(RestructurePairMergeSheet.title(source: "Health/TODO/Dental",
                                                destination: "Health/Dental")
                    == "Merge Dental into Health/Dental")
    }

    @Test func thePairSheetRendersItsDerivedOperations() throws {
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
        // An ink floor, not a width: `fittingSize.width > 0` is true of an empty
        // `VStack`, so it passed with the subject of this test deleted.
        let rep = try #require(RestructureRender.raster(sheet, width: 560, height: 420))
        #expect(RestructureRender.inkedPixels(rep) > 1000)
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
        // Scoped to the trigger's own gate rather than the whole 1,300-line file: a legitimate
        // future `finding.kind == .shape` anywhere else is not this defect.
        let trigger = try #require(lens.range(of: "if let onPlan,"))
        #expect(!lens[trigger.lowerBound...].prefix(400).contains("finding.kind == .shape"),
                "gating on the kind is the shipped narrowing this change removes")

        let host = try String(
            contentsOf: sources.appendingPathComponent("LensWorkspaceView.swift"),
            encoding: .utf8)
        #expect(host.contains("RestructurePlanRouting.route(for: finding)"),
                "the host picks its sheet from the same rule the lens gates on")
        #expect(host.contains("case .pairMerge(let source, let destination):"),
                "pin the ARM: a bare type-name grep was satisfied by the unused private helper")
        #expect(host.contains("case .seededMapping(let family, let member, let source, "
                              + "let target):"))
        #expect(host.contains("?? seeded.map { [$0] }"),
                "the seed is the whole promise of \"already filled in\"")
    }

    // MARK: The row text — names, not truncated paths

    /// **A row names what moves, not where it already is.** Both folders are in the header, and
    /// every row of a pair merge runs between those two — so repeating them spent the row's whole
    /// width on what the reader knew and truncated what they did not. On the real tree this read
    /// `…on/Form ETA-9035 (DOL).pdf → …n/Form ETA-9035 (DOL).pdf`: two ellipses, no answer.
    @Test func anOrdinaryRowIsJustTheFileName() {
        let action = RestructureManifest.Action(
            action: .moveFile,
            src: "Immigration/Authorization/H-1B/2021-2024/Petition/Petition/Form I-129.pdf",
            dst: "Immigration/Authorization/H-1B/2021-2024/Petition/Form I-129.pdf")
        let row = RestructurePairMergeSheet.rowText(
            action,
            source: "Immigration/Authorization/H-1B/2021-2024/Petition/Petition",
            destination: "Immigration/Authorization/H-1B/2021-2024/Petition")
        #expect(row.name == "Form I-129.pdf")
        #expect(row.detail == nil, "it goes where the header says everything goes")
    }

    /// A file nested inside the source keeps the part of its path that is not the source folder —
    /// dropping to the leaf alone would show two rows as identical names.
    @Test func aNestedFileKeepsWhatDistinguishesIt() {
        let action = RestructureManifest.Action(
            action: .moveFile, src: "A/Inbox/2024/receipt.pdf", dst: "A/Real/2024/receipt.pdf")
        let row = RestructurePairMergeSheet.rowText(action, source: "A/Inbox",
                                                    destination: "A/Real")
        #expect(row.name == "2024/receipt.pdf")
        #expect(row.detail == nil,
                "a merge preserves structure, so the mirrored landing repeats the name back")
    }

    /// **A row that does something the header does not describe says so.** A collision rename and
    /// a landing outside the common destination are exactly the rows a reader must not miss, and
    /// they are the ones a leaf-only row would hide.
    @Test func aRowThatDivergesFromTheHeaderSaysHow() {
        let renamed = RestructurePairMergeSheet.rowText(
            RestructureManifest.Action(action: .moveFile, src: "A/Inbox/tax.pdf",
                                       dst: "A/Real/tax 2.pdf"),
            source: "A/Inbox", destination: "A/Real")
        #expect(renamed.name == "tax.pdf")
        #expect(renamed.detail == "as tax 2.pdf", "the collision's new name is on the row")

        let elsewhere = RestructurePairMergeSheet.rowText(
            RestructureManifest.Action(action: .moveDir, src: "A/Inbox/Forms",
                                       dst: "A/Somewhere Else/Forms"),
            source: "A/Inbox", destination: "A/Real")
        #expect(elsewhere.detail?.contains("A/Somewhere Else/Forms") == true,
                "a destination the header never named is stated in full")

        // A file landing somewhere else UNDER the destination names the place, not the path.
        let deeper = RestructurePairMergeSheet.rowText(
            RestructureManifest.Action(action: .moveFile, src: "A/Inbox/tax.pdf",
                                       dst: "A/Real/2024/tax.pdf"),
            source: "A/Inbox", destination: "A/Real")
        #expect(deeper.detail == "into 2024/tax.pdf")
    }

    /// `relative` is component-wise — a sibling sharing a name prefix is not a child.
    @Test func theSourcePrefixIsStrippedByComponentNotByCharacter() {
        #expect(RestructurePairMergeSheet.relative(of: "A/Inbox/x.pdf", under: "A/Inbox")
                == "x.pdf")
        #expect(RestructurePairMergeSheet.relative(of: "A/InboxOld/x.pdf", under: "A/Inbox")
                == nil, "InboxOld is another folder, not a child of Inbox")
        #expect(RestructurePairMergeSheet.relative(of: "A/Inbox", under: "A/Inbox") == nil)
    }

    // MARK: The safe button says what it is for

    /// It was labelled "Export plan…" with no help at all — a file format for a name, and nothing
    /// about why anyone would press it. Both of the things it does have to be in the sentence,
    /// because the durable one (the card remembers) is the one people actually want.
    @Test func theSaveButtonExplainsBothOfTheThingsItDoes() {
        let help = RestructurePairMergeSheet.exportHelp
        #expect(help.contains("Review N operations"), "the card state it produces")
        #expect(help.contains("after you quit"), "and that it survives one")
        #expect(help.contains("JSON"), "the file, for anyone who wants to read it")
        #expect(help.contains("Nothing moves"), "the reassurance the red button needs beside it")
    }

    // MARK: Both paths reach the pixels

    /// **The two folders are the sheet's whole subject, and they were the first thing truncated.**
    /// Rendered at the minimum width, a deep source and a deep destination must still draw
    /// differently from a shallow pair — a header that clipped both to `…/Petition` would not.
    @Test func bothFullPathsAreDrawnEvenWhenDeep() throws {
        func sheet(source: String, destination: String) -> RestructurePairMergeSheet {
            RestructurePairMergeSheet(
                source: source, destination: destination, kind: .echoName,
                tree: RestructureTreeView(childFolders: { _ in [] },
                                          files: { $0 == source ? ["Form I-129.pdf"] : [] },
                                          fileCount: { _ in 1 }),
                profileId: "p", accent: .blue, rationale: "echoes its parent",
                onExport: { _ in .saved(filename: "f.json") }, onClose: {})
        }
        let deep = try #require(RestructureRender.raster(
            sheet(source: "Immigration/Authorization/H-1B/2021-2024/Petition/Petition",
                  destination: "Immigration/Authorization/H-1B/2021-2024/Petition"),
            width: 520, height: 460))
        let shallow = try #require(RestructureRender.raster(
            sheet(source: "A/B", destination: "A"), width: 520, height: 460))
        #expect(RestructureRender.inkedPixels(deep) > 1000, "the sheet drew")
        #expect(RestructureRender.differingPixels(deep, shallow) > 400,
                "the paths themselves are on screen, not one shared ellipsis")
    }
}
