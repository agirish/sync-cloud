import Testing
import Foundation
@testable import Sync

/// The structure detector — and, more importantly, the four controls it has to stay quiet about.
///
/// **A detector like this is judged by its silence.** On the real profile 247 folder names appear
/// under more than one parent and almost all of them are correct, so the interesting assertions
/// here are the negative ones: the families that look divergent to a naive rule and are not. The
/// three controls below (`Travel/Trips`, `Chase/Archive`, `Credit Accounts`) are the exact cases
/// that a score-based first cut got wrong, and each is here with the shape that broke it.
@Suite struct StructureDivergenceTests {

    // MARK: Fixtures

    private static func entry(_ path: String, axes: [String: String] = [:]) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [], acceptsNewFiles: true,
                           fileCount: 1, subfolderCount: 0, axes: axes)
    }

    /// Builds a profile from a list of folder paths, each optionally carrying axes.
    private static func profile(_ paths: [String], axes: [String: [String: String]] = [:]) -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for path in paths {
            folders[path] = entry(path, axes: axes[path] ?? [:])
        }
        return FolderProfile(profileId: "test", root: "/root", folders: folders, personTokens: [])
    }

    /// The real shape of `Finance/US/Income Tax`, cut down to the four eras and their vocabularies.
    private static var incomeTax: FolderProfile {
        var paths: [String] = []
        func year(_ y: String, _ children: [String]) {
            paths.append("Finance/US/Income Tax/\(y)")
            paths += children.map { "Finance/US/Income Tax/\(y)/\($0)" }
        }
        year("2013", ["Federal Tax", "State Tax (California)"])
        year("2014", ["Federal Tax", "State Tax (California)"])
        year("2016", ["Forms", "Reference", "Refund", "Transcripts"])
        year("2017", ["Forms", "Reference", "Refund", "Transcripts"])
        year("2018", ["Forms", "Reference", "Refund", "Transcripts", "Extras"])
        year("2024", ["Deductions", "Income", "Tax Records", "Tax Returns"])
        year("2025", ["Deductions", "Income", "Tax Records", "Tax Returns"])
        return profile(paths)
    }

    // MARK: It finds the thing it was built for

    @Test func theTaxYearsAreReportedAsOneFamilyWithItsEras() throws {
        let findings = StructureDivergence.findings(in: Self.incomeTax)
        let tax = try #require(findings.first { $0.family == "Finance/US/Income Tax" })
        // Three eras of two-or-more, not seven singletons and not one blob.
        #expect(tax.schemes.count == 3)
        #expect(tax.memberCount == 7)
        // Largest era first, so the reading order matches "what this mostly looks like".
        #expect(tax.schemes[0].members == ["2016", "2017", "2018"])
        // The scheme's vocabulary is the INTERSECTION: 2018's stray `Extras` is not advertised as
        // part of a convention the other two never had.
        #expect(tax.schemes[0].vocabulary == ["forms", "reference", "refund", "transcripts"])
    }

    @Test func aStrayExtraDoesNotSplitAnEraIntoSingletons() {
        // Single linkage, not complete: an era grows an extra folder in its later years and each
        // year is still recognisably the same scheme as the one before it. Exact-shape matching
        // shatters 2016–2023 into eight singletons over stray extras, and then the ≥2-members gate
        // discards all of them and the finding disappears entirely.
        let findings = StructureDivergence.findings(in: Self.incomeTax)
        let tax = findings.first { $0.family == "Finance/US/Income Tax" }
        #expect(tax?.schemes.allSatisfy { $0.members.count >= 2 } == true)
    }

    // MARK: The controls — what it must NOT say

    @Test func statesHoldingDifferentCitiesAreNotDivergent() {
        // `Travel/Trips/United States`: Arizona holds Phoenix, Nevada holds Las Vegas. Every
        // sibling differs from every other, which a similarity score reads as maximum divergence
        // — it rated this 1.00. The ≥2-groups-of-≥2 gate is what makes it silent: there is no
        // group of two that agrees on anything, so there is no convention to have departed from.
        let p = Self.profile([
            "Travel/Trips/United States/Arizona", "Travel/Trips/United States/Arizona/Phoenix",
            "Travel/Trips/United States/Nevada", "Travel/Trips/United States/Nevada/Las Vegas",
            "Travel/Trips/United States/Utah", "Travel/Trips/United States/Utah/Moab",
            "Travel/Trips/United States/Oregon", "Travel/Trips/United States/Oregon/Portland",
        ])
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }

    @Test func accountsFoldByDifferentYearsWithoutDiverging() {
        // `Chase/Archive`: each account ran for different years, so their children differ
        // completely — but a year is an axis value, not a role. Dropping them leaves every sibling
        // with an empty vocabulary, and an empty vocabulary carries no evidence either way.
        let p = Self.profile([
            "Finance/Chase/Archive/Checking", "Finance/Chase/Archive/Checking/2019",
            "Finance/Chase/Archive/Checking/2020",
            "Finance/Chase/Archive/Savings", "Finance/Chase/Archive/Savings/2021",
            "Finance/Chase/Archive/Savings/2022",
            "Finance/Chase/Archive/Credit", "Finance/Chase/Archive/Credit/2023",
            "Finance/Chase/Archive/Business", "Finance/Chase/Archive/Business/2024",
        ])
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }

    @Test func twoOfFourHavingABacklogFolderIsDriftNotAnEra() {
        // `Credit Accounts`: two of four carry a `TODO`, two do not. An inbox is an axis value —
        // it recurs legitimately and its absence is not a different convention.
        let p = Self.profile([
            "Finance/Credit Accounts/Amex", "Finance/Credit Accounts/Amex/Statements",
            "Finance/Credit Accounts/Amex/TODO",
            "Finance/Credit Accounts/Visa", "Finance/Credit Accounts/Visa/Statements",
            "Finance/Credit Accounts/Visa/TODO",
            "Finance/Credit Accounts/Discover", "Finance/Credit Accounts/Discover/Statements",
            "Finance/Credit Accounts/Citi", "Finance/Credit Accounts/Citi/Statements",
        ])
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }

    @Test func aLoneOddSiblingIsDriftNotDivergence() {
        // One folder out of five doing its own thing is a mistake to fix, not an era to reconcile.
        // Without the ≥2-members gate this reports, and "these siblings differ" is not a finding.
        let p = Self.profile([
            "Health/Dental/2021", "Health/Dental/2021/Claims", "Health/Dental/2021/Receipts",
            "Health/Dental/2022", "Health/Dental/2022/Claims", "Health/Dental/2022/Receipts",
            "Health/Dental/2023", "Health/Dental/2023/Claims", "Health/Dental/2023/Receipts",
            "Health/Dental/2024", "Health/Dental/2024/Paperwork",
        ])
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }

    @Test func identicalSiblingsAreHealthAndSaySoBySayingNothing() {
        // Vanguard's Roth and Traditional IRAs, four Chase accounts foldered the same way: a
        // *duplicated taxonomy* detector fires on these, which is why it is deliberately absent.
        let p = Self.profile([
            "Finance/Vanguard/Roth IRA", "Finance/Vanguard/Roth IRA/Statements",
            "Finance/Vanguard/Roth IRA/Tax Forms",
            "Finance/Vanguard/Traditional IRA", "Finance/Vanguard/Traditional IRA/Statements",
            "Finance/Vanguard/Traditional IRA/Tax Forms",
        ])
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }

    // MARK: The axis rules, directly

    @Test func anAxisValuedChildIsDroppedEvenWhenTheProfileIsTheOnlyThingThatKnows() {
        // A person folder is an axis value whose name is not a year and not an inbox — the profile
        // is the ONLY thing that can say so. Without reading `axes`, `Immigration/OCI` below reads
        // as two siblings with completely different vocabularies.
        let p = Self.profile(
            ["Immigration/OCI/Aditi", "Immigration/OCI/Aditi/Divit",
             "Immigration/OCI/Shweta", "Immigration/OCI/Shweta/Abhishek"],
            axes: ["Immigration/OCI/Aditi/Divit": ["person": "Divit"],
                   "Immigration/OCI/Shweta/Abhishek": ["person": "Abhishek"]])
        #expect(StructureDivergence.vocabulary(of: "Immigration/OCI/Aditi", in: p).isEmpty)
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }

    @Test func inheritedAxesDoNotSilenceEveryRoleFolderBeneathThem() {
        // **The bug the real tree caught and twelve green tests could not.** The live profile
        // propagates axes down a subtree: `Income Tax/2013/Federal Tax` carries `year: 2013` and
        // `jurisdiction: US` exactly as its ancestors do. A "carries an axis key?" test therefore
        // drops every role folder under a year, every vocabulary comes back empty, and the
        // detector reports NOTHING across 3,013 folders — silently, because silence is also what
        // a correct run looks like.
        //
        // Every fixture above puts the axis only on the folder that owns it, which is why none of
        // them could see it. This one is shaped like the real file.
        let p = Self.profile(
            ["Tax/2013", "Tax/2013/Federal", "Tax/2013/State",
             "Tax/2014", "Tax/2014/Federal", "Tax/2014/State",
             "Tax/2016", "Tax/2016/Forms", "Tax/2016/Refund",
             "Tax/2017", "Tax/2017/Forms", "Tax/2017/Refund"],
            axes: [
                "Tax/2013": ["year": "2013"], "Tax/2013/Federal": ["year": "2013"],
                "Tax/2013/State": ["year": "2013"],
                "Tax/2014": ["year": "2014"], "Tax/2014/Federal": ["year": "2014"],
                "Tax/2014/State": ["year": "2014"],
                "Tax/2016": ["year": "2016"], "Tax/2016/Forms": ["year": "2016"],
                "Tax/2016/Refund": ["year": "2016"],
                "Tax/2017": ["year": "2017"], "Tax/2017/Forms": ["year": "2017"],
                "Tax/2017/Refund": ["year": "2017"],
            ])
        // The role folders survive: they inherited the year, they did not introduce it.
        #expect(StructureDivergence.vocabulary(of: "Tax/2013", in: p) == ["federal", "state"])
        let findings = StructureDivergence.findings(in: p)
        #expect(findings.count == 1)
        #expect(findings.first?.schemes.count == 2)
    }

    @Test func aBareYearIsAnAxisValueWhetherOrNotTheProfileSaysSo() {
        #expect(StructureDivergence.isBareYear("2023"))
        #expect(StructureDivergence.isBareYear("1999"))
        // Not years: too short, too long, not numeric, and out of range.
        #expect(!StructureDivergence.isBareYear("202"))
        #expect(!StructureDivergence.isBareYear("20231"))
        #expect(!StructureDivergence.isBareYear("Forms"))
        #expect(!StructureDivergence.isBareYear("0042"))
    }

    @Test func onlyImmediateChildrenFormAFoldersVocabulary() {
        // A grandchild is the CHILD's vocabulary. Counting it here would make every folder's
        // vocabulary its whole subtree, and two eras that differ three levels down would read as
        // differing at the top.
        let p = Self.profile(["A/B", "A/B/C", "A/B/C/D"])
        #expect(StructureDivergence.vocabulary(of: "A/B", in: p) == ["c"])
    }

    // MARK: Non-vacuity

    @Test func theDetectorCanActuallyFireOnTheFixture() {
        // The controls above all assert emptiness, and a detector that returned `[]` unconditionally
        // would pass every one of them. This is the half that makes them mean something.
        #expect(!StructureDivergence.findings(in: Self.incomeTax).isEmpty)
    }

    @Test func anEmptyProfileFindsNothingWithoutCrashing() {
        let p = Self.profile([])
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }
}
