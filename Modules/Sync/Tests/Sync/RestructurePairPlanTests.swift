import Testing
import Foundation
@testable import Sync

/// §5.4's plan surface on the merge kinds — the routing that decides which surface a finding
/// opens, and the cross-parent derivation the family mapping cannot express (the audit's G2).
@Suite struct RestructurePairPlanTests {

    // MARK: - Fixtures

    /// A tree view over a dictionary of folder → (folders, files). A path absent from the
    /// dictionary does not exist, which is the distinction the whole-move branch turns on.
    private static func view(_ tree: [String: (folders: [String], files: [String])])
        -> RestructureTreeView {
        RestructureTreeView(
            childFolders: { tree[$0]?.folders },
            files: { tree[$0]?.files },
            fileCount: { tree[$0]?.files.count })
    }

    private static func finding(kind: FindingKind, family: String, subject: String,
                                detail: StructureFinding.Detail?) -> StructureFinding {
        StructureFinding(kind: kind, family: family, subject: subject, detail: detail)
    }

    // MARK: - The geometry split

    /// A sibling echo and a shadowed year are both one row of a family mapping — but the family
    /// the mapping runs over is the pair's GRANDparent, because the mapping's unit is a child
    /// name inside a member. Pointing it at the parent would map the parent's siblings instead.
    @Test func aPairUnderOneParentSeedsTheMappingOverThatParent() {
        let echo = Self.finding(
            kind: .echoName, family: "Finance/Income Tax/2023/Forms",
            subject: "Finance/Income Tax/2023/Forms/Form W2",
            detail: .echoName(counterpart: "Finance/Income Tax/2023/Forms/Form W-2",
                              relation: .sibling))
        #expect(RestructurePlanRouting.route(for: echo)
                    == .seededMapping(family: "Finance/Income Tax/2023",
                                      member: "Forms",
                                      source: "Form W2", target: "Form W-2"))

        let shadow = Self.finding(
            kind: .shadowAxis, family: "Immigration/H-1B",
            subject: "Immigration/H-1B/IRS Docs - 2023",
            detail: .shadowAxis(target: "2023", targetExists: true))
        #expect(RestructurePlanRouting.route(for: shadow)
                    == .seededMapping(family: "Immigration", member: "H-1B",
                                      source: "IRS Docs - 2023", target: "2023"))
    }

    /// A shadowed year with no bare-year sibling is a rename rather than a merge — and it takes
    /// the SAME route, because the planner decides rename-or-merge from whether the target is
    /// standing. Two answers to that question is how the card and the plan disagree.
    @Test func aShadowedYearWithNoTargetTakesTheSameRoute() {
        let shadow = Self.finding(
            kind: .shadowAxis, family: "Immigration/H-1B",
            subject: "Immigration/H-1B/IRS Docs - 2024",
            detail: .shadowAxis(target: "2024", targetExists: false))
        #expect(RestructurePlanRouting.route(for: shadow)
                    == .seededMapping(family: "Immigration", member: "H-1B",
                                      source: "IRS Docs - 2024", target: "2024"))
    }

    @Test func theCrossParentKindsAskForAPairMerge() {
        let parentEcho = Self.finding(
            kind: .echoName, family: "Home/PG&E", subject: "Home/PG&E/PGE",
            detail: .echoName(counterpart: "Home/PG&E", relation: .parentChild))
        #expect(RestructurePlanRouting.route(for: parentEcho)
                    == .pairMerge(source: "Home/PG&E/PGE", destination: "Home/PG&E"))

        let mirrored = Self.finding(
            kind: .mirroredInbox, family: "Health/TODO", subject: "Health/TODO/Dental",
            detail: .mirroredInbox(destination: "Health/Dental"))
        #expect(RestructurePlanRouting.route(for: mirrored)
                    == .pairMerge(source: "Health/TODO/Dental", destination: "Health/Dental"))

        // The loose folder keeps its own name inside the container — the destination is
        // container/name, not the container itself, or the merge would empty it into the
        // container's own files.
        let loose = Self.finding(
            kind: .looseBesideContainer, family: "Work", subject: "Work/Badge",
            detail: .looseBesideContainer(container: "Work/MapR"))
        #expect(RestructurePlanRouting.route(for: loose)
                    == .pairMerge(source: "Work/Badge", destination: "Work/MapR/Badge"))
    }

    @Test func shapeKeepsItsWholeFamilyRouteAndTheReportOnlyKindsGetNone() {
        let shape = StructureFinding(kind: .shape, family: "Family/Events",
                                     subject: "Family/Events",
                                     schemes: [.init(vocabulary: ["photos"], members: ["A"])])
        #expect(RestructurePlanRouting.route(for: shape)
                    == .familyMapping(family: "Family/Events"))

        let backlog = Self.finding(kind: .backlog, family: "Health/Dental",
                                   subject: "Health/Dental/2026",
                                   detail: .backlog(scaffold: ["Claims"], looseFiles: 3))
        #expect(RestructurePlanRouting.route(for: backlog) == nil,
                "the scaffold is its own builder and its files go to To File")

        let loose = Self.finding(kind: .looseAboveSeries, family: "Tax", subject: "Tax",
                                 detail: .looseAboveSeries(looseFiles: 4, seriesFolders: 3))
        #expect(RestructurePlanRouting.route(for: loose) == nil)

        let taxonomy = Self.finding(
            kind: .duplicatedTaxonomy, family: "Work/MapR", subject: "Work/MapR/Forms",
            detail: .duplicatedTaxonomy(counterpart: "Tax/2016/Forms", matchedDocuments: 5))
        #expect(RestructurePlanRouting.route(for: taxonomy) == nil,
                "its pair is only trustworthy once a duplicate scan has measured it")
    }

    /// The lens gates its trigger on this, so it has to agree with the routes above rather than
    /// re-deriving the same judgement from the kind.
    @Test func theTriggerGateFollowsTheRoute() {
        let mirrored = Self.finding(
            kind: .mirroredInbox, family: "Health/TODO", subject: "Health/TODO/Dental",
            detail: .mirroredInbox(destination: "Health/Dental"))
        #expect(RestructurePlanRouting.carriesPlanSurface(mirrored))
        let loose = Self.finding(kind: .looseAboveSeries, family: "Tax", subject: "Tax",
                                 detail: .looseAboveSeries(looseFiles: 4, seriesFolders: 3))
        #expect(!RestructurePlanRouting.carriesPlanSurface(loose))
    }

    // MARK: - The cross-parent derivation

    /// The loose-folder card promises "moves one folder — its files ride along". With nothing of
    /// that name at the destination that is literally one `move-dir`, and the count it carries is
    /// what makes the ledger able to say how many files travelled.
    @Test func anAbsentDestinationIsOneWholeMove() throws {
        let tree = Self.view([
            "Work": (["Badge", "MapR"], []),
            "Work/Badge": ([], ["badge.pdf", "photo.jpg"]),
            "Work/MapR": (["Offer Letter"], []),
            "Work/MapR/Offer Letter": ([], ["offer.pdf"]),
        ])
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Work/Badge", destination: "Work/MapR/Badge", kind: .looseBesideContainer,
            in: tree, profileId: "p", manifestId: "m", createdAt: "t").get())
        #expect(manifest.actions.count == 1)
        let action = try #require(manifest.actions.first)
        #expect(action.action == .moveDir)
        #expect(action.src == "Work/Badge")
        #expect(action.dst == "Work/MapR/Badge")
        #expect(action.filesCarried == 2)
        #expect(manifest.family == "Work")
        #expect(manifest.kind == .looseBesideContainer)
    }

    /// A standing destination is drained into, never nested under. This is the mirrored-inbox
    /// shape: the inbox copy and the real folder both exist, and the inbox's contents move across
    /// file by file.
    @Test func aStandingDestinationIsMergedIntoNotNested() throws {
        let tree = Self.view([
            "Health/TODO/Dental": (["Claims"], ["invoice.pdf", "shared.pdf"]),
            "Health/TODO/Dental/Claims": ([], ["claim-1.pdf"]),
            "Health/Dental": ([], ["shared.pdf"]),
        ])
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Health/TODO/Dental", destination: "Health/Dental", kind: .mirroredInbox,
            in: tree, profileId: "p", manifestId: "m", createdAt: "t").get())
        #expect(!manifest.actions.contains {
            $0.action == .moveDir && $0.src == "Health/TODO/Dental"
        }, "a move-dir of the source onto the target would nest the inbox inside its destination")
        #expect(manifest.actions.map(\.action) == [.moveFile, .moveFile, .moveDir])
        #expect(manifest.actions[0].dst == "Health/Dental/invoice.pdf")
        #expect(manifest.actions[1].dst == "Health/Dental/shared.pdf")
        #expect(manifest.actions[1].collisionExpected == true,
                "the destination already holds a shared.pdf — the plan says so before it runs")
        #expect(manifest.actions[2].src == "Health/TODO/Dental/Claims")
        #expect(manifest.actions[2].dst == "Health/Dental/Claims")
        #expect(manifest.family == "Health")
    }

    /// A child echoing its parent moves UP one level. The source's own directory is left standing
    /// for the removal step — this planner never emits `remove-empty-dir`, mapped or paired.
    @Test func aChildEchoingItsParentDrainsUpwardAndLeavesItsShell() throws {
        let tree = Self.view([
            "Home/PG&E": (["PGE"], ["2024-bill.pdf"]),
            "Home/PG&E/PGE": ([], ["2023-bill.pdf"]),
        ])
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Home/PG&E/PGE", destination: "Home/PG&E", kind: .echoName,
            in: tree, profileId: "p", manifestId: "m", createdAt: "t").get())
        #expect(manifest.actions.map(\.action) == [.moveFile])
        #expect(manifest.actions[0].src == "Home/PG&E/PGE/2023-bill.pdf")
        #expect(manifest.actions[0].dst == "Home/PG&E/2023-bill.pdf")
        #expect(!manifest.actions.contains { $0.action == .removeEmptyDir },
                "the emptied source is the removal step's manifest, not this one's")
    }

    /// The containment test the refusal below leans on — by component, so `A/Bx` is not inside
    /// `A/B`. A character prefix would refuse a legitimate pair.
    @Test func containmentIsByComponent() {
        #expect(RestructurePaths.isInside("A/B/C", of: "A/B"))
        #expect(RestructurePaths.isInside("A/B", of: "A/B"), "a path contains itself")
        #expect(!RestructurePaths.isInside("A/Bx/C", of: "A/B"))
        #expect(!RestructurePaths.isInside("A", of: "A/B"))
    }

    // MARK: - Refusals

    @Test func aDestinationInsideItsOwnSourceIsRefused() {
        let tree = Self.view(["A": (["B"], []), "A/B": ([], [])])
        let result = RestructurePlanner.pairMergeManifest(
            source: "A", destination: "A/B", kind: .echoName, in: tree,
            profileId: "p", manifestId: "m", createdAt: "t")
        #expect(result == .failure(.unresolvableOrder(member: "A")))
    }

    @Test func aPairPointingAtItselfIsNothingToDo() {
        let tree = Self.view(["A": ([], ["f.pdf"])])
        #expect(RestructurePlanner.pairMergeManifest(
            source: "A", destination: "A", kind: .echoName, in: tree,
            profileId: "p", manifestId: "m", createdAt: "t") == .failure(.nothingMapped))
    }

    /// An empty source produces no operation, and an empty manifest must be a refusal rather than
    /// a landing that would write a junk ledger record.
    @Test func anEmptySourceRefusesRatherThanLandingNothing() {
        let tree = Self.view(["A/Inbox": ([], []), "A/Real": ([], ["f.pdf"])])
        #expect(RestructurePlanner.pairMergeManifest(
            source: "A/Inbox", destination: "A/Real", kind: .mirroredInbox, in: tree,
            profileId: "p", manifestId: "m", createdAt: "t") == .failure(.nothingMapped))
    }

    /// A view that cannot name the files inside the source refuses — a merge that cannot say what
    /// it moves is a guess, and the profile-backed view is exactly that view.
    @Test func aViewThatCannotNameFilesRefuses() {
        let profileLike = RestructureTreeView(
            childFolders: { ["A/Inbox": [], "A/Real": []][$0] },
            files: { _ in nil },
            fileCount: { _ in 1 })
        #expect(RestructurePlanner.pairMergeManifest(
            source: "A/Inbox", destination: "A/Real", kind: .mirroredInbox, in: profileLike,
            profileId: "p", manifestId: "m", createdAt: "t")
                    == .failure(.unknownFiles(source: "A/Inbox")))
    }

    // MARK: - The manifest is a manifest

    /// Whatever route derived it, a landing is undone by the mechanical inverse — so the pair
    /// merge has to satisfy the same involution law the mapped planner's manifests do.
    @Test func aPairMergeInvertsLikeAnyOtherManifest() throws {
        let tree = Self.view([
            "Work": (["Badge", "MapR"], []),
            "Work/Badge": ([], ["badge.pdf"]),
            "Work/MapR": ([], []),
        ])
        let manifest = try #require(try RestructurePlanner.pairMergeManifest(
            source: "Work/Badge", destination: "Work/MapR/Badge", kind: .looseBesideContainer,
            in: tree, profileId: "p", manifestId: "m", createdAt: "t").get())
        #expect(manifest.inverse.inverse == manifest)
        #expect(manifest.inverse.actions.first?.src == "Work/MapR/Badge")
        #expect(manifest.inverse.actions.first?.dst == "Work/Badge")
    }
}
