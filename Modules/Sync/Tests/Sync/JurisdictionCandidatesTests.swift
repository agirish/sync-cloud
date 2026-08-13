import Foundation
import Testing
@testable import Sync

/// Pins ``JurisdictionCandidates`` — a proposer whose output is *confirmed by a person*, never
/// trusted.
///
/// The tests below deliberately include one that asserts a **known false positive is proposed**.
/// That is not a bug being enshrined: the rule is permissive on purpose because a human filters it,
/// and on the reference tree it invents `HPE`, `IT` and `PRD` while scoring 83.2% against a
/// hand-built profile that scores 100% when handed the confirmed values. A future tightening that
/// silently stops offering `HPE` should have to look at this test and decide, because the same
/// tightening is what drops `IN`.
@Suite struct JurisdictionCandidatesTests {

    /// Builds a directory tree from `"a/b/c"` paths. Files are never created here — the rule reads
    /// folder names, and a fixture that also carried files could pass by reading the wrong thing.
    private static func tree(_ paths: [String], root: String = "/root") -> [FileNode] {
        final class Box {
            var children: [String: Box] = [:]
            func child(_ name: String) -> Box {
                if let existing = children[name] { return existing }
                let made = Box(); children[name] = made; return made
            }
        }
        let top = Box()
        for path in paths {
            var here = top
            for component in path.split(separator: "/") { here = here.child(String(component)) }
        }
        func nodes(_ box: Box, prefix: String) -> [FileNode] {
            box.children.keys.sorted().map { name in
                let path = prefix + "/" + name
                return FileNode(id: path, name: name, isDirectory: true,
                                children: nodes(box.children[name]!, prefix: path))
            }
        }
        return nodes(top, prefix: root)
    }

    /// A genuine two-value split: both are proposed, each carrying the parents that are the
    /// evidence a dialog shows and the count of folders it would touch.
    @Test func aGenuineTwoValueSplitProposesBoth() {
        let candidates = JurisdictionCandidates.propose(tree: Self.tree([
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

    /// **The ≥3-parent rule, tested where it costs something.** `EU` lives under two parents and is
    /// not proposed; `IN`, in the same tree, is. A fixture that proposed nothing at all would pass
    /// with the whole rule deleted, so the refusal and the acceptance are measured together.
    @Test func aValueUnderTooFewParentsIsNotProposed() {
        let candidates = JurisdictionCandidates.propose(tree: Self.tree([
            "Finance/EU/VAT", "Legal/EU/GDPR",                       // two parents only
            "Finance/IN/Income Tax", "Legal/IN/Property", "School/IN/Certificates"
        ]), root: "/root")

        #expect(candidates.map(\.value) == ["IN"])
        #expect(candidates.first?.folderCount == 6)      // three `IN` folders and one child each
    }

    /// A single acronym under one parent — the `Work/HPE/Payslips` shape with nothing to
    /// generalise from — proposes nothing at all. The dialog is not opened for one folder.
    @Test func anAcronymUnderOneParentProposesNothing() {
        #expect(JurisdictionCandidates.propose(tree: Self.tree([
            "Work/HPE/Payslips", "Work/HPE/Reviews", "Work/HPE/Offers", "Personal/Notes"
        ]), root: "/root").isEmpty)
    }

    /// Ordering is by **folders affected**, not by parents and not alphabetically. The fixture is
    /// built so all three orders differ: `ZZ` sits under three parents but owns a deep subtree,
    /// `AB` sits under five parents and owns nothing.
    @Test func candidatesAreOrderedByHowManyFoldersTheyWouldAffect() {
        let candidates = JurisdictionCandidates.propose(tree: Self.tree([
            "One/AB", "Two/AB", "Three/AB", "Four/AB", "Five/AB",
            "Alpha/ZZ/a/deep/one", "Beta/ZZ/b/deep/two", "Gamma/ZZ/c"
        ]), root: "/root")

        #expect(candidates.map(\.value) == ["ZZ", "AB"], "ordered by parents or alphabetically")
        #expect(candidates[0].folderCount == 10)   // three `ZZ` folders plus seven below them
        #expect(candidates[0].parents.count == 3)
        #expect(candidates[1].folderCount == 5)
        #expect(candidates[1].parents.count == 5)
    }

    /// **A known false positive IS proposed, and that is the design.** `HPE` is an employer and
    /// `PRD` a product stage; both clear the bar on the reference tree, and both reach the user as
    /// a tick box beside `US`. Wiring this straight into a profile would write
    /// `jurisdiction: HPE` onto 40-odd folders and give the router a fact that does not exist.
    @Test func aKnownFalsePositiveIsProposedBecauseAPersonFiltersIt() {
        let candidates = JurisdictionCandidates.propose(tree: Self.tree([
            "Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts",
            "Work/HPE/Payslips", "Benefits/HPE/Dental", "Equity/HPE/Grants",
            "Docs/PRD/2024", "Specs/PRD/2025", "Archive/PRD/old"
        ]), root: "/root")

        let values = candidates.map(\.value)
        #expect(values.contains("HPE"))
        #expect(values.contains("PRD"))
        #expect(values.contains("US"))
        // And the evidence that lets a person tell them apart is carried, rather than the caller
        // being handed three bare strings: an employer's parents read nothing like a place's.
        #expect(candidates.first { $0.value == "HPE" }?.parents == ["Benefits", "Equity", "Work"])
        #expect(candidates.first { $0.value == "US" }?.parents == ["Finance", "Legal", "School"])
    }

    /// **The miss the dialog has to cover.** `Singapore` is a real jurisdiction on the reference
    /// tree (10 folders) and this rule cannot reach it: nine characters, and only two parents. The
    /// fixture reproduces both halves — a long name under three parents, and a short one under two
    /// — beside a value that *is* proposed, so the test cannot pass by proposing nothing.
    ///
    /// A confirmation dialog built on this must let the user ADD a value, or that tree's third
    /// jurisdiction can never be recorded at all.
    @Test func aRealValueThisRuleCannotReachIsAbsentFromTheProposals() {
        let candidates = JurisdictionCandidates.propose(tree: Self.tree([
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
        // **The upper bound, which nothing else here reaches.** The reference tree's only all-caps
        // name of four-plus characters under three or more parents is `TODO` — under 16 of them,
        // more than `US` — so a dropped cap proposes the inbox marker as the strongest
        // jurisdiction on the tree. This assertion is the one that catches that.
        #expect(!JurisdictionCandidates.isCandidateName("TODO"))
        #expect(!JurisdictionCandidates.isCandidateName("USCIS"))

        // And the same names refused through the real entry point, under enough parents to clear
        // every other bar — so a rule that only lived in the helper would still fail here.
        #expect(JurisdictionCandidates.propose(tree: Self.tree([
            "Finance/529/2023", "College/529/2024", "Savings/529/2025",
            "Utilities/PG&E/2023", "Bills/PG&E/2024", "Archive/PG&E/2025",
            "Health/TODO/Dental", "Work/TODO/Offers", "Legal/TODO/Scans"
        ]), root: "/root").isEmpty)
    }

    /// The root may be handed over either way — as the root node itself, or as its children — and
    /// both must name the same folders. Passing the root node in used to be the way to get every
    /// path prefixed with `Documents`, which no profile path carries.
    @Test func theRootItselfContributesNoValueAndNoPrefix() {
        let paths = ["Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts"]
        let children = JurisdictionCandidates.propose(tree: Self.tree(paths), root: "/root")
        let wrapped = JurisdictionCandidates.propose(
            tree: [FileNode(id: "/root", name: "root", isDirectory: true,
                            children: Self.tree(paths))],
            root: "/root")
        #expect(children == wrapped)
        #expect(wrapped.first?.parents == ["Finance", "Legal", "School"])
    }

    /// Files are not folders. A file called `US` inside a folder is not a jurisdiction, and it must
    /// not count toward either the parent bar or the blast radius.
    @Test func filesAreNotCounted() {
        let folders = Self.tree(["Finance/US/Tax", "Legal/US/Contracts", "School/US/Transcripts"])
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
}
