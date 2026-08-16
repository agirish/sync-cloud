import Testing
import Foundation
@testable import Sync

// MARK: - Fixture helpers

private func file(_ name: String) -> FileNode {
    FileNode(id: "/x/\(name)", name: name, isDirectory: false)
}

private func dir(_ name: String, _ children: [FileNode] = []) -> FileNode {
    FileNode(id: "/x/\(name)", name: name, isDirectory: true, children: children)
}

/// A two-person household with a shared surname, so the "exactly one person" rule has something
/// real to abstain on.
private let household = PersonRegistry(people: [
    Person(id: "shweta", displayName: "Shweta", fullNames: ["Shweta Dani"], aliases: []),
    Person(id: "muktha", displayName: "Muktha", fullNames: ["Muktha Girish"], aliases: ["Mom"]),
])

private func build(_ tree: [FileNode], jurisdictions: Set<String> = ["US", "IN"],
                   registry: PersonRegistry? = household) -> FolderProfile {
    FolderSurveyBuilder.build(tree: tree, root: "~/Documents", profileId: "test",
                              registry: registry, jurisdictionValues: jurisdictions)
}

/// ``FolderSurveyBuilder`` over synthetic trees — one fixture per rule, each shaped so that the
/// rule and its fallback answer *differently*.
///
/// That last part is the standing trap here: `role`'s fallback is `.destination` and every axis's
/// fallback is *absent*, so a fixture expecting either would pass with the rule deleted. Every
/// expectation below is paired with the sibling that proves the rule fired — a `container` beside a
/// `destination`, a `person` axis beside a folder that has none.
@Suite struct FolderSurveyBuilderTests {

    // MARK: - The walk itself

    @Test func everyFolderGetsAnEntryAndTheRootIsCalledDot() {
        let profile = build([dir("Finance", [dir("US", [file("a.pdf")])]), file("loose.pdf")])
        #expect(Set(profile.folders.keys) == [".", "Finance", "Finance/US"])
        #expect(profile.folders["."]?.fileCount == 1)
        #expect(profile.folders["."]?.subfolderCount == 1)
        #expect(profile.folders["Finance/US"]?.fileCount == 1)
        #expect(profile.folders["Finance/US"]?.subfolderCount == 0)
    }

    @Test func dotFilesAndSymlinksAreNotDocuments() {
        let link = FileNode(id: "/x/alias", name: "alias", isDirectory: false, isSymbolicLink: true)
        let profile = build([dir("Box", [file("real.pdf"), file(".DS_Store"), link,
                                         dir(".hidden", [file("nope.pdf")])])])
        #expect(profile.folders["Box"]?.fileCount == 1)
        #expect(profile.folders["Box"]?.subfolderCount == 0)
        #expect(profile.folders["Box/.hidden"] == nil)
    }

    @Test func anUnexploredFolderIsCountedButNotDescribed() {
        let capped = FileNode(id: "/x/Deep", name: "Deep", isDirectory: true, children: [],
                              isUnexplored: true)
        let profile = build([dir("Top", [capped, dir("Walked", [file("a.pdf")])])])
        #expect(profile.folders["Top"]?.subfolderCount == 2)
        #expect(profile.folders["Top/Deep"] == nil, "counts for an unwalked folder would be fiction")
        #expect(profile.folders["Top/Walked"] != nil)
    }

    @Test func theBuilderIsAFunctionOfTheTreeAndNotOfTheWalkOrder() {
        let files = [file("Zebra Invoice.pdf"), file("Apple Invoice.pdf"), file("Mango Note.pdf")]
        let a = build([dir("Box", files)])
        let b = build([dir("Box", files.reversed())])
        #expect(a == b)
        // Non-vacuous: the folder really did earn a list an ordering could have reshuffled.
        #expect((a.folders["Box"]?.anchors.count ?? 0) >= 2)
    }

    // MARK: - Role, all eight branches

    @Test func roleTellsTheEightKindsOfFolderApart() {
        let profile = build([
            dir("Papers", [file("a.pdf")]),                                      // destination
            dir("Empty"),                                                        // empty
            dir("TODO", [file("b.pdf")]),                                        // inbox
            dir("Archive", [file("c.pdf")]),                                     // archive
            dir("2019", [file("d.pdf")]),                                        // year-bucket
            dir("Muktha", [file("e.pdf")]),                                      // person-bucket
            dir("Only", [dir("Child", [file("f.pdf")])]),                        // pass-through
            dir("Many", [dir("A", [file("g.pdf")]), dir("B", [file("h.pdf")])]), // container
        ])
        #expect(profile.folders["Papers"]?.role == .destination)
        #expect(profile.folders["Empty"]?.role == .empty)
        #expect(profile.folders["TODO"]?.role == .inbox)
        #expect(profile.folders["Archive"]?.role == .archive)
        #expect(profile.folders["2019"]?.role == .yearBucket)
        #expect(profile.folders["Muktha"]?.role == .personBucket)
        #expect(profile.folders["Only"]?.role == .passThrough)
        #expect(profile.folders["Many"]?.role == .container)
    }

    /// The measured ordering: an empty inbox is `empty`, not `inbox`.
    @Test func emptinessOutranksEveryOtherRole() {
        let profile = build([dir("TODO"), dir("Archive"), dir("2019"), dir("Muktha")])
        for name in ["TODO", "Archive", "2019", "Muktha"] {
            #expect(profile.folders[name]?.role == .empty, "\(name) holds nothing")
        }
    }

    /// Role reads the folder's **own** name; `acceptsNewFiles` reads the whole path. Measured: role
    /// on the whole path costs 0.6 points of agreement, because a year folder under `TODO` is still
    /// a year folder.
    @Test func aFolderInsideAnInboxKeepsItsOwnRoleAndLosesItsPermission() {
        let profile = build([dir("TODO", [dir("2023", [file("a.pdf")]),
                                          dir("Bank", [file("b.pdf")])])])
        #expect(profile.folders["TODO"]?.role == .inbox)
        #expect(profile.folders["TODO/2023"]?.role == .yearBucket)
        #expect(profile.folders["TODO/Bank"]?.role == .destination)
        // …and every one of them still refuses new files.
        #expect(profile.folders["TODO/2023"]?.acceptsNewFiles == false)
        #expect(profile.folders["TODO/Bank"]?.acceptsNewFiles == false)
        #expect(profile.acceptsNewFiles("TODO/Bank") == false)
    }

    @Test func aFolderInsideAnArchiveKeepsItsOwnRole() {
        let profile = build([dir("Archive", [dir("2010", [file("a.pdf")]),
                                             dir("Chase", [file("b.pdf")])])])
        #expect(profile.folders["Archive"]?.role == .archive)
        #expect(profile.folders["Archive/2010"]?.role == .yearBucket)
        #expect(profile.folders["Archive/Chase"]?.role == .destination)
        // The archive *fact* still reaches them — through the axis, which is what propagates.
        #expect(profile.folders["Archive/Chase"]?.axes["lifecycle"] == "archive")
    }

    /// A folder that merely *mentions* a person is a destination; only an exact roster name is a
    /// person bucket. The pair is the point — either fixture alone passes under either rule.
    @Test func personBucketNeedsTheWholeNameAndNothingElse() {
        let profile = build([dir("Muktha", [file("a.pdf")]),
                             dir("Mom", [file("b.pdf")]),
                             dir("Credit 1892 (Muktha)", [file("c.pdf")]),
                             dir("Muktha 2024", [file("d.pdf")])])
        #expect(profile.folders["Muktha"]?.role == .personBucket)
        #expect(profile.folders["Mom"]?.role == .personBucket, "an alias is a name form too")
        #expect(profile.folders["Credit 1892 (Muktha)"]?.role == .destination)
        #expect(profile.folders["Muktha 2024"]?.role == .destination)
    }

    @Test func withoutARosterNothingIsAPersonBucket() {
        let profile = build([dir("Muktha", [file("a.pdf")])], registry: nil)
        #expect(profile.folders["Muktha"]?.role == .destination)
        #expect(profile.folders["Muktha"]?.axes["person"] == nil)
    }

    // MARK: - acceptsNewFiles

    @Test func onlyInboxPathsRefuseFilesAndEverythingElseStaysSilent() {
        let profile = build([dir("TODO", [file("a.pdf")]),
                             dir("Papers", [file("b.pdf")]),
                             dir("EDD - TODO", [file("c.pdf")])])
        #expect(profile.folders["TODO"]?.acceptsNewFiles == false)
        #expect(profile.folders["EDD - TODO"]?.acceptsNewFiles == false)
        // nil, not `true`: the walk never checked whether filing here is a good idea.
        #expect(profile.folders["Papers"]?.acceptsNewFiles == nil)
        #expect(profile.acceptsNewFiles("Papers"))
    }

    // MARK: - naming is refused on purpose

    @Test func namingIsNeverGuessed() {
        // Files sharing an obvious convention — the exact shape a detector would claim. The builder
        // still says nothing, because a wrong convention makes the rename pass propose renames
        // toward a convention nobody has.
        let profile = build([dir("Payslips", [file("01. Jan 2024.pdf"), file("02. Feb 2024.pdf"),
                                              file("03. Mar 2024.pdf")])])
        #expect(profile.folders["Payslips"]?.naming == nil)
        #expect(profile.folders.values.allSatisfy { $0.naming == nil })
    }

    // MARK: - Anchors

    /// The keep rule, both directions in one fixture: `invoice` is in two filenames and stays,
    /// `zebra` is in one and goes, and the two path components stay at a count of one.
    @Test func anchorsKeepRepeatedWordsAndTheFoldersOwnNameAndNothingElse() {
        let profile = build([dir("Papers", [dir("Box", [file("Invoice Alpha.pdf"),
                                                        file("Invoice Bravo.pdf"),
                                                        file("Zebra.pdf")])])])
        #expect(profile.folders["Papers/Box"]?.anchors == ["invoice", "papers", "box"])
    }

    @Test func anchorsRankByCountAndBreakTiesByFirstAppearance() {
        let profile = build([dir("Alpha", [dir("Beta", [
            file("gamma delta one.pdf"), file("gamma delta two.pdf"), file("gamma solo.pdf"),
        ])])])
        // gamma 3, delta 2, then the path tokens at 1 in parent-then-child order.
        #expect(profile.folders["Alpha/Beta"]?.anchors == ["gamma", "delta", "alpha", "beta"])
    }

    @Test func anchorsStopAtTenTokens() throws {
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
                     "india", "juliet", "kilo", "lima"]
        let files = words.flatMap { [file("\($0) a1.pdf"), file("\($0) b2.pdf")] }
        let profile = build([dir("Box", files)])
        let anchors = try #require(profile.folders["Box"]?.anchors)
        #expect(anchors.count == FolderSurveyBuilder.anchorLimit)
        // Non-vacuous: twelve tokens were eligible, so the cap is what did the cutting.
        #expect(words.count > FolderSurveyBuilder.anchorLimit)
    }

    @Test func onlyTheFirstFortyFilenamesAreRead() throws {
        var files = (1...FolderSurveyBuilder.fileNameSample).map { file("aaa\($0) common.pdf") }
        files += [file("zzz late.pdf"), file("zzz later.pdf")]
        let profile = build([dir("Box", files)])
        let anchors = try #require(profile.folders["Box"]?.anchors)
        #expect(anchors.contains("common"))
        #expect(!anchors.contains("zzz"), "a word past the sample must not reach the anchors")
        #expect(profile.folders["Box"]?.fileCount == files.count, "but it is still counted")
    }

    @Test func onlyTheLastTwoPathComponentsSpeak() {
        let profile = build([dir("Grandparent", [dir("Parent", [dir("Child", [file("a.pdf")])])])])
        #expect(profile.folders["Grandparent/Parent/Child"]?.anchors == ["parent", "child"])
    }

    /// The token rule is `[a-z][a-z0-9&+-]{2,}` and it keeps compounds whole — which is exactly
    /// where it parts company with `FilingRouter.tokenize`. Both sides pinned, so a later
    /// "unification" of the two fails here first.
    @Test func theAnchorTokenizerKeepsCompoundsThatTheRoutersOneShatters() {
        #expect(FolderSurveyBuilder.anchorWords("PG&E Parents-in-Law") == ["pg&e", "parents-in-law"])
        #expect(FolderSurveyBuilder.anchorWords("2026-report") == ["report"])
        #expect(FolderSurveyBuilder.anchorWords("H-1B Visa") == ["h-1b", "visa"])
        #expect(FolderSurveyBuilder.anchorWords("JN Card") == ["card"], "two letters is not a token")
        #expect(FilingRouter.tokenize("PG&E Parents-in-Law") == ["pg", "parents", "law"])
        #expect(FilingRouter.tokenize("JN Card") == ["jn", "card"])
    }

    @Test func packagingWordsAreDroppedEvenWhenTheyNameTheFolder() {
        let profile = build([dir("Forms", [file("Tax Form.pdf"), file("Tax Form 2.pdf")])])
        #expect(profile.folders["Forms"]?.anchors == ["tax"])
    }

    /// Months are filing dates in a filename and subjects in a folder name. Both directions, or the
    /// rule would pass with its exception deleted.
    @Test func monthsSurviveOnlyWhenTheyNameTheFolder() {
        let profile = build([dir("Lacewings JAN", [file("visit jan.pdf"), file("note jan.pdf")]),
                             dir("Trips", [file("jul photo.pdf"), file("jul video.pdf")])])
        #expect(profile.folders["Lacewings JAN"]?.anchors == ["jan", "lacewings"])
        #expect(profile.folders["Trips"]?.anchors == ["trips"])
    }

    // MARK: - Axes

    @Test func theYearAxisTakesABareYearAndTheFiscalAxisTakesASpan() {
        let profile = build([dir("Tax", [dir("2023", [file("a.pdf")]),
                                         dir("2013-2014", [file("b.pdf")]),
                                         dir("2006 - 2007", [file("c.pdf")]),
                                         dir("IRS Docs - 2023", [file("d.pdf")])])])
        #expect(profile.folders["Tax/2023"]?.axes["year"] == "2023")
        #expect(profile.folders["Tax/2023"]?.axes["fiscalYear"] == nil)
        #expect(profile.folders["Tax/2013-2014"]?.axes["fiscalYear"] == "2013-2014")
        #expect(profile.folders["Tax/2013-2014"]?.axes["year"] == nil)
        // Spaces around the dash make it a folder name, not a span — measured on the real tree.
        #expect(profile.folders["Tax/2006 - 2007"]?.axes["fiscalYear"] == nil)
        #expect(profile.folders["Tax/IRS Docs - 2023"]?.axes["year"] == nil)
    }

    @Test func axesPropagateDownAndTheDeeperFolderWins() {
        let profile = build([dir("Finance", [dir("US", [dir("2023", [
            dir("Deductions", [file("a.pdf")]), dir("2024", [file("b.pdf")]),
        ])])])])
        #expect(profile.folders["Finance/US/2023/Deductions"]?.axes["year"] == "2023")
        #expect(profile.folders["Finance/US/2023/Deductions"]?.axes["jurisdiction"] == "US")
        #expect(profile.folders["Finance/US/2023/2024"]?.axes["year"] == "2024")
    }

    @Test func onlyDeclaredJurisdictionValuesCount() {
        let tree = [dir("Finance", [dir("US", [file("a.pdf")]), dir("Chase", [file("b.pdf")])])]
        let declared = build(tree, jurisdictions: ["US", "IN"])
        #expect(declared.folders["Finance/US"]?.axes["jurisdiction"] == "US")
        #expect(declared.folders["Finance/Chase"]?.axes["jurisdiction"] == nil)
        // Nothing in the tree says which names are jurisdictions, so an empty vocabulary records
        // none — same folder, different answer.
        let none = build(tree, jurisdictions: [])
        #expect(none.folders["Finance/US"]?.axes["jurisdiction"] == nil)
    }

    @Test func lifecycleSaysInboxArchiveOrActive() {
        let profile = build([dir("TODO", [file("a.pdf")]),
                             dir("Archive", [dir("Chase", [file("b.pdf")])]),
                             dir("Papers", [file("c.pdf")])])
        #expect(profile.folders["TODO"]?.axes["lifecycle"] == "inbox")
        #expect(profile.folders["Archive/Chase"]?.axes["lifecycle"] == "archive")
        #expect(profile.folders["Papers"]?.axes["lifecycle"] == "active")
    }

    @Test func anInboxInsideAnArchiveReadsAsAnInbox() {
        let profile = build([dir("Archive", [dir("TODO", [file("a.pdf")])])])
        #expect(profile.folders["Archive/TODO"]?.axes["lifecycle"] == "inbox")
    }

    /// The abstention rule, with the fixture built so abstaining and answering differ: the parent
    /// names Shweta, the child names two people, and the child must keep the parent's answer rather
    /// than picking one of its own.
    @Test func aFolderNamingTwoPeopleNamesNobodyNew() {
        let profile = build([dir("Shweta", [
            dir("Shweta Dani and Muktha Girish", [file("a.pdf")]),
            dir("Muktha", [file("b.pdf")]),
            dir("Receipts", [file("c.pdf")]),
        ])])
        #expect(profile.folders["Shweta"]?.axes["person"] == "Shweta")
        #expect(profile.folders["Shweta/Muktha"]?.axes["person"] == "Muktha", "deeper wins")
        #expect(profile.folders["Shweta/Receipts"]?.axes["person"] == "Shweta", "and propagates")
        #expect(profile.folders["Shweta/Shweta Dani and Muktha Girish"]?.axes["person"] == "Shweta",
                "two names is not evidence for either — the parent's answer stands")
    }

    @Test func thePersonAxisIsSpelledTheWayTheRosterSpellsIt() {
        let profile = build([dir("Mom", [file("a.pdf")])])
        #expect(profile.folders["Mom"]?.axes["person"] == "Muktha")
    }

    @Test func theProfileCarriesTheRosterTokensAndAliases() {
        let profile = build([dir("Papers", [file("a.pdf")])])
        #expect(profile.personTokens.contains("muktha"))
        #expect(profile.personTokens.contains("mom"))
        #expect(profile.personAliases["mom"] == "muktha")
    }

    // MARK: - The two year keys are one axis

    /// **A path carrying both styles keeps both axes**, exactly as the hand-built profile does —
    /// four folders on the reference tree record a `year` and a `fiscalYear` together, because both
    /// are true of them. The builder must not drop either, or the ground truth's 100% year agreement
    /// goes with it.
    ///
    /// Which of the two a *consumer* answers with is ``FolderProfileEntry/yearKey``'s business, and
    /// is asserted in `theDeeperYearComponentIsTheOneAFolderAnswersWith`.
    @Test func bothYearAxesSurviveWhenAPathCarriesBoth() {
        let profile = build([dir("H-1B", [dir("2016-2019", [dir("2016", [file("a.pdf")])])])])
        let deep = profile.folders["H-1B/2016-2019/2016"]
        #expect(deep?.axes["year"] == "2016")
        #expect(deep?.axes["fiscalYear"] == "2016-2019",
                "the ancestor's fiscal span was dropped — the hand-built profile keeps it")

        // The control: with only one style in the path, only that key is set — so the assertion
        // above cannot be passing by setting both keys everywhere.
        let plain = build([dir("Finance", [dir("2023", [file("a.pdf")]),
                                           dir("2013-2014", [file("b.pdf")])])])
        #expect(plain.folders["Finance/2023"]?.axes["year"] == "2023")
        #expect(plain.folders["Finance/2023"]?.axes["fiscalYear"] == nil)
        #expect(plain.folders["Finance/2013-2014"]?.axes["fiscalYear"] == "2013-2014")
        #expect(plain.folders["Finance/2013-2014"]?.axes["year"] == nil)
    }

    /// **The deeper of the two year components is the one the folder answers with.**
    ///
    /// `yearKey` used to read `axes["year"] ?? axes["fiscalYear"]`, a fixed precedence that answers
    /// with whichever key is named first rather than with the folder the value describes. On the
    /// reference tree's four both-axes folders it is right by luck — the bare year is deeper there,
    /// and the first arm returns it. Reverse the nesting, as an Indian fiscal folder under a
    /// calendar-year parent does, and the ancestor wins: `FilingRouter.foldersByYear` files the
    /// folder under the wrong year and `RenamePlanner` questions documents that are correctly filed.
    ///
    /// Both directions are asserted, and the first is the one that pins the real tree's behaviour
    /// as unchanged.
    @Test func theDeeperYearComponentIsTheOneAFolderAnswersWith() {
        let bareDeeper = build([dir("H-1B", [dir("2016-2019", [dir("2016", [file("a.pdf")])])])])
        #expect(bareDeeper.folders["H-1B/2016-2019/2016"]?.yearKey == "2016",
                "the real tree's arrangement changed answer")

        let spanDeeper = build([dir("Finance", [dir("2015", [dir("2014-2015", [file("a.pdf")])])])])
        #expect(spanDeeper.folders["Finance/2015/2014-2015"]?.yearKey == "2014-2015",
                "a folder about a fiscal span answered with its ancestor's calendar year")

        // Neither arm of the depth scan may disturb the single-axis cases or the name fallback.
        let plain = build([dir("Finance", [dir("2023", [file("a.pdf")]),
                                           dir("2013-2014", [file("b.pdf")])])])
        #expect(plain.folders["Finance/2023"]?.yearKey == "2023")
        #expect(plain.folders["Finance/2013-2014"]?.yearKey == "2013-2014")
        #expect(plain.folders["Finance"]?.yearKey == nil)
    }

    // MARK: - A hand-edited roster cannot take the survey down with it

    /// `people.json` is hand-edited and nothing upstream rejects a repeated id.
    ///
    /// ``PersonRegistry`` loads such a file without complaint — its own init just overwrites — and
    /// so does every other consumer. This builder used to be the exception: it fed
    /// `Dictionary(uniqueKeysWithValues:)`, which traps on a duplicate key, so a copy-pasted person
    /// block whose id was not changed killed the process inside the detached task the survey runs
    /// in. The survey has to survive the file, and last-wins matches what the registry itself does
    /// with the same input.
    /// The registry keeps the *last* entry's tokens for a repeated id — its own dictionaries
    /// overwrite — so the surviving display name is what the axis reports. Asserted here because it
    /// is what makes "last wins" in the builder the right choice rather than an arbitrary one: the
    /// two now agree about which of the two records answers for that id.
    @Test func aDuplicatedPersonIdSurveysRatherThanTrapping() {
        let duplicated = PersonRegistry(people: [
            Person(id: "muktha", displayName: "Muktha", fullNames: [], aliases: []),
            Person(id: "muktha", displayName: "Muktha Girish", fullNames: [], aliases: ["Mom"]),
        ])
        let profile = build([dir("Mom", [file("a.pdf")]), dir("Finance", [file("b.pdf")])],
                            registry: duplicated)
        #expect(profile.folders.count == 3)                     // root, Mom, Finance
        #expect(profile.folders["Mom"]?.axes["person"] == "Muktha Girish")
        #expect(profile.folders["Finance"]?.axes["person"] == nil,
                "a folder naming nobody must not inherit a person")
    }

    // MARK: - Vocabularies that must not drift from the code that owns them

    /// The month list is derived from ``OrdinalMonthName``'s tables rather than retyped, so a
    /// spelling added to the renamer's vocabulary reaches anchor suppression too. This pins that the
    /// derivation still covers what the hand-written list covered, and that `sept` — measured as a
    /// keeper on the reference tree — is still absent from it.
    /// **Checked against an independent literal, not against the tables it is derived from.** The
    /// obvious form of this test — assert every entry of `monthAbbreviations` and `monthFullNames`
    /// is in `monthWords` — is `Set(A+B).contains(each of A+B)`, which is true of any derivation
    /// from those two tables including a broken one, and would have been the only check left after
    /// the hand-written list it replaced was deleted. So the list it replaced is restored here, as
    /// the expected value: the measured vocabulary, spelled out, on the other side of the equals.
    @Test func theMonthVocabularyTracksTheRenamer() {
        let measured: Set<String> = [
            "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
            "january", "february", "march", "april", "june", "july", "august", "september",
            "october", "november", "december",
        ]
        #expect(FolderSurveyBuilder.monthWords == measured,
                "the derived month list stopped matching the one measured on the reference tree")
        #expect(!FolderSurveyBuilder.monthWords.contains("sept"),
                "`sept` is a measured keeper — deriving the list must not quietly add it")
        // Lowercasing is applied to both tables and is load-bearing: the tokens this set is matched
        // against are always lowercased, so an uppercase entry would suppress nothing.
        #expect(FolderSurveyBuilder.monthWords.allSatisfy { $0 == $0.lowercased() })
    }

    /// Which name forms count as a person folder comes from ``Person/nameForms``, the same union the
    /// registry matches on. Spelled out separately, a new form source reaches one and not the other,
    /// and a folder starts matching for the person axis while failing to count as a person bucket.
    @Test func aPersonBucketIsRecognisedByEveryFormTheRegistryMatches() {
        let profile = build([dir("Shweta Dani", [file("a.pdf")]), dir("Mom", [file("b.pdf")]),
                             dir("Receipts", [file("c.pdf")])])
        #expect(profile.folders["Shweta Dani"]?.role == .personBucket, "a full name is a form")
        #expect(profile.folders["Mom"]?.role == .personBucket, "an alias is a form")
        #expect(profile.folders["Receipts"]?.role == .destination,
                "a folder naming nobody must not be a person bucket")
    }
}
