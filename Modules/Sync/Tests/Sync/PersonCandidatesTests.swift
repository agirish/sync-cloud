import Foundation
import Testing
@testable import Sync

/// The household proposer's rule, on trees small enough to reason about.
///
/// The measurement that decides whether the rule is any *good* is machine-pinned
/// (`PersonCandidatesGroundTruthTests`); these pin what it means. Both are needed: a fixture cannot
/// tell you a rule proposes 214 names on a real tree, and a real tree cannot tell you which clause
/// did it.
@Suite struct PersonCandidatesTests {

    private static func tree(_ paths: [String]) -> [FileNode] {
        // Builds a nested tree from `A/B/C` strings, sharing parents.
        var roots: [String: FileNode] = [:]
        func insert(_ parts: ArraySlice<String>, into node: FileNode?) -> FileNode {
            let name = String(parts.first!)
            let rest = parts.dropFirst()
            let existingChildren = node?.children ?? []
            if rest.isEmpty {
                return FileNode(id: "/root/" + name, name: name, isDirectory: true,
                                children: existingChildren)
            }
            var children = existingChildren
            let childName = String(rest.first!)
            let existing = children.first { $0.name == childName }
            let rebuilt = insert(rest, into: existing)
            children.removeAll { $0.name == childName }
            children.append(rebuilt)
            return FileNode(id: "/root/" + name, name: name, isDirectory: true, children: children)
        }
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            let top = parts[0]
            roots[top] = insert(parts[...], into: roots[top])
        }
        return roots.values.sorted { $0.name < $1.name }
    }

    // MARK: - What qualifies

    /// A direct child of a household folder is a person, on that folder's word alone.
    @Test func aChildOfAHouseholdFolderIsProposed() {
        let proposals = PersonCandidates.propose(tree: Self.tree(["Family/Aditi", "Family/Divit"]))
        #expect(Set(proposals.map(\.name)) == ["Aditi", "Divit"])
    }

    /// **A descendant is not a child**, which is the clause that took the reference tree from 79
    /// proposals to 28. `Family` says what its children are; it says nothing about its grandchildren.
    @Test func aDescendantOfAHouseholdFolderIsNotProposed() {
        let proposals = PersonCandidates.propose(tree: Self.tree(["Family/Photos/Reference"]))
        #expect(!proposals.map(\.name).contains("Reference"),
                "matching anywhere in the path is what proposed Reference(41) on the real tree")
        // `Photos` IS a direct child of `Family`, so proposing it is the rule working — and it is
        // the over-proposal the design accepts: one tick to refuse, with `Family` shown as the
        // reason it was asked about.
        #expect(proposals.map(\.name) == ["Photos"])
    }

    /// Repetition on its own is not evidence of a person.
    ///
    /// The rule this replaced proposed on it, and on a real document tree `Reference`, `Application`
    /// and `Statements` outranked every member of the household.
    @Test func aNameRepeatedAcrossBranchesIsNotProposedOnThatAlone() {
        let proposals = PersonCandidates.propose(tree: Self.tree([
            "Finance/Statements", "Immigration/Statements", "Legal/Statements",
        ]))
        #expect(proposals.isEmpty)
    }

    @Test func everyHouseholdParentNameWorks() {
        for parent in PersonCandidates.householdParents {
            let proposals = PersonCandidates.propose(tree: Self.tree(["\(parent)/Aditi"]))
            #expect(proposals.map(\.name) == ["Aditi"], "\(parent) did not read as a household folder")
        }
    }

    // MARK: - Shape

    /// All-caps names belong to the jurisdiction rule, and the two read the same tree.
    @Test func anAcronymIsNotAPerson() {
        for name in ["US", "HPE", "TODO", "IT"] {
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
        for name in ["Anne-Marie", "O'Brien", "Muktha", "Anuraag", "José"] {
            #expect(PersonCandidates.isNameShaped(name), "\(name) was refused as a name")
        }
    }

    @Test func theStoplistCoversWordsThatLookLikeNames() {
        let proposals = PersonCandidates.propose(tree: Self.tree(["Family/Archive", "Family/Shared"]))
        #expect(proposals.isEmpty)
    }

    // MARK: - What it does not offer back

    /// Somebody already on the roster is not proposed again, in any spelling.
    @Test func aKnownPersonIsNotOfferedBack() {
        let tree = Self.tree(["Family/Aditi", "Family/Divit"])
        let proposals = PersonCandidates.propose(tree: tree, known: ["aditi"])
        #expect(proposals.map(\.name) == ["Divit"], "offered a name the roster already has")
    }

    /// A name nested under itself is one branch, not two — the correction
    /// `JurisdictionCandidates` needed for the same reason.
    @Test func aNameUnderItselfDoesNotCountTwice() {
        let proposals = PersonCandidates.propose(tree: Self.tree(["Family/Aditi/Aditi"]))
        #expect(proposals.map(\.name) == ["Aditi"])
        #expect(proposals.first?.folderCount == 1, "the nested copy was counted as a second folder")
    }

    // MARK: - Order

    /// Ranked by household evidence, and only then by size.
    ///
    /// **The count ordering put `Reference` above every real person on the reference tree.** This is
    /// that fixture in miniature: a name under two household folders leads one under a single
    /// household folder and forty other places.
    @Test func householdEvidenceOutranksFolderCount() {
        var paths = ["Family/Shweta", "People/Shweta", "Family/Reference"]
        paths += (1...12).map { "Work/Project\($0)/Reference" }
        let proposals = PersonCandidates.propose(tree: Self.tree(paths))

        let names = proposals.map(\.name)
        #expect(names.first == "Shweta",
                "ordered \(names) — the biggest name won instead of the best-evidenced one")
        let reference = proposals.first { $0.name == "Reference" }
        #expect(reference?.folderCount ?? 0 > proposals[0].folderCount,
                "the fixture no longer has a bigger impostor, so it proves nothing")
    }

    @Test func theOrderDoesNotWobbleBetweenRuns() {
        let tree = Self.tree(["Family/Aditi", "Family/Divit", "People/Aditi"])
        let first = PersonCandidates.propose(tree: tree).map(\.name)
        for _ in 0..<5 {
            #expect(PersonCandidates.propose(tree: tree).map(\.name) == first)
        }
    }

    // MARK: - Evidence

    /// Each proposal carries the parents that justify it, which is what the dialog shows.
    @Test func aProposalCarriesItsEvidence() throws {
        let proposals = PersonCandidates.propose(tree: Self.tree(["Family/Aditi", "People/Aditi"]))
        let aditi = try #require(proposals.first)
        #expect(aditi.parents == ["Family", "People"])
        #expect(aditi.folderCount == 2)
        #expect(aditi.householdParents == 2)
    }

    @Test func anEmptyTreeProposesNobody() {
        #expect(PersonCandidates.propose(tree: []).isEmpty)
    }
}
