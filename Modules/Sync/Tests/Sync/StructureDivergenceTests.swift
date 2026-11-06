import Testing
import Foundation
@testable import Sync

/// The structure detector, and the controls it must stay quiet about. A detector like this is
/// judged by its silence: in a real profile hundreds of folder names appear under more than one
/// parent and almost all are correct, so the important assertions are the negative ones. The
/// controls (`Travel/Trips`, `Chase/Archive`, `Credit Accounts`) are families a naive
/// similarity-score rule reports as divergent, each in the shape that fools it.
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
        // The scheme's vocabulary is the intersection: 2018's stray `Extras` is not advertised as
        // part of a convention the other two never had.
        #expect(tax.schemes[0].vocabulary == ["forms", "reference", "refund", "transcripts"])
    }

    @Test func aStrayExtraDoesNotSplitAnEraIntoSingletons() {
        // Single linkage, not complete: an era grows an extra folder in later years and each year
        // still matches the one before. Exact-shape matching would shatter an era into singletons
        // over stray extras, the ≥2-members gate would discard them all, and the finding would
        // vanish.
        let findings = StructureDivergence.findings(in: Self.incomeTax)
        let tax = findings.first { $0.family == "Finance/US/Income Tax" }
        #expect(tax?.schemes.allSatisfy { $0.members.count >= 2 } == true)
    }

    // MARK: The controls — what it must NOT say

    @Test func statesHoldingDifferentCitiesAreNotDivergent() {
        // `Travel/Trips/United States`: Arizona holds Phoenix, Nevada holds Las Vegas. Every
        // sibling differs from every other, which a similarity score reads as maximum divergence.
        // The ≥2-groups-of-≥2 gate keeps it silent: no group of two agrees on anything, so there
        // is no convention to depart from.
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
        // completely, but a year is an axis value, not a role. Dropping them leaves every sibling
        // with an empty vocabulary, and an empty vocabulary is no evidence either way.
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
        // `Credit Accounts`: two of four carry a `TODO`, two don't. An inbox is an axis value: it
        // recurs legitimately and its absence is not a different convention.
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
        // Vanguard's Roth and Traditional IRAs, foldered the same way: a name-based
        // duplicated-taxonomy rule would fire on these, which is why neither detector does.
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
        // A person folder is an axis value whose name is neither a year nor an inbox, and only the
        // profile can say so. Without reading `axes`, `Immigration/OCI` below reads as two siblings
        // with completely different vocabularies.
        let p = Self.profile(
            ["Immigration/OCI/Daughter", "Immigration/OCI/Daughter/Son",
             "Immigration/OCI/Mother", "Immigration/OCI/Mother/Father"],
            axes: ["Immigration/OCI/Daughter/Son": ["person": "Son"],
                   "Immigration/OCI/Mother/Father": ["person": "Father"]])
        #expect(StructureDivergence.vocabulary(of: "Immigration/OCI/Daughter", in: p).isEmpty)
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }

    @Test func inheritedAxesDoNotSilenceEveryRoleFolderBeneathThem() {
        // A real profile propagates axes down a subtree: `Income Tax/2013/Federal Tax` carries
        // `year: 2013` exactly as its ancestors do. A "carries an axis key?" test would drop every
        // role folder under a year, every vocabulary would come back empty, and the detector would
        // report nothing, silently, since silence is also what a correct run looks like. The
        // fixtures above put each axis only on the folder that owns it; this one is shaped like the
        // real file.
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
        // The role folders survive: they inherited the year, they didn't introduce it.
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
        // A grandchild is the child's vocabulary. Counting it here would make every folder's
        // vocabulary its whole subtree, and two eras that differ three levels down would read as
        // differing at the top.
        let p = Self.profile(["A/B", "A/B/C", "A/B/C/D"])
        #expect(StructureDivergence.vocabulary(of: "A/B", in: p) == ["c"])
    }

    // MARK: Non-vacuity

    @Test func theDetectorCanActuallyFireOnTheFixture() {
        // The controls above all assert emptiness, and a detector that always returned `[]` would
        // pass every one of them. This is the half that makes them mean something.
        #expect(!StructureDivergence.findings(in: Self.incomeTax).isEmpty)
    }

    @Test func anEmptyProfileFindsNothingWithoutCrashing() {
        let p = Self.profile([])
        #expect(StructureDivergence.findings(in: p).isEmpty)
    }

    // MARK: Single linkage means single linkage

    /// A bridging sibling joins the two groups it bridges. If clustering never merged groups, A and
    /// B seeded apart would stay apart even when C is close to both, the finding would report two
    /// schemes for a family that agrees transitively, and the grouping would depend on walk order.
    @Test func aBridgingSiblingMergesTheGroupsItBridges() {
        // A and B share nothing; C shares heavily with each, so single linkage puts all three
        // together. (`StructureDivergence.AgreementRule.similarity` is the threshold for each pair.)
        let a = (name: "2019", words: Set(["statements", "notices"]))
        let b = (name: "2020", words: Set(["receipts", "invoices"]))
        let c = (name: "2021", words: Set(["statements", "notices", "receipts", "invoices"]))

        // The premise, so this can't pass by the thresholds drifting: C really is close to both
        // ends, and the ends really are not close to each other.
        #expect(StructureDivergence.jaccard(a.words, c.words) >= StructureDivergence.AgreementRule.similarity)
        #expect(StructureDivergence.jaccard(b.words, c.words) >= StructureDivergence.AgreementRule.similarity)
        #expect(StructureDivergence.jaccard(a.words, b.words) < StructureDivergence.AgreementRule.similarity)

        let groups = StructureDivergence.cluster([a, b, c])
        let shown = groups.map { $0.map(\.name).joined(separator: "+") }.joined(separator: " | ")
        #expect(groups.count == 1,
                "\(groups.count) schemes for a family that agrees transitively: \(shown)")
        #expect(groups.first?.count == 3)
    }

    /// Membership doesn't depend on walk order: the same three folders in any order give the same
    /// grouping.
    @Test func theGroupingDoesNotDependOnTheOrderTheChildrenAreWalkedIn() {
        let a = (name: "2019", words: Set(["statements", "notices"]))
        let b = (name: "2020", words: Set(["receipts", "invoices"]))
        let c = (name: "2021", words: Set(["statements", "notices", "receipts", "invoices"]))
        for ordering in [[a, b, c], [c, a, b], [b, c, a], [b, a, c]] {
            let names = StructureDivergence.cluster(ordering).map { Set($0.map(\.name)) }
            #expect(names == [Set(["2019", "2020", "2021"])],
                    "order \(ordering.map(\.name)) produced \(names)")
        }
    }

    /// Three groups bridged at once, the only shape that exercises the descending removal. With
    /// two, `bridged.dropFirst()` has one element and `.reversed()` is a no-op; with three, removing
    /// at ascending indices shifts the ones still to move and loses a group or traps.
    @Test func oneItemCanMergeThreeGroupsAtOnce() {
        // Each end shares exactly half of the bridge's vocabulary (0.5, the threshold) while no two
        // ends reach it between themselves (0 and 0.33). A bridge can't reach three mutually
        // disjoint ends (each needs half the bridge, and three halves don't fit), so the ends
        // overlap a little, below the bar. The premise checks below prove both.
        let a = (name: "2019", words: Set(["statements", "notices"]))
        let b = (name: "2020", words: Set(["receipts", "invoices"]))
        let c = (name: "2021", words: Set(["notices", "receipts"]))
        let bridge = (name: "2022", words: Set(["statements", "notices", "receipts", "invoices"]))
        for pair in [(a, b), (a, c), (b, c)] {
            #expect(StructureDivergence.jaccard(pair.0.words, pair.1.words)
                    < StructureDivergence.AgreementRule.similarity,
                    "\(pair.0.name) and \(pair.1.name) already agree — nothing to bridge")
        }
        for end in [a, b, c] {
            #expect(StructureDivergence.jaccard(end.words, bridge.words)
                    >= StructureDivergence.AgreementRule.similarity,
                    "the bridge does not reach \(end.name)")
        }

        let groups = StructureDivergence.cluster([a, b, c, bridge])
        #expect(groups.count == 1,
                "three groups bridged by one sibling came out as \(groups.map { $0.map(\.name) })")
        #expect(groups.first?.map(\.name) == ["2019", "2020", "2021", "2022"],
                "the merged members are not in profile order: \(groups.first?.map(\.name) ?? [])")
    }

    /// Members come back in the order the survey walked them, which
    /// ``StructureFinding/Scheme/members`` documents and the scheme sort's tiebreaker reads.
    /// Appending merged groups end to end would give `[A₀, A₂, B₁, B₃, C₄]` here.
    @Test func mergedMembersKeepProfileOrder() {
        let items = [(name: "A0", words: Set(["alpha"])),
                     (name: "B1", words: Set(["beta"])),
                     (name: "A2", words: Set(["alpha"])),
                     (name: "B3", words: Set(["beta"])),
                     (name: "C4", words: Set(["alpha", "beta"]))]
        let groups = StructureDivergence.cluster(items)
        #expect(groups.count == 1)
        #expect(groups.first?.map(\.name) == ["A0", "B1", "A2", "B3", "C4"])
    }

    /// The other direction, so the merge isn't simply collapsing everything: two unrelated schemes
    /// with nothing bridging them stay two.
    @Test func twoSchemesWithNothingBetweenThemStayTwo() {
        let a = (name: "2019", words: Set(["statements", "notices"]))
        let b = (name: "2020", words: Set(["receipts", "invoices"]))
        #expect(StructureDivergence.cluster([a, b]).count == 2)
    }

    // MARK: - The lens over a profile the app derived for itself

    /// ROADMAP v5 §4.2 says this lens returns the same finding from a walk-derived profile as from
    /// a hand-built one; this asserts it. The comparison is against the same profile given
    /// `naming`, the one field a walk can't derive and a hand-built profile carries. If the lens
    /// starts reading that field, the two stop matching.
    ///
    /// What it doesn't pin: a derived profile against a real hand-built one, which also differs in
    /// `axes` and `anchors`, both of which the lens does read. That stays measured, not asserted.
    /// The first expectation is the non-vacuity guard: two profiles with no findings would compare
    /// equal and prove nothing.
    @Test func theLensSeesTheSameThingInADerivedProfileAsInAHandBuiltOne() throws {
        func dir(_ name: String, _ children: [FileNode] = []) -> FileNode {
            FileNode(id: "/x/\(name)", name: name, isDirectory: true, children: children)
        }
        func leaf(_ name: String) -> FileNode {
            dir(name, [FileNode(id: "/x/\(name)/f.pdf", name: "f.pdf", isDirectory: false)])
        }
        // Two eras that disagree: three years of statements/notices, two of receipts/invoices.
        let tree = [dir("Finance", [dir("Income Tax", [
            dir("2016", [leaf("Statements"), leaf("Notices")]),
            dir("2017", [leaf("Statements"), leaf("Notices")]),
            dir("2018", [leaf("Statements"), leaf("Notices")]),
            dir("2019", [leaf("Receipts"), leaf("Invoices")]),
            dir("2020", [leaf("Receipts"), leaf("Invoices")]),
        ])])]
        let derived = FolderSurveyBuilder.build(tree: tree, root: "~/Documents", profileId: "t",
                                                registry: nil, jurisdictionValues: [])

        let fromDerived = StructureDivergence.findings(in: derived)
        #expect(fromDerived.contains { $0.family == "Finance/Income Tax" },
                "the fixture stopped diverging — the comparison below would be vacuous")

        // The same tree as a hand-built profile would carry it: every entry given the one field a
        // walk abstains from.
        let enriched = FolderProfile(
            profileId: derived.profileId, root: derived.root,
            folders: derived.folders.mapValues {
                FolderProfileEntry(path: $0.path, role: $0.role, naming: "ordinal-month",
                                   anchors: $0.anchors, acceptsNewFiles: $0.acceptsNewFiles,
                                   fileCount: $0.fileCount, subfolderCount: $0.subfolderCount,
                                   axes: $0.axes)
            },
            personTokens: derived.personTokens, personAliases: derived.personAliases)

        let fromHandBuilt = StructureDivergence.findings(in: enriched)
        // `StructureFinding` is Equatable, so compare it whole: family and member lists alone would
        // miss a scheme whose `vocabulary` started depending on a field only a hand-built profile
        // carries, which is the thing being pinned.
        #expect(fromDerived == fromHandBuilt,
                "the lens read a field only a hand-built profile carries")
    }
}

/// `vocabulary` reads one bucket of the sibling map ``StructureDivergence/families(in:)`` builds
/// instead of walking the whole profile per folder, which made Organize's first visit stall. This
/// pins that it selects the same children as the full walk. The map keys on
/// `deletingLastPathComponent`, which agrees with the walk for ordinary paths but not for shapes
/// NSString normalises (`"A/B/"` and `"A//C"` both bucket under `A`, which the walk excluded), so
/// the remainder test must stay in the map's code.
@Suite struct StructureSiblingMapEquivalenceTests {

    /// The rule without the map: a pass over the whole profile per call.
    private static func byFullWalk(of path: String, in profile: FolderProfile) -> Set<String> {
        var words: Set<String> = []
        let prefix = path + "/"
        let parent = profile.folders[path]
        for (childPath, entry) in profile.folders where childPath.hasPrefix(prefix) {
            let relative = String(childPath.dropFirst(prefix.count))
            guard !relative.contains("/") else { continue }
            guard !StructureDivergence.isAxisValued(path: childPath, name: relative, entry: entry,
                                                    parent: parent) else { continue }
            words.insert(relative.lowercased())
        }
        return words
    }

    private static func profile(_ paths: [String],
                                axes: [String: [String: String]] = [:]) -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for path in paths {
            folders[path] = FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: true, fileCount: 1,
                                               subfolderCount: 0, axes: axes[path] ?? [:])
        }
        return FolderProfile(profileId: "test", root: "/root", folders: folders, personTokens: [])
    }

    /// Every folder in a profile, both ways, including the path shapes where the two would part
    /// company if the remainder test were dropped for `lastPathComponent`.
    @Test func theMapSelectsExactlyTheChildrenTheWalkDid() {
        let awkward = Self.profile([
            // Ordinary.
            "A", "A/B", "A/B/C", "A/D",
            // A trailing slash: `deletingLastPathComponent` buckets this under `A`; the walk saw
            // the remainder `"B2/"`, which contains a `/`, and dropped it.
            "A/B2/",
            // A doubled separator: buckets under `A` too; the walk saw the remainder `"/C2"`.
            "A//C2",
            // A dot component, which NSString does not normalise: both agree it isn't A's child.
            "A/./E",
            // A year, an inbox and a person axis, so the axis rules are exercised on both sides.
            "Y", "Y/2023", "Y/Forms", "Y/TODO", "Y/Mom",
        ], axes: ["Y/Mom": ["person": "Granny"]])

        let childrenByParent = StructureDivergence.families(in: awkward)
        var nonEmpty = 0
        for path in awkward.folders.keys.sorted() {
            let walked = Self.byFullWalk(of: path, in: awkward)
            let mapped = StructureDivergence.vocabulary(of: path, in: awkward,
                                                        childrenByParent: childrenByParent)
            #expect(walked == mapped, "\(path): walk \(walked.sorted()) vs map \(mapped.sorted())")
            if !walked.isEmpty { nonEmpty += 1 }
        }
        // A positive control: two empty sets compare equal, and a `vocabulary` that always
        // returned `[]` would pass every assertion above.
        #expect(nonEmpty >= 2, "the fixture has folders with a real vocabulary")
        #expect(Self.byFullWalk(of: "A", in: awkward) == ["b", "d"],
                "the trailing-slash and doubled-separator keys are NOT A's children, both ways")
        #expect(StructureDivergence.vocabulary(of: "Y", in: awkward,
                                               childrenByParent: childrenByParent) == ["forms"],
                "the year, the inbox and the person axis all drop, as before")
    }

    /// The convenience overload, used by the tests above and any isolated caller, builds the map
    /// itself and must answer the same as the threaded one.
    @Test func theOverloadThatBuildsItsOwnMapAgrees() {
        let p = Self.profile(["A", "A/B", "A/C", "A/B/D"])
        let map = StructureDivergence.families(in: p)
        for path in p.folders.keys {
            #expect(StructureDivergence.vocabulary(of: path, in: p)
                    == StructureDivergence.vocabulary(of: path, in: p, childrenByParent: map))
        }
        #expect(StructureDivergence.vocabulary(of: "A", in: p) == ["b", "c"])
    }
}
