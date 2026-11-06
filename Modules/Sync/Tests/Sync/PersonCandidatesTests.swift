import Foundation
import Testing
@testable import Sync

/// The household proposer's rule, on trees small enough to reason about. Whether the rule is any
/// good is measured on a real tree (`PersonCandidatesGroundTruthTests`); these pin what each clause
/// means, which a real tree can't isolate.
@Suite struct PersonCandidatesTests {

    // MARK: - What qualifies

    /// A direct child of a household folder is a person, on that folder's word alone.
    @Test func aChildOfAHouseholdFolderIsProposed() {
        let proposals = PersonCandidates.propose(tree: FixtureTree.of(["Family/Daughter", "Family/Son"]))
        #expect(Set(proposals.map(\.name)) == ["Daughter", "Son"])
    }

    /// A descendant is not a child: `Family` says what its children are, not its grandchildren.
    /// This clause cuts a real tree's proposals by about two thirds.
    @Test func aDescendantOfAHouseholdFolderIsNotProposed() {
        let proposals = PersonCandidates.propose(tree: FixtureTree.of(["Family/Photos/Reference"]))
        #expect(!proposals.map(\.name).contains("Reference"),
                "matching anywhere in the path is what proposed Reference(41) on the real tree")
        // `Photos` is a direct child of `Family`, so proposing it is the rule working: the
        // over-proposal the design accepts, one tick to refuse with `Family` shown as the reason.
        #expect(proposals.map(\.name) == ["Photos"])
    }

    /// Repetition on its own is not evidence of a person: on a real document tree, `Reference`,
    /// `Application` and `Statements` repeat more than any member of the household.
    @Test func aNameRepeatedAcrossBranchesIsNotProposedOnThatAlone() {
        let proposals = PersonCandidates.propose(tree: FixtureTree.of([
            "Finance/Statements", "Immigration/Statements", "Legal/Statements",
        ]))
        #expect(proposals.isEmpty)
    }

    @Test func everyHouseholdParentNameWorks() {
        for parent in PersonCandidates.householdParents {
            let proposals = PersonCandidates.propose(tree: FixtureTree.of(["\(parent)/Daughter"]))
            #expect(proposals.map(\.name) == ["Daughter"], "\(parent) did not read as a household folder")
        }
    }

    // MARK: - Shape

    /// All-caps names belong to the jurisdiction rule, and the two read the same tree.
    @Test func anAcronymIsNotAPerson() {
        for name in ["US", "EMP", "TODO", "IT"] {
            #expect(!PersonCandidates.isNameShaped(name), "\(name) read as a given name")
        }
    }

    @Test func aYearOrAPhraseIsNotAPerson() {
        for name in ["2024", "2024 Taxes", "Tax Returns", "a", "Ab"] {
            #expect(!PersonCandidates.isNameShaped(name))
        }
    }

    /// Names really do carry these, and excluding them would drop real people.
    @Test func aJoinedOrAccentedNameIsStillAName() {
        for name in ["Anne-Marie", "O'Brien", "Granny", "Uncle", "José"] {
            #expect(PersonCandidates.isNameShaped(name), "\(name) was refused as a name")
        }
    }

    @Test func theStoplistCoversWordsThatLookLikeNames() {
        let proposals = PersonCandidates.propose(tree: FixtureTree.of(["Family/Archive", "Family/Shared"]))
        #expect(proposals.isEmpty)
    }

    // MARK: - What it does not offer back

    /// Somebody already on the roster is not proposed again, in any spelling.
    @Test func aKnownPersonIsNotOfferedBack() {
        let tree = FixtureTree.of(["Family/Daughter", "Family/Son"])
        let proposals = PersonCandidates.propose(tree: tree, known: ["daughter"])
        #expect(proposals.map(\.name) == ["Son"], "offered a name the roster already has")
    }

    /// A name nested under itself is one branch, not two, as in `JurisdictionCandidates`.
    @Test func aNameUnderItselfDoesNotCountTwice() {
        let proposals = PersonCandidates.propose(tree: FixtureTree.of(["Family/Daughter/Daughter"]))
        #expect(proposals.map(\.name) == ["Daughter"])
        #expect(proposals.first?.folderCount == 1, "the nested copy was counted as a second folder")
    }

    // MARK: - Order

    /// Ranked by household evidence, and only then by size, or a big folder name like `Reference`
    /// outranks every real person. A name under two household folders leads one under a single
    /// household folder and a dozen other places.
    @Test func householdEvidenceOutranksFolderCount() {
        var paths = ["Family/Mother", "People/Mother", "Family/Reference"]
        paths += (1...12).map { "Work/Project\($0)/Reference" }
        let proposals = PersonCandidates.propose(tree: FixtureTree.of(paths))

        let names = proposals.map(\.name)
        #expect(names.first == "Mother",
                "ordered \(names) — the biggest name won instead of the best-evidenced one")
        let reference = proposals.first { $0.name == "Reference" }
        #expect(reference?.folderCount ?? 0 > proposals[0].folderCount,
                "the fixture no longer has a bigger impostor, so it proves nothing")
    }

    @Test func theOrderDoesNotWobbleBetweenRuns() {
        let tree = FixtureTree.of(["Family/Daughter", "Family/Son", "People/Daughter"])
        let first = PersonCandidates.propose(tree: tree).map(\.name)
        for _ in 0..<5 {
            #expect(PersonCandidates.propose(tree: tree).map(\.name) == first)
        }
    }

    // MARK: - Evidence

    /// Each proposal carries the parents that justify it, which is what the dialog shows.
    @Test func aProposalCarriesItsEvidence() throws {
        let proposals = PersonCandidates.propose(tree: FixtureTree.of(["Family/Daughter", "People/Daughter"]))
        let daughter = try #require(proposals.first)
        #expect(daughter.parents == ["Family", "People"])
        #expect(daughter.folderCount == 2)
        #expect(daughter.householdParents == 2)
    }

    /// The three sort keys in their documented order, on a fixture where evidence and size
    /// disagree: `Bulk` sits under one household folder and eight ordinary ones, `Nadia` under two
    /// and no others. Evidence-first puts Nadia ahead; size-first would put Bulk ahead.
    @Test func theOrderIsEvidenceFirstNotSizeFirst() throws {
        let tree = FixtureTree.of(["Family/Nadia", "People/Nadia"]
                             + ["Family/Bulk"]
                             + (1...8).map { "Work/Project\($0)/Bulk" })
        let proposals = PersonCandidates.propose(tree: tree)
        let nadia = try #require(proposals.firstIndex { $0.name == "Nadia" })
        let bulk = try #require(proposals.firstIndex { $0.name == "Bulk" })

        // The fixture proves what it claims to: size and evidence really do disagree here.
        let bulkCandidate = proposals[bulk], nadiaCandidate = proposals[nadia]
        #expect(bulkCandidate.folderCount > nadiaCandidate.folderCount,
                "the impostor is not bigger — a size-first sort would agree and this proves nothing")
        #expect(nadiaCandidate.householdParents > bulkCandidate.householdParents,
                "the person is not better evidenced — the fixture does not separate the two rules")

        #expect(nadia < bulk,
                "ordered \(proposals.map(\.name)) — size beat evidence, which is the ordering the comment beside the sort says was wrong")
    }

    /// Ties on both evidence and size break by name, ascending: the third key, which the
    /// comparator spells by swapping its operands rather than by negating.
    @Test func aTieBreaksByNameAscending() {
        let tree = FixtureTree.of(["Family/Zoya", "Family/Amara"])
        let names = PersonCandidates.propose(tree: tree).map(\.name)
        #expect(names == ["Amara", "Zoya"], "ordered \(names) — the name tie-break is inverted")
    }

    @Test func anEmptyTreeProposesNobody() {
        #expect(PersonCandidates.propose(tree: []).isEmpty)
    }
}
