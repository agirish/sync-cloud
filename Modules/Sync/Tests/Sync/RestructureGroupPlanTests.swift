import Foundation
import Testing
@testable import Sync

/// The family-group table and one shared mapping across it (proposal O17).
///
/// The fixture is the immigration trio the 6 Aug session actually worked on — three sibling
/// families whose child names nearly agree, and whose disagreements were invisible until someone
/// laid them side by side. That is the thing this table exists to make visible in one glance, so
/// it is the thing the tests are written against.
@Suite struct RestructureGroupPlanTests {

    /// H-1B, H-4 and H-4 EAD under `Immigration`, each with one member year holding the child
    /// names the 6 Aug notes record.
    ///
    /// **It clears `parallelFamilies`' own bar, and the first version did not.** That gate needs
    /// three shared names; the first fixture shared two, so `parallelFamilies` returned `[]` and
    /// every test below passed a family list the app could never have formed — the rules were
    /// right and nothing reachable called them. `theGateActuallyFormsThisGroup` is the test that
    /// keeps the fixture and the gate in step.
    private static func trio() -> RestructureTreeView {
        let children: [String: [String]] = [
            "Immigration": ["H-1B", "H-4", "H-4 EAD"],
            "Immigration/H-1B": ["2023"],
            "Immigration/H-1B/2023": ["Petition", "Approval", "Correspondence", "Receipts"],
            "Immigration/H-4": ["2023"],
            "Immigration/H-4/2023": ["Application", "Approval", "Correspondence", "Receipts"],
            "Immigration/H-4 EAD": ["2023"],
            "Immigration/H-4 EAD/2023": ["Application", "Approval", "Correspondence",
                                         "Receipts"],
        ]
        return RestructureTreeView(childFolders: { children[$0] },
                                   files: { _ in [] },
                                   fileCount: { _ in 1 })
    }

    private static let families = ["Immigration/H-1B", "Immigration/H-4", "Immigration/H-4 EAD"]

    // MARK: The gate that forms the group at all

    /// **`parallelFamilies` is the only producer of a group in the app**, so a fixture it refuses
    /// makes every test below vacuous — the rules exercised over a set nothing could construct.
    /// This is the test that ties the two together: the trio really is a group by the app's own
    /// bar, and the bar is still three.
    @Test func theGateActuallyFormsThisGroup() {
        let siblings = RestructurePlanner.parallelFamilies(of: "Immigration/H-1B", in: Self.trio())
        #expect(siblings.sorted() == ["H-4", "H-4 EAD"],
                "the trio is a group by the app's own rule, not just by this test's say-so")
        // And the bar is load-bearing: a family sharing two names is not a parallel. `Receipts`
        // is what takes the overlap from two to three.
        let narrower: [String: [String]] = [
            "P": ["A", "B"],
            "P/A": ["2023"], "P/A/2023": ["Approval", "Correspondence", "Petition"],
            "P/B": ["2023"], "P/B/2023": ["Approval", "Correspondence", "Application"],
        ]
        let view = RestructureTreeView(childFolders: { narrower[$0] }, files: { _ in [] },
                                       fileCount: { _ in 1 })
        #expect(RestructurePlanner.parallelFamilies(of: "P/A", in: view).isEmpty,
                "two shared names is under the bar — the noise it exists to exclude")
    }

    // MARK: The table

    /// One row per distinct name, one flag per family, **ordered so the disagreements collect at
    /// the bottom**: the names everyone shares are the spine, and the ones only one family has
    /// are the thing worth reading.
    @Test func theTableLaysTheGroupSideBySide() throws {
        let table = try #require(RestructurePlanner.familyGroupTable(families: Self.families,
                                                                     in: Self.trio()))
        #expect(table.families == Self.families)
        #expect(table.rows.map(\.name) == ["Approval", "Correspondence", "Receipts",
                                           "Application", "Petition"],
                "three-family names first, then two, then one — alphabetical inside each")

        let approval = try #require(table.rows.first { $0.name == "Approval" })
        #expect(approval.presentIn == [true, true, true])
        #expect(approval.isUniversal)

        let petition = try #require(table.rows.first { $0.name == "Petition" })
        #expect(petition.presentIn == [true, false, false], "H-1B alone has it")
        #expect(!petition.isUniversal)

        let application = try #require(table.rows.first { $0.name == "Application" })
        #expect(application.presentIn == [false, true, true])
    }

    /// The disagreement count is what the disclosure's header states, and what decides whether
    /// opening the grid is worth doing.
    @Test func theDisagreementsAreTheNamesNotEveryoneHas() throws {
        let table = try #require(RestructurePlanner.familyGroupTable(families: Self.families,
                                                                     in: Self.trio()))
        #expect(table.disagreements.map(\.name) == ["Application", "Petition"])

        // A group that already agrees has none — the header says so rather than showing an empty
        // grid under a count of zero.
        let agreeing: [String: [String]] = [
            "P": ["A", "B"], "P/A": ["2023"], "P/A/2023": ["Forms"],
            "P/B": ["2023"], "P/B/2023": ["Forms"],
        ]
        let flat = RestructureTreeView(childFolders: { agreeing[$0] }, files: { _ in [] },
                                       fileCount: { _ in 1 })
        let same = try #require(RestructurePlanner.familyGroupTable(families: ["P/A", "P/B"],
                                                                     in: flat))
        #expect(same.disagreements.isEmpty)
    }

    /// One family is not a group, and a group with no child names has no grid to draw.
    @Test func aTableNeedsTwoFamiliesAndSomethingInThem() {
        #expect(RestructurePlanner.familyGroupTable(families: ["Immigration/H-4"],
                                                    in: Self.trio()) == nil)
        #expect(RestructurePlanner.familyGroupTable(families: [], in: Self.trio()) == nil)
        let empty = RestructureTreeView(childFolders: { _ in [] }, files: { _ in [] },
                                        fileCount: { _ in 0 })
        #expect(RestructurePlanner.familyGroupTable(families: ["A", "B"], in: empty) == nil)
    }

    // MARK: One mapping, derived per family

    /// The sources one shared mapping is edited over: every name in the group, once.
    @Test func theGroupsSourcesAreTheUnionOfItsNames() {
        #expect(RestructurePlanner.groupSources(families: Self.families, in: Self.trio())
                == ["Application", "Approval", "Correspondence", "Petition", "Receipts"])
    }

    /// **Each family's manifest is derived against its own folders**, and a row naming a folder
    /// this family does not carry is simply not about it. Passing the shared mapping through
    /// whole would refuse a good plan on a name only a sibling has.
    @Test func oneMappingDerivesAManifestPerFamily() throws {
        let mapping = RestructureMapping(rows: [
            .init(source: "Application", target: "Petition"),
            .init(source: "Correspondence", target: "Letters"),
        ])
        let plans = RestructurePlanner.groupManifests(
            families: Self.families, mapping: mapping, kind: .shape, in: Self.trio(),
            profileId: "p", manifestIdPrefix: "m", createdAt: "t")

        #expect(plans.map(\.family) == Self.families, "asked-for order, so the columns line up")

        // H-1B has no `Application`, so only the Correspondence row is about it.
        let h1b = try #require(try plans[0].result.get())
        #expect(h1b.actions.contains { $0.src == "Immigration/H-1B/2023/Correspondence"
                                        && $0.dst == "Immigration/H-1B/2023/Letters" })
        #expect(!h1b.actions.contains { $0.src?.hasSuffix("Application") == true })

        // H-4 has both, and its `Application → Petition` is a plain rename because it has no
        // Petition of its own.
        let h4 = try #require(try plans[1].result.get())
        #expect(h4.actions.contains { $0.src == "Immigration/H-4/2023/Application"
                                       && $0.dst == "Immigration/H-4/2023/Petition" })

        // Every manifest carries its own id, so each landing is its own ledger record and its
        // own undo.
        let ids = plans.compactMap { try? $0.result.get() }.map(\.manifestId)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("m-") })
    }

    /// A family whose plan refuses stays in the result with its refusal — a group where one
    /// member cannot be planned is a thing to see, not to silently drop, and the other two are
    /// still landable.
    @Test func aFamilyThatRefusesStaysInTheResult() throws {
        // Two targets differing only in case cannot coexist on a case-insensitive volume, and
        // that refusal is per family because the derivation is.
        let mapping = RestructureMapping(rows: [
            .init(source: "Approval", target: "Forms"),
            .init(source: "Petition", target: "forms"),
        ])
        let plans = RestructurePlanner.groupManifests(
            families: Self.families, mapping: mapping, kind: .shape, in: Self.trio(),
            profileId: "p", manifestIdPrefix: "m", createdAt: "t")

        #expect(plans.count == 3, "nothing is dropped")
        if case .success = plans[0].result {
            Issue.record("H-1B has both rows and must refuse the case clash")
        }
        // H-4 and H-4 EAD have no Petition, so their narrowed mapping has one row and no clash.
        #expect((try? plans[1].result.get()) != nil)
        #expect((try? plans[2].result.get()) != nil)
    }

}
