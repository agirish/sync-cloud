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
    Person(id: "mother", displayName: "Mother", fullNames: ["Mother Maiden"], aliases: []),
    Person(id: "granny", displayName: "Granny", fullNames: ["Granny Elder"], aliases: ["Mom"]),
])

private func build(_ tree: [FileNode], jurisdictions: Set<String> = ["US", "IN"],
                   registry: PersonRegistry? = household) -> FolderProfile {
    FolderSurveyBuilder.build(tree: tree, root: "~/Documents", profileId: "test",
                              registry: registry, jurisdictionValues: jurisdictions)
}

/// ``FolderSurveyBuilder`` over synthetic trees, one fixture per rule, each shaped so the rule and
/// its fallback answer differently. `role` falls back to `.destination` and every axis to absent,
/// so a fixture expecting either would pass with the rule deleted; each expectation is paired with
/// a sibling that proves the rule fired.
@Suite struct FolderSurveyBuilderTests {

    /// Whole-line comments removed, so a source scan counts what the file does, not what its prose
    /// says about it (as in `PaneTabWiringTests`).
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

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

    /// A package is one document: counted as a file in its folder, its insides never surveyed, or a
    /// finding about `Song.key/Data` would plan a move of a document's insides.
    @Test func aPackageIsADocumentAndItsInsidesAreNotSurveyed() throws {
        let package = FileNode(id: "/x/Song.key", name: "Song.key", isDirectory: true,
                               children: [dir("Data", [dir("Media", [file("a.png")])])],
                               kind: "com.apple.iwork.keynote.key")
        try #require(package.isPackage, "the premise: the walk's kind reads as a package")
        let profile = build([dir("Music", [package, dir("Live", [file("b.mp3")])])])
        #expect(Set(profile.folders.keys) == [".", "Music", "Music/Live"],
                "a package's insides were surveyed: \(profile.folders.keys.sorted())")
        #expect(profile.folders["Music"]?.fileCount == 1, "the package is a document in its folder")
        #expect(profile.folders["Music"]?.subfolderCount == 1)
        #expect(!FolderSurveyBuilder.isSurveyedFolder(package))
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
            dir("Granny", [file("e.pdf")]),                                      // person-bucket
            dir("Only", [dir("Child", [file("f.pdf")])]),                        // pass-through
            dir("Many", [dir("A", [file("g.pdf")]), dir("B", [file("h.pdf")])]), // container
        ])
        #expect(profile.folders["Papers"]?.role == .destination)
        #expect(profile.folders["Empty"]?.role == .empty)
        #expect(profile.folders["TODO"]?.role == .inbox)
        #expect(profile.folders["Archive"]?.role == .archive)
        #expect(profile.folders["2019"]?.role == .yearBucket)
        #expect(profile.folders["Granny"]?.role == .personBucket)
        #expect(profile.folders["Only"]?.role == .passThrough)
        #expect(profile.folders["Many"]?.role == .container)
    }

    /// The measured ordering: an empty inbox is `empty`, not `inbox`.
    @Test func emptinessOutranksEveryOtherRole() {
        let profile = build([dir("TODO"), dir("Archive"), dir("2019"), dir("Granny")])
        for name in ["TODO", "Archive", "2019", "Granny"] {
            #expect(profile.folders[name]?.role == .empty, "\(name) holds nothing")
        }
    }

    /// Role reads the folder's own name; `acceptsNewFiles` reads the whole path. A year folder under
    /// `TODO` is still a year folder (role on the whole path measured 0.6 points worse).
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
    /// Person-folder names come from ``Person/nameForms``, the union the registry matches on.
    /// Spelled out separately, a new form could match the person axis but not count as a bucket.
    @Test func personBucketNeedsTheWholeNameAndNothingElse() {
        let profile = build([dir("Granny", [file("a.pdf")]),
                             dir("Mom", [file("b.pdf")]),
                             dir("Credit 1892 (Granny)", [file("c.pdf")]),
                             dir("Granny 2024", [file("d.pdf")]),
                             dir("Mother Maiden", [file("e.pdf")]),
                             dir("Receipts", [file("f.pdf")])])
        #expect(profile.folders["Granny"]?.role == .personBucket)
        #expect(profile.folders["Mom"]?.role == .personBucket, "an alias is a name form too")
        #expect(profile.folders["Mother Maiden"]?.role == .personBucket, "a full name is a form")
        #expect(profile.folders["Credit 1892 (Granny)"]?.role == .destination)
        #expect(profile.folders["Granny 2024"]?.role == .destination)
        #expect(profile.folders["Receipts"]?.role == .destination,
                "a folder naming nobody must not be a person bucket")
    }

    @Test func withoutARosterNothingIsAPersonBucket() {
        let profile = build([dir("Granny", [file("a.pdf")])], registry: nil)
        #expect(profile.folders["Granny"]?.role == .destination)
        #expect(profile.folders["Granny"]?.axes["person"] == nil)
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

    /// The builder never guesses a naming convention. `naming` has no rule, just the literal
    /// `naming: nil`, so no fixture asserting `nil` could fail. What can fail instead: the same
    /// predicate is false over a hand-built profile that carries a convention, and the builder has
    /// exactly one writer of the field, that literal, so a detector added later fails here.
    @Test func namingIsNeverGuessed() throws {
        // Files sharing an obvious convention, the shape a detector would claim. A wrong convention
        // would make the rename pass propose renames toward it.
        let profile = build([dir("Payslips", [file("01. Jan 2024.pdf"), file("02. Feb 2024.pdf"),
                                              file("03. Mar 2024.pdf")])])
        #expect(profile.folders["Payslips"]?.naming == nil)
        #expect(profile.folders.values.allSatisfy { $0.naming == nil })

        // The control: a hand-built profile, the other producer of these entries, records `naming`.
        // Decoded from the on-disk shape the way the store reads it.
        let handBuilt = """
        {"profileId": "test", "root": "~/Documents", "folders": [
          {"path": "Payslips", "role": "destination", "naming": "ordinal-month",
           "anchors": [], "fileCount": 3, "subfolderCount": 0, "axes": {}}]}
        """
        let hand = try JSONDecoder().decode(FolderProfile.self, from: Data(handBuilt.utf8))
        #expect(hand.folders["Payslips"]?.naming == "ordinal-month",
                "the field cannot carry a convention at all, so the assertions above assert nothing")
        #expect(!hand.folders.values.allSatisfy { $0.naming == nil },
                "the `allSatisfy` above is vacuous — it holds even of a profile that names one")

        // Nobody has added a guesser: one writer, and it is the abstention.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sync/FolderSurveyBuilder.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        #expect(code.contains("public enum FolderSurveyBuilder"),
                "this is not the builder — the scan below is vacuous")
        // Comments stripped first, so prose that mentions `naming:` doesn't count as a writer.
        let writers = Self.codeOnly(code).components(separatedBy: "naming:").count - 1
        #expect(writers == 1, """
                the builder writes `naming:` \(writers) times — it used to be the one abstention, \
                so something now guesses a convention
                """)
        #expect(Self.codeOnly(code).contains("naming: nil"),
                "the builder's one `naming:` is no longer the abstention")
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

    /// The token rule is `[a-z][a-z0-9&+-]{2,}` and keeps compounds whole, unlike
    /// `FilingRouter.tokenize`. Both sides pinned, so merging the two fails here.
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
    /// names Mother, the child names two people, and the child must keep the parent's answer rather
    /// than picking one of its own.
    @Test func aFolderNamingTwoPeopleNamesNobodyNew() {
        let profile = build([dir("Mother", [
            dir("Mother Maiden and Granny Elder", [file("a.pdf")]),
            dir("Granny", [file("b.pdf")]),
            dir("Receipts", [file("c.pdf")]),
        ])])
        #expect(profile.folders["Mother"]?.axes["person"] == "Mother")
        #expect(profile.folders["Mother/Granny"]?.axes["person"] == "Granny", "deeper wins")
        #expect(profile.folders["Mother/Receipts"]?.axes["person"] == "Mother", "and propagates")
        #expect(profile.folders["Mother/Mother Maiden and Granny Elder"]?.axes["person"] == "Mother",
                "two names is not evidence for either — the parent's answer stands")
    }

    @Test func thePersonAxisIsSpelledTheWayTheRosterSpellsIt() {
        let profile = build([dir("Mom", [file("a.pdf")])])
        #expect(profile.folders["Mom"]?.axes["person"] == "Granny")
    }

    @Test func theProfileCarriesTheRosterTokensAndAliases() {
        let profile = build([dir("Papers", [file("a.pdf")])])
        #expect(profile.personTokens.contains("granny"))
        #expect(profile.personTokens.contains("mom"))
        #expect(profile.personAliases["mom"] == "granny")
    }

    // MARK: - The two year keys are one axis

    /// The deeper of the two year components is the one the folder answers with. A fixed precedence
    /// would let an ancestor win when a fiscal folder sits under a calendar-year parent, and
    /// `FilingRouter.foldersByYear` would file it under the wrong year. Both nestings are asserted;
    /// the first is the reference tree's. A path carrying both styles keeps both axes, as the
    /// hand-built profile does for four folders on the reference tree; dropping either loses the
    /// ground truth's 100% year agreement.
    @Test func theDeeperYearComponentIsTheOneAFolderAnswersWith() {
        let bareDeeper = build([dir("H-1B", [dir("2016-2019", [dir("2016", [file("a.pdf")])])])])
        let deep = bareDeeper.folders["H-1B/2016-2019/2016"]
        #expect(deep?.axes["year"] == "2016")
        #expect(deep?.axes["fiscalYear"] == "2016-2019",
                "the ancestor's fiscal span was dropped — the hand-built profile keeps it")
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

    /// The depth scan runs only when both values are path components. The builder can't produce
    /// this shape, but the offline Python builder can, since it records axes as facts. Here the
    /// plain `year`-first precedence stands, so such profiles keep their answer.
    @Test func anAxisThatIsNotAPathComponentKeepsTheOldPrecedence() {
        let entry = FolderProfileEntry(path: "Finance/Chase", role: nil, naming: nil, anchors: [],
                                       acceptsNewFiles: nil, fileCount: 1, subfolderCount: 0,
                                       axes: ["year": "2015", "fiscalYear": "2014-2015"])
        #expect(entry.yearKey == "2015",
                "the depth scan ran on a path containing neither value and changed the answer")

        // One value a component and the other not: still `year` first, since a scan matching only
        // one can't answer a depth question.
        let half = FolderProfileEntry(path: "Finance/2014-2015", role: nil, naming: nil, anchors: [],
                                      acceptsNewFiles: nil, fileCount: 1, subfolderCount: 0,
                                      axes: ["year": "2015", "fiscalYear": "2014-2015"])
        #expect(half.yearKey == "2015")
    }

    // MARK: - A hand-edited roster cannot take the survey down with it

    /// `people.json` is hand-edited, and nothing upstream rejects a repeated id. The survey must
    /// survive one rather than trap on a duplicate dictionary key in its detached task. The builder
    /// keeps the last record, as ``PersonRegistry`` does, so the axis reports that display name.
    @Test func aDuplicatedPersonIdSurveysRatherThanTrapping() {
        let duplicated = PersonRegistry(people: [
            Person(id: "granny", displayName: "Granny", fullNames: [], aliases: []),
            Person(id: "granny", displayName: "Granny Elder", fullNames: [], aliases: ["Mom"]),
        ])
        let profile = build([dir("Mom", [file("a.pdf")]), dir("Finance", [file("b.pdf")])],
                            registry: duplicated)
        #expect(profile.folders.count == 3)                     // root, Mom, Finance
        #expect(profile.folders["Mom"]?.axes["person"] == "Granny Elder")
        #expect(profile.folders["Finance"]?.axes["person"] == nil,
                "a folder naming nobody must not inherit a person")
    }

    /// What a duplicated id does to the roster. `PersonRegistry.init` collapses a repeated id to its
    /// last record, so a folder named only for a dropped record is not a person bucket at all. That
    /// is intended: one id is one person, and `PeopleStore` warns at load that the earlier entries
    /// were dropped and their names won't resolve.
    @Test func aDuplicatedIdResolvesOnlyTheRecordTheRegistryKept() {
        let duplicated = PersonRegistry(people: [
            Person(id: "m", displayName: "Granny", fullNames: [], aliases: []),
            Person(id: "m", displayName: "Mukti", fullNames: [], aliases: ["Mom"]),
        ])
        // The premise: the collapse really happened, so the assertions below are about one person.
        #expect(duplicated.people.map(\.displayName) == ["Mukti"])
        #expect(duplicated.repeatedIds == ["m"], "the registry did not report the repeat it repaired")

        let profile = build([dir("Granny", [file("a.pdf")]), dir("Mukti", [file("b.pdf")]),
                             dir("Receipts", [file("c.pdf")])], registry: duplicated)

        let dropped = profile.folders["Granny"]
        #expect(dropped?.role != .personBucket,
                "a folder named only for the DROPPED record is still read as somebody's bucket")
        #expect(dropped?.axes["person"] == nil)

        // The surviving record still resolves on both, which keeps the line above meaningful.
        #expect(profile.folders["Mukti"]?.role == .personBucket)
        #expect(profile.folders["Mukti"]?.axes["person"] == "Mukti")
        // And a folder naming nobody is untouched by any of it.
        #expect(profile.folders["Receipts"]?.role == .destination)
        #expect(profile.folders["Receipts"]?.axes["person"] == nil)
    }

    // MARK: - Vocabularies that must not drift from the code that owns them

    /// The month list is derived from ``OrdinalMonthName``'s tables, so a spelling the renamer adds
    /// reaches anchor suppression too. Checked against an independent literal, the measured
    /// vocabulary: checked against its own source tables, any derivation would pass. `sept`, a
    /// measured keeper on the reference tree, stays out, and every entry is lowercase, as the
    /// tokens matched against it are.
    @Test func theMonthVocabularyTracksTheRenamer() {
        let measured: Set<String> = [
            "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
            "january", "february", "march", "april", "june", "july", "august", "september",
            "october", "november", "december",
        ]
        #expect(FolderSurveyBuilder.monthWords == measured,
                "the derived month list stopped matching the one measured on the reference tree")
    }
}
