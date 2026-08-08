import Foundation
import Testing
@testable import Sync

/// The router's rules, each pinned by a case where getting it wrong is *silent* — a worse
/// suggestion, never an error. Three of these exist because the measured version of the algorithm
/// scored badly until the rule was added, and one because a hash format drifting apart from its
/// builder would quietly stop every identifier matching.
@Suite struct FilingRouterTests {

    // MARK: - Fixtures

    /// A miniature of the real tree's shape: one provider with several years, a sibling provider,
    /// and an unrelated branch to be wrong about.
    static func index(memoryDocs: [String: [String]] = [:],
                      extraFolders: [String] = [],
                      profileEntries: [FolderProfileEntry] = []) -> FilingRouter.Index {
        var folders = [
            "Home/Utilities/PG&E/2023", "Home/Utilities/PG&E/2024",
            "Home/Utilities/AT&T/2023", "Home/Utilities/AT&T/2024",
            "Health/Medical/Kaiser/Surgery", "Finance/US/Income Tax/2023",
        ]
        folders.append(contentsOf: extraFolders)
        var entries = folders.map { path in
            FolderProfileEntry(path: path, role: .yearBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 1, subfolderCount: 0, axes: [:])
        }
        entries.append(contentsOf: profileEntries)
        let profile = FolderProfile(profileId: "t", root: "~/Documents",
                                    folders: Dictionary(entries.map { ($0.path, $0) },
                                                        uniquingKeysWith: { _, b in b }),
                                    personTokens: ["shweta", "divit"])
        var memFolders: [String: FilingMemoryEntry] = [:]
        for (folder, rawTokens) in memoryDocs {
            // Stored tokens go through the tokenizer first, exactly as the builder does — which
            // lowercases. Hashing `AA00CVPBHP` raw stores something `rank` can never produce, and
            // the symptom is not an error but an identifier that silently stops matching.
            let tokens = rawTokens.flatMap { FilingRouter.tokenize($0) }
            memFolders[folder] = FilingMemoryEntry(
                docs: 4,
                anchors: tokens.filter { !FilingRouter.isIdentifier($0) }
                    .map { FilingMemoryToken(token: $0, weight: 3.0) },
                idHashes: tokens.filter { FilingRouter.isIdentifier($0) }
                    .map { FilingMemoryToken(token: FilingMemory.hash($0, salt: "s"), weight: 3.0) })
        }
        let memory = FilingMemory(profileId: "t", salt: "s", folders: memFolders)
        return FilingRouter.makeIndex(destinations: folders, profile: profile, memory: memory)
    }

    // MARK: - The rules that were found by measuring

    /// **Evidence must be inherited from the parent.** `AT&T/2024` is empty, so it has no content of
    /// its own; only its sibling `AT&T/2023` knows what an AT&T bill looks like. Without inheritance
    /// the correct folder scores zero and can never be proposed — measured at 0.7% against 26.8%
    /// for the name signal alone, which is what sent this rule into the design.
    @Test func anEmptyYearFolderIsReachableThroughItsSiblings() {
        let idx = Self.index(memoryDocs: ["Home/Utilities/AT&T/2023": ["wireless", "att", "mobility"]])
        let r = FilingRouter.rank(fileName: "bill.pdf",
                                  contentSnippet: "AT&T Mobility wireless statement for 2024",
                                  index: idx)
        #expect(r.best?.relativePath == "Home/Utilities/AT&T/2024")
    }

    /// The vocabulary for the two inheritance tests below. Deliberately words that appear in **no**
    /// folder path in the fixture, and a file name that shares nothing with any of them: inherited
    /// content is then the only route by which a child folder can score at all. The first draft of
    /// these tests used the real `Visa/H-1B/2024-2026` names, and both survived every mutation —
    /// the era folders were entering the ranking on the `visa` and `2026` tokens in their own paths,
    /// so neither test was ever exercising inheritance.
    static let parentVocabulary = ["consulate", "foil", "annotation", "nonimmigrant", "issuance",
                                   "reciprocity", "biometrics", "interview", "endorsement",
                                   "duration", "petitioner", "beneficiary"]

    /// **A parent that holds all the evidence must reach its own children.** The mirror image of the
    /// sibling case, and the one the first cut missed: `Visa/US/H-1B Visa` holds every visa foil
    /// while its per-era children hold none, so sharing only between siblings gave the era folders —
    /// the folders the file actually belongs in — nothing whatsoever. The parent is still the top
    /// pick here; what this pins is that its empty children are *reachable at all*.
    @Test func anEmptyChildIsReachableThroughTheParentThatHoldsTheEvidence() throws {
        let idx = Self.index(memoryDocs: ["Records/Consular": Self.parentVocabulary],
                             extraFolders: ["Records/Consular", "Records/Consular/Alpha",
                                            "Records/Consular/Beta"])
        let r = FilingRouter.rank(fileName: "scan.pdf",
                                  contentSnippet: Self.parentVocabulary.joined(separator: " "),
                                  index: idx)
        let ranked = r.candidates.map(\.relativePath)
        #expect(ranked.first == "Records/Consular")
        #expect(ranked.contains("Records/Consular/Alpha"),
                "an empty child of the evidence-holding parent never entered the ranking: \(ranked)")
    }

    /// **The inherited share has to be in the same units as the score it is added to.** It used to
    /// be divided by the peak, which pinned every share into [0, `inheritWeight`] and then added it
    /// to raw content scores that reach the hundreds on a real memory — so inheritance moved a cold
    /// folder by a fraction of a percent of the leader and was, in the one case it exists for,
    /// arithmetically inert. Twelve matching anchors are enough for the constant and the fraction to
    /// be different answers.
    @Test func theInheritedShareScalesWithTheEvidenceBehindIt() throws {
        let idx = Self.index(memoryDocs: ["Records/Consular": Self.parentVocabulary],
                             extraFolders: ["Records/Consular", "Records/Consular/Alpha"])
        let r = FilingRouter.rank(fileName: "scan.pdf",
                                  contentSnippet: Self.parentVocabulary.joined(separator: " "),
                                  index: idx)
        let child = try #require(r.candidates.first { $0.relativePath == "Records/Consular/Alpha" },
                                 "the empty child scored nothing: \(r.candidates.map(\.relativePath))")
        let parent = try #require(r.candidates.first { $0.relativePath == "Records/Consular" })
        #expect(child.score > parent.score * 0.2,
                "inherited \(child.score) against a parent at \(parent.score) — share out of scale")
    }

    /// The same fixture with the year changed must move to the sibling — otherwise the test above
    /// passes for the wrong reason (a fixture whose expected value equals the fallback cannot fail).
    @Test func theYearInTheDocumentPicksTheSibling() {
        let idx = Self.index(memoryDocs: ["Home/Utilities/AT&T/2023": ["wireless", "att", "mobility"]])
        let r = FilingRouter.rank(fileName: "bill.pdf",
                                  contentSnippet: "AT&T Mobility wireless statement for 2023",
                                  index: idx)
        #expect(r.best?.relativePath == "Home/Utilities/AT&T/2023")
    }

    /// **Years must be read out of the document, not only the filename.** Three files all called
    /// `Lease Agreement.pdf` differ only by the term printed inside them.
    @Test func aYearOnlyInTheBodyStillRoutes() {
        let idx = Self.index(memoryDocs: ["Home/Utilities/PG&E/2023": ["gas", "electric", "pge"]])
        let named = FilingRouter.rank(fileName: "statement.pdf",
                                      contentSnippet: "PG&E gas and electric service 2024",
                                      index: idx)
        #expect(named.best?.relativePath == "Home/Utilities/PG&E/2024")
    }

    /// An identifier that lives in exactly one folder is the strongest signal there is — the case
    /// where four screenshots carrying only a case number were placed by an already-filed
    /// confirmation. It has to beat a folder that shares ordinary words.
    @Test func anIdentifierOutweighsSharedVocabulary() {
        let idx = Self.index(memoryDocs: [
            "Health/Medical/Kaiser/Surgery": ["AA00CVPBHP", "record"],
            "Finance/US/Income Tax/2023": ["record", "statement", "summary"],
        ])
        let r = FilingRouter.rank(fileName: "scan.pdf",
                                  contentSnippet: "record AA00CVPBHP summary", index: idx)
        #expect(r.best?.relativePath == "Health/Medical/Kaiser/Surgery")
    }

    /// **Inboxes are never destinations.** Listing one actively teaches the classifier to file into
    /// the place things go when they have nowhere to go. Matching has to be on a whole path
    /// component: a first cut of this leaked 105 inbox folders into a destination list.
    @Test func inboxFoldersAreNeverProposed() {
        let idx = Self.index(memoryDocs: ["Health/TODO/Dental": ["dental", "cleaning"]],
                             extraFolders: ["Health/TODO/Dental", "Health/Dental/2024"])
        let r = FilingRouter.rank(fileName: "dental cleaning.pdf",
                                  contentSnippet: "dental cleaning visit summary", index: idx)
        #expect(r.candidates.allSatisfy { !$0.relativePath.contains("TODO") })
        #expect(!idx.destinations.contains("Health/TODO/Dental"))
    }

    @Test func aRejectedFolderIsNotOfferedAgain() {
        let idx = Self.index(memoryDocs: ["Home/Utilities/PG&E/2023": ["gas", "pge"]])
        let r = FilingRouter.rank(fileName: "b.pdf", contentSnippet: "PG&E gas 2023", index: idx,
                                  excluding: ["Home/Utilities/PG&E/2023"])
        #expect(r.best?.relativePath != "Home/Utilities/PG&E/2023")
    }

    // MARK: - Confidence

    /// The margin is what the app reports as confidence, so it has to move with the evidence: a
    /// document matching one folder alone must not read the same as one matching two equally.
    @Test func theMarginSeparatesAClearWinnerFromATie() {
        let clear = Self.index(memoryDocs: ["Health/Medical/Kaiser/Surgery": ["perioperative", "anesthesia"]])
        let decided = FilingRouter.rank(fileName: "op.pdf",
                                        contentSnippet: "perioperative anesthesia note", index: clear)
        #expect(decided.confidence == .high)

        let tied = Self.index(memoryDocs: [
            "Home/Utilities/PG&E/2023": ["statement"],
            "Home/Utilities/AT&T/2023": ["statement"],
        ])
        let unsure = FilingRouter.rank(fileName: "doc.pdf", contentSnippet: "statement", index: tied)
        #expect(unsure.margin < decided.margin)
    }

    @Test func nothingMatchingYieldsNoCandidates() {
        let idx = Self.index()
        let r = FilingRouter.rank(fileName: "zzz.bin", contentSnippet: "qqqq wwww", index: idx)
        #expect(r.best == nil)
        #expect(r.confidence == .low)
    }

    /// With neither artifact there is nothing to route with, and the caller must get an empty index
    /// rather than a confident wrong answer — this is the "never been surveyed" machine.
    @Test func noProfileAndNoMemoryMeansAnEmptyIndex() {
        let idx = FilingRouter.makeIndex(destinations: ["A/B"], profile: nil, memory: nil)
        #expect(FilingRouter.rank(fileName: "x.pdf", contentSnippet: "x", index: idx).best == nil)
    }

    // MARK: - Tokenizing, which must agree with the builder that wrote the memory

    @Test func tokenizingMatchesTheBuildersRules() {
        #expect(FilingRouter.tokenize("PG&E-2023 bill.pdf") == ["pg", "2023", "bill"])
        #expect(FilingRouter.tokenize("a of the and") == [])          // stop words and length < 2
        #expect(FilingRouter.tokenize("Form W-2") == ["form"])        // "w" and "2" are both < 2 chars
        #expect(FilingRouter.tokenize("9829custbill07182023") == ["9829custbill07182023"])
    }

    @Test func identifiersAndYearsAreRecognised() {
        #expect(FilingRouter.isIdentifier("1892"))
        #expect(FilingRouter.isIdentifier("aa00cvpbhp1"))
        #expect(!FilingRouter.isIdentifier("kaiser"))
        #expect(!FilingRouter.isIdentifier("w2"))                     // too short to discriminate
        #expect(FilingRouter.isYearToken("2023"))
        #expect(!FilingRouter.isYearToken("1492"))
    }

    /// A fiscal span matches fully only when the document names both halves — the Indian tax year
    /// spans two calendar years and a classifier reading one of them must not claim a full match.
    @Test func fiscalSpansNeedBothHalves() {
        #expect(FilingRouter.yearFit("2019-2020", ["2019", "2020"]) == 1.0)
        #expect(FilingRouter.yearFit("2019-2020", ["2019"]) == 0.5)
        #expect(FilingRouter.yearFit("2019-2020", ["2024"]) == -1.0)
        #expect(FilingRouter.yearFit("2023", ["2023"]) == 1.0)
    }
}

/// The inbox rule, and the seam that hands it to a backend. Both were asked in three places with
/// two different answers before this suite existed.
@Suite struct FilingDestinationRuleTests {

    /// **A whole word, not a substring.** `contains("todo")` also refuses `Mastodon` — and it
    /// refused all four real `Misc` folders in the surveyed tree (`Semester Fees/Misc`,
    /// `System Design/Misc`), which are ordinary destinations, not inboxes.
    @Test func inboxMatchingIsOnWholeWords() {
        #expect(FolderProfile.isInboxPath("Documents/TODO"))
        #expect(FolderProfile.isInboxPath("Work/EDD - TODO"))
        #expect(FolderProfile.isInboxPath("Health/New (TODO)/Dental"))
        #expect(FolderProfile.isInboxPath("Home/TODO - May 2025"))
        #expect(!FolderProfile.isInboxPath("Media/Mastodon"))
        #expect(!FolderProfile.isInboxPath("School/IN/BMS College of Engineering/Misc"))
        #expect(!FolderProfile.isInboxPath("Finance/US/Income Tax/2023"))
    }

    /// A backend must be handed destinations, not the raw taxonomy — and the answer must not change
    /// depending on whether a profile happens to be loaded.
    @Test func destinationsExcludeInboxesWithAndWithoutAProfile() {
        let taxonomy = ["Finance/US/Income Tax/2023", "Documents/TODO", "Health/TODO/Dental"]
        let bare = FilingContext(taxonomyFolders: taxonomy)
        #expect(bare.destinations == ["Finance/US/Income Tax/2023"])

        let entry = FolderProfileEntry(path: "Documents/TODO", role: .inbox, naming: nil,
                                       anchors: [], acceptsNewFiles: false, fileCount: 9,
                                       subfolderCount: 0, axes: [:])
        let profiled = FilingContext(taxonomyFolders: taxonomy,
                                     profile: FolderProfile(profileId: "t", root: "~",
                                                            folders: [entry.path: entry],
                                                            personTokens: []))
        #expect(profiled.destinations == bare.destinations)
        #expect(profiled.taxonomyFolders.count == 3)     // the full list is still there to read
    }
}
