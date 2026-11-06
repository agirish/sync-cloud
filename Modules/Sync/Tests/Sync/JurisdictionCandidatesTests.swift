import Foundation
import Testing
@testable import Sync

/// Pins ``JurisdictionCandidates``, a proposer whose output a person confirms, never trusted.
/// One test asserts a known false positive is proposed. That is by design: the rule is permissive
/// because a human filters it, and on the reference tree it also offers `EMP`, `IT` and `PRD`. A
/// tightening that stops offering `EMP` should have to face that test, because the same tightening
/// drops `IN`.
@Suite struct JurisdictionCandidatesTests {

    /// A genuine two-value split: both are proposed, each carrying the parents that are the
    /// evidence a dialog shows and the count of folders it would touch.
    @Test func aGenuineTwoValueSplitProposesBoth() {
        let candidates = JurisdictionCandidates.propose(tree: FixtureTree.of([
            "Finance/US/Income Tax/2023", "Finance/US/Income Tax/2024", "Finance/US/Banking",
            "Finance/IN/Income Tax/2023",
            "Legal/US/Contracts", "Legal/IN/Property",
            "School/US/Transcripts", "School/IN/Certificates"
        ]), root: "/root")

        #expect(candidates.map(\.value) == ["US", "IN"])
        let us = candidates[0]
        #expect(us.parents == ["Finance", "Legal", "School"])
        // The blast radius, not the number of parents: the three `US` folders plus `Income Tax`,
        // its two years, `Banking`, `Contracts` and `Transcripts`.
        #expect(us.folderCount == 9)
        #expect(candidates[1].folderCount == 7)
        #expect(candidates[1].parents == ["Finance", "Legal", "School"])
    }

    /// The ≥3-parent rule: `EU` under two parents is not proposed, `IN` in the same tree is. The
    /// refusal and the acceptance are checked together, so proposing nothing can't pass.
    @Test func aValueUnderTooFewParentsIsNotProposed() {
        let candidates = JurisdictionCandidates.propose(tree: FixtureTree.of([
            "Finance/EU/VAT", "Legal/EU/GDPR",                       // two parents only
            "Finance/IN/Income Tax", "Legal/IN/Property", "School/IN/Certificates"
        ]), root: "/root")

        #expect(candidates.map(\.value) == ["IN"])
        #expect(candidates.first?.folderCount == 6)      // three `IN` folders and one child each
    }

    /// A single acronym under one parent (`Work/EMP/Payslips`, nothing to generalise from)
    /// proposes nothing, so the dialog doesn't open for one folder.
    @Test func anAcronymUnderOneParentProposesNothing() {
        #expect(JurisdictionCandidates.propose(tree: FixtureTree.of([
            "Work/EMP/Payslips", "Work/EMP/Reviews", "Work/EMP/Offers", "Personal/Notes"
        ]), root: "/root").isEmpty)
    }

    /// Ordering is by folders affected, not by parents and not alphabetically. The fixture makes
    /// all three orders differ: `ZZ` is under three parents with a deep subtree, `AB` under five
    /// with nothing below.
    @Test func candidatesAreOrderedByHowManyFoldersTheyWouldAffect() {
        let candidates = JurisdictionCandidates.propose(tree: FixtureTree.of([
            "One/AB", "Two/AB", "Three/AB", "Four/AB", "Five/AB",
            "Alpha/ZZ/a/deep/one", "Beta/ZZ/b/deep/two", "Gamma/ZZ/c"
        ]), root: "/root")

        #expect(candidates.map(\.value) == ["ZZ", "AB"], "ordered by parents or alphabetically")
        #expect(candidates[0].folderCount == 10)   // three `ZZ` folders plus seven below them
        #expect(candidates[0].parents.count == 3)
        #expect(candidates[1].folderCount == 5)
        #expect(candidates[1].parents.count == 5)
    }

    /// A known false positive is proposed, by design. `EMP` (an employer) and `PRD` (a product
    /// stage) clear the bar and reach the user as tick boxes beside `US`. Wired straight into a
    /// profile, this would stamp `jurisdiction: EMP` on dozens of folders: a fact that isn't so.
    @Test func aKnownFalsePositiveIsProposedBecauseAPersonFiltersIt() {
        let candidates = JurisdictionCandidates.propose(tree: FixtureTree.of([
            "Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts",
            "Work/EMP/Payslips", "Benefits/EMP/Dental", "Equity/EMP/Grants",
            "Docs/PRD/2024", "Specs/PRD/2025", "Archive/PRD/old"
        ]), root: "/root")

        let values = candidates.map(\.value)
        #expect(values.contains("EMP"))
        #expect(values.contains("PRD"))
        #expect(values.contains("US"))
        // The parents are carried so a person can tell them apart: an employer's read nothing
        // like a place's.
        #expect(candidates.first { $0.value == "EMP" }?.parents == ["Benefits", "Equity", "Work"])
        #expect(candidates.first { $0.value == "US" }?.parents == ["Finance", "Legal", "School"])
    }

    /// The miss the dialog has to cover. `Singapore` is a real jurisdiction on the reference tree
    /// that this rule can't reach: nine characters, and only two parents. The fixture has both (a
    /// long name under three parents, a short one under two) beside a value that is proposed, so
    /// proposing nothing can't pass. The dialog must let the user add a value, or that
    /// jurisdiction can never be recorded.
    @Test func aRealValueThisRuleCannotReachIsAbsentFromTheProposals() {
        let candidates = JurisdictionCandidates.propose(tree: FixtureTree.of([
            "Immigration/Visa/Singapore", "Travel/Trips/Singapore", "Legal/Singapore",  // too long
            "Finance/AE/Bank", "Legal/AE/Lease",                                        // two parents
            "Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts"
        ]), root: "/root")

        #expect(candidates.map(\.value) == ["US"])
        #expect(!candidates.contains { $0.value == "Singapore" })
        #expect(!candidates.contains { $0.value == "AE" })
    }

    /// Shape rules, each with a real counter-example on the tree: `529` is a college-savings folder
    /// under `Finance/US`, `PG&E` a utility, and `Us` an ordinary word. None of them is a place.
    @Test func onlyShortAllCapsLetterNamesAreOffered() {
        #expect(JurisdictionCandidates.isCandidateName("US"))
        #expect(JurisdictionCandidates.isCandidateName("PRD"))
        #expect(!JurisdictionCandidates.isCandidateName("529"))
        #expect(!JurisdictionCandidates.isCandidateName("PG&"))
        #expect(!JurisdictionCandidates.isCandidateName("Us"))
        #expect(!JurisdictionCandidates.isCandidateName("USA1"))
        #expect(!JurisdictionCandidates.isCandidateName("U"))
        // The upper bound, which nothing else here reaches. On the reference tree `TODO` sits
        // under more parents than `US`, so without the length cap the inbox marker would be
        // proposed as the strongest jurisdiction.
        #expect(!JurisdictionCandidates.isCandidateName("TODO"))
        #expect(!JurisdictionCandidates.isCandidateName("USCIS"))

        // The same names refused through the real entry point, under enough parents to clear
        // every other bar, so a rule that only lived in the helper would still fail here.
        #expect(JurisdictionCandidates.propose(tree: FixtureTree.of([
            "Finance/529/2023", "College/529/2024", "Savings/529/2025",
            "Utilities/PG&E/2023", "Bills/PG&E/2024", "Archive/PG&E/2025",
            "Health/TODO/Dental", "Work/TODO/Offers", "Legal/TODO/Scans"
        ]), root: "/root").isEmpty)
    }

    /// The root may be handed over as the root node itself or as its children, and both must name
    /// the same folders. The root's own name must not prefix the paths: no profile path carries it.
    @Test func theRootItselfContributesNoValueAndNoPrefix() {
        let paths = ["Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts"]
        let children = JurisdictionCandidates.propose(tree: FixtureTree.of(paths), root: "/root")
        let wrapped = JurisdictionCandidates.propose(
            tree: [FileNode(id: "/root", name: "root", isDirectory: true,
                            children: FixtureTree.of(paths))],
            root: "/root")
        #expect(children == wrapped)
        #expect(wrapped.first?.parents == ["Finance", "Legal", "School"])
    }

    /// Files are not folders. A file called `US` inside a folder is not a jurisdiction, and it must
    /// not count toward either the parent bar or the blast radius.
    @Test func filesAreNotCounted() {
        let folders = FixtureTree.of(["Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts"])
        var withFiles = folders
        withFiles.append(FileNode(id: "/root/Loose", name: "Loose", isDirectory: true, children: [
            FileNode(id: "/root/Loose/US", name: "US", isDirectory: false),
            FileNode(id: "/root/Loose/IN", name: "IN", isDirectory: false)
        ]))
        let candidates = JurisdictionCandidates.propose(tree: withFiles, root: "/root")
        #expect(candidates.map(\.value) == ["US"])
        #expect(candidates[0].parents == ["Finance", "Legal", "School"])
        #expect(candidates[0].folderCount == 6)
    }

    // MARK: - It counts the tree the survey actually walks

    /// Every number here promises what confirming a value would do, so it must be counted over the
    /// folders the survey really gives an entry to. ``FolderSurveyBuilder`` skips dot-directories
    /// and symlinks and gives an unexplored directory no entry, so none of those may count toward
    /// the evidence or the blast radius. A symlink is the easy one to miss:
    /// ``FileNode/isDirectory`` describes the link's target. All three kinds share one tree and are
    /// asserted through `parents`, the list the dialog shows, so dropping only some still fails.
    @Test func foldersTheSurveyWillNeverStampAreNotCounted() throws {
        let real = FixtureTree.of(["Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts"])
        let ignorable = [
            FileNode(id: "/root/.Trash", name: ".Trash", isDirectory: true, children: [
                FileNode(id: "/root/.Trash/US", name: "US", isDirectory: true,
                         children: [FileNode(id: "/root/.Trash/US/Old", name: "Old",
                                             isDirectory: true, children: [])])
            ]),
            FileNode(id: "/root/Linked", name: "Linked", isDirectory: true, children: [
                // A symlink whose target is a directory: `isDirectory` is the target's.
                FileNode(id: "/root/Linked/US", name: "US", isDirectory: true,
                         children: [FileNode(id: "/root/Linked/US/Copy", name: "Copy",
                                             isDirectory: true, children: [])],
                         isSymbolicLink: true)
            ]),
            FileNode(id: "/root/Capped", name: "Capped", isDirectory: true, children: [
                FileNode(id: "/root/Capped/US", name: "US", isDirectory: true, children: [],
                         isUnexplored: true)
            ])
        ]

        let candidates = JurisdictionCandidates.propose(tree: real + ignorable, root: "/root")

        let us = try #require(candidates.first { $0.value == "US" })
        #expect(us.parents == ["Finance", "Legal", "School"],
                "a dot-directory, a symlink or an unexplored folder reached the evidence the dialog shows")
        #expect(us.folderCount == 6,
                "the blast radius counted folders the survey never gives an entry to")
    }

    /// A value nested under itself doesn't clear the parents bar on its own.
    /// `minimumDistinctParents` exists because an axis value splits branches; counting every
    /// occurrence would let one branch supply all the evidence, since `A/US/B/US/C/US` yields three
    /// different parent strings for a value that splits nothing.
    @Test func aValueNestedUnderItselfDoesNotClearTheParentsBar() {
        let candidates = JurisdictionCandidates.propose(
            tree: FixtureTree.of(["A/US/B/US/C/US/Papers"]), root: "/root")
        #expect(!candidates.contains { $0.value == "US" },
                "one branch cleared the distinct-parents bar by nesting under itself")

        // The control: the same value across three real branches is still proposed, so the guard
        // cannot be passing by refusing everything.
        let genuine = JurisdictionCandidates.propose(tree: FixtureTree.of([
            "Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts",
        ]), root: "/root")
        #expect(genuine.contains { $0.value == "US" })
    }

    /// A folder whose path names the value twice is one folder. `folderCount` orders the list and
    /// is what the dialog reports, so a doubled count is a wrong number and can be a wrong order.
    /// The other three parents get `US` proposed; ten folders carry it (two per single-depth
    /// branch, plus `Taxes/US`, `…/Consulate`, `…/Consulate/US`, `…/Visa`). Counting per path
    /// component would give twelve.
    @Test func aValueRepeatedInOnePathCountsThatFolderOnce() throws {
        let candidates = JurisdictionCandidates.propose(tree: FixtureTree.of([
            "Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts",
            "Taxes/US/Consulate/US/Visa",
        ]), root: "/root")

        let us = try #require(candidates.first { $0.value == "US" })
        #expect(us.folderCount == 10,
                "a folder whose path repeats the value was counted once per occurrence")
    }
}
