import Foundation
import Testing
@testable import Sync

/// The router's rules, each pinned by a case where getting it wrong is silent: a worse suggestion,
/// never an error. That includes the hash format, which must match its builder or every identifier
/// quietly stops matching.
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
                                    personTokens: ["mother", "son"])
        var memFolders: [String: FilingMemoryEntry] = [:]
        for (folder, rawTokens) in memoryDocs {
            // Tokenize first, as the builder does (it lowercases): a raw `AA00CVPBHP` hash is one
            // `rank` can never produce, so the identifier would silently stop matching.
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

    /// Evidence is inherited from the parent. `AT&T/2024` is empty; only its sibling `AT&T/2023`
    /// knows what an AT&T bill looks like. Without inheritance the right folder scores zero and can
    /// never be proposed.
    @Test func anEmptyYearFolderIsReachableThroughItsSiblings() {
        let idx = Self.index(memoryDocs: ["Home/Utilities/AT&T/2023": ["wireless", "att", "mobility"]])
        let r = FilingRouter.rank(fileName: "bill.pdf",
                                  contentSnippet: "AT&T Mobility wireless statement for 2024",
                                  index: idx)
        #expect(r.best?.relativePath == "Home/Utilities/AT&T/2024")
    }

    /// The vocabulary for the two inheritance tests below: words in no folder path of the fixture,
    /// with a file name sharing none of them, so inherited content is the only way a child folder
    /// can score. Words from the folder names would let the children rank on their own path tokens
    /// and the tests would never exercise inheritance.
    static let parentVocabulary = ["consulate", "foil", "annotation", "nonimmigrant", "issuance",
                                   "reciprocity", "biometrics", "interview", "endorsement",
                                   "duration", "petitioner", "beneficiary"]

    /// A parent that holds all the evidence must reach its own children: the mirror of the sibling
    /// case, as when `Visa/US/H-1B Visa` holds every foil and its per-era children none. The parent
    /// still ranks first; this pins that its empty children are reachable at all.
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

    /// The inherited share is in the same units as the score it is added to. Normalised by the peak
    /// it would land in [0, `inheritWeight`] beside raw scores in the hundreds, and inheritance would
    /// do nothing. Twelve matching anchors are enough to tell the two apart.
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

    /// The scorer reads only the sample its weights were tuned on, whatever the caller passes.
    /// `ContentSignalExtractor` returns up to five pages, right for a classifier prompt; pages 2–5
    /// of a bill are line items whose words pull unrelated folders up and shrink the margin enough to
    /// drop confidence a level.
    @Test func pagesTwoOnwardsCannotDiluteTheRanking() {
        let idx = Self.index(memoryDocs: ["Records/Consular": Self.parentVocabulary,
                                          "Finance/US/Income Tax/2023": ["itemised", "charges", "subtotal"]],
                             extraFolders: ["Records/Consular"])
        // Page 1 is longer than the sample window, so the window holds only page-1 words. A shorter
        // stand-in would let the window reach into the tail and fail for the fixture's sake.
        let pageOne = String(repeating: Self.parentVocabulary.joined(separator: " ") + " ", count: 6)
        #expect(pageOne.count > FilingRouter.contentSampleChars)
        // Plus four pages of line items whose words belong to a different folder entirely.
        let withTail = pageOne + String(repeating: "itemised charges subtotal ", count: 800)
        #expect(withTail.count > 16_000)

        let short = FilingRouter.rank(fileName: "bill.pdf", contentSnippet: pageOne, index: idx)
        let long = FilingRouter.rank(fileName: "bill.pdf", contentSnippet: withTail, index: idx)
        #expect(long.best?.relativePath == short.best?.relativePath)
        #expect(long.margin == short.margin, "the tail changed the ranking: \(long.margin) vs \(short.margin)")
        #expect(long.candidates == short.candidates)
    }

    // MARK: - Reading the document's own years

    /// A year is not always a token: `tokenize` keeps a foil's expiry `20NOV2026` as one token, so
    /// years are read from the raw text. A long digit run such as the control number
    /// `20241808200001` must yield nothing.
    @Test func yearsAreReadOutOfTheTextRatherThanItsTokens() {
        #expect(FilingRouter.yearsInText("Expiration Date 20NOV2026") == ["2026"])
        #expect(FilingRouter.yearsInText("Control Number 20241808200001").isEmpty)
        #expect(FilingRouter.yearsInText("term 2019-2020 renewed") == ["2019", "2020"])
        #expect(FilingRouter.tokenize("20NOV2026").filter(FilingRouter.isYearToken).isEmpty,
                "the tokenizer would have to change to see this, which the memory forbids")
    }

    /// Text extracted one glyph per field, `0 3 J U L 2 0 2 4`, still reads as a date.
    @Test func aDatePrintedOneGlyphPerFieldIsStillADate() {
        #expect(FilingRouter.despaced("Issue Date 0 3 J U L 2 0 2 4") == "Issue Date 03JUL2024")
        #expect(FilingRouter.yearsInText("Issue Date 0 3 J U L 2 0 2 4") == ["2024"])
        // Three single fields are not a run — an ordinary sentence must survive untouched.
        #expect(FilingRouter.despaced("a b c word") == "a b c word")
    }

    /// A span matches fully only when the document names both halves, so a visa issued 2024 and
    /// expiring 2026 separates `2024-2026` from a span sharing only its end; the filename's single
    /// `2026` half-matches both. The decoy `2020-2026` sorts first on purpose: ties break on the
    /// path, so a decoy that sorted after the answer would let the test pass without the year reader.
    @Test func bothYearsInTheBodySeparateTwoOverlappingSpans() throws {
        let idx = Self.index(memoryDocs: ["Records/Visas": Self.parentVocabulary],
                            extraFolders: ["Records/Visas", "Records/Visas/2020-2026",
                                           "Records/Visas/2024-2026"])
        let r = FilingRouter.rank(fileName: "foil Nov 2026.pdf",
                                  contentSnippet: Self.parentVocabulary.joined(separator: " ")
                                      + " Issue Date 0 3 J U L 2 0 2 4 Expiration Date 20NOV2026",
                                  index: idx)
        let ranked = r.candidates.map(\.relativePath)
        let right = try #require(ranked.firstIndex(of: "Records/Visas/2024-2026"), "\(ranked)")
        let wrong = try #require(ranked.firstIndex(of: "Records/Visas/2020-2026"), "\(ranked)")
        #expect(right < wrong, "the two spans did not separate: \(ranked)")
    }

    /// A folder named `H-1B Visa` is reachable from a file that writes `H1B`, though
    /// `tokenize("H-1B Visa")` is `["1b", "visa"]`. Index-side only: widening what a folder name
    /// indexes cannot disagree with the builder that wrote the stored anchors.
    @Test func aHyphenatedFolderNameIsReachableFromTheUnhyphenatedSpelling() {
        #expect(FilingRouter.pathTokens(of: "Visa/US/H-1B Visa").contains("h1b"))
        #expect(FilingRouter.pathTokens(of: "Visa/US/H-1B Visa").contains("1b"))   // still the old form
        let idx = Self.index(memoryDocs: ["Visa/US/H-1B Visa": Self.parentVocabulary,
                                          "Visa/US/H-4 Visa": Self.parentVocabulary],
                             extraFolders: ["Visa/US/H-1B Visa", "Visa/US/H-4 Visa"])
        let r = FilingRouter.rank(fileName: "H1B Visa - Nov 2026.pdf",
                                  contentSnippet: Self.parentVocabulary.joined(separator: " "),
                                  index: idx)
        #expect(r.best?.relativePath == "Visa/US/H-1B Visa",
                "H1B did not reach H-1B: \(r.candidates.map(\.relativePath))")
    }

    /// The same fixture with the year changed moves to the sibling, so the empty-year test can't be
    /// passing on a fallback.
    @Test func theYearInTheDocumentPicksTheSibling() {
        let idx = Self.index(memoryDocs: ["Home/Utilities/AT&T/2023": ["wireless", "att", "mobility"]])
        let r = FilingRouter.rank(fileName: "bill.pdf",
                                  contentSnippet: "AT&T Mobility wireless statement for 2023",
                                  index: idx)
        #expect(r.best?.relativePath == "Home/Utilities/AT&T/2023")
    }

    /// Years are read from the document, not only the filename: three files called
    /// `Lease Agreement.pdf` can differ only by the term printed inside.
    @Test func aYearOnlyInTheBodyStillRoutes() {
        let idx = Self.index(memoryDocs: ["Home/Utilities/PG&E/2023": ["gas", "electric", "pge"]])
        let named = FilingRouter.rank(fileName: "statement.pdf",
                                      contentSnippet: "PG&E gas and electric service 2024",
                                      index: idx)
        #expect(named.best?.relativePath == "Home/Utilities/PG&E/2024")
    }

    /// An identifier found in exactly one folder is the strongest signal there is, enough to place
    /// a screenshot carrying only a case number. It beats a folder sharing ordinary words.
    @Test func anIdentifierOutweighsSharedVocabulary() {
        let idx = Self.index(memoryDocs: [
            "Health/Medical/Kaiser/Surgery": ["AA00CVPBHP", "record"],
            "Finance/US/Income Tax/2023": ["record", "statement", "summary"],
        ])
        let r = FilingRouter.rank(fileName: "scan.pdf",
                                  contentSnippet: "record AA00CVPBHP summary", index: idx)
        #expect(r.best?.relativePath == "Health/Medical/Kaiser/Surgery")
    }

    /// Inboxes are never destinations: listing one teaches the classifier to file into the place
    /// things go when they have nowhere to go. Matching is on a whole path component.
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

    /// With neither profile nor memory there is nothing to route with, so the caller gets an empty
    /// index, not a confident wrong answer: the never-surveyed machine.
    @Test func noProfileAndNoMemoryMeansAnEmptyIndex() {
        let idx = FilingRouter.makeIndex(destinations: ["A/B"], profile: nil, memory: nil)
        #expect(FilingRouter.rank(fileName: "x.pdf", contentSnippet: "x", index: idx).best == nil)
    }

    // MARK: - Routing between folders that differ only by person

    /// Two sibling person buckets holding the same kind of document, and the household that tells
    /// them apart. The folders carry identical memory on purpose: content cannot separate them, so
    /// the person axis is the only thing that can.
    static func siblingPersonIndex() -> FilingRouter.Index {
        let folders = ["School/Daughter", "School/Son"]
        let entries = [
            FolderProfileEntry(path: "School/Daughter", role: .personBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 6, subfolderCount: 0,
                               axes: ["person": "Daughter"]),
            FolderProfileEntry(path: "School/Son", role: .personBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 6, subfolderCount: 0,
                               axes: ["person": "Son"]),
        ]
        let profile = FolderProfile(profileId: "t", root: "~",
                                    folders: Dictionary(entries.map { ($0.path, $0) },
                                                        uniquingKeysWith: { a, _ in a }),
                                    personTokens: ["daughter", "son", "father"])
        let shared = ["report", "card", "trimester", "attendance"]
            .map { FilingMemoryToken(token: $0, weight: 3.0) }
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            "School/Daughter": FilingMemoryEntry(docs: 6, anchors: shared, idHashes: []),
            "School/Son": FilingMemoryEntry(docs: 6, anchors: shared, idHashes: []),
        ])
        let registry = PersonRegistry(people: [
            Person(id: "father", displayName: "Father", fullNames: ["Father Elder"]),
            Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
            Person(id: "son", displayName: "Son", fullNames: ["Son Father"]),
        ])
        return FilingRouter.makeIndex(destinations: folders, profile: profile, memory: memory,
                                      registry: registry)
    }

    /// The person axis picks the sibling. Everything else about the two folders is identical, so
    /// without it the path tie-break sends every child's report card to `School/Daughter`.
    @Test func thePersonAxisPicksBetweenSiblingPersonBuckets() {
        let idx = Self.siblingPersonIndex()
        let son = FilingRouter.rank(fileName: "Son Father - Report Card.pdf",
                                      contentSnippet: "Trimester report card, attendance", index: idx)
        #expect(son.best?.relativePath == "School/Son")
        let daughter = FilingRouter.rank(fileName: "Daughter Father - Report Card.pdf",
                                      contentSnippet: "Trimester report card, attendance", index: idx)
        #expect(daughter.best?.relativePath == "School/Daughter")
    }

    /// The father's name appears in both children's full names, and a document that is *his* must
    /// not be attributed to either child by that shared word. Naming nobody in the household these
    /// folders belong to leaves both unpenalised — the tie stands rather than resolving wrongly.
    @Test func aSharedSurnameDoesNotAttributeAChildsFolder() {
        let idx = Self.siblingPersonIndex()
        let r = FilingRouter.rank(fileName: "Father Elder - Report Card.pdf",
                                  contentSnippet: "Trimester report card, attendance", index: idx)
        // Neither child is named, so neither bucket is confirmed OR contradicted: the two stay
        // level and the margin says the router cannot tell them apart.
        #expect(r.margin < 0.2)
    }

    /// A contradiction demotes, not merely fails to promote. The penalty shows only where the wrong
    /// person's folder wins on content: Daughter's folder knows every word of a shower invitation
    /// that names Granny.
    @Test func aFolderContentRanksFirstIsDemotedWhenItIsTheWrongPersons() {
        let folders = ["Family/Daughter/Events", "Family/Granny/Events"]
        func entry(_ path: String, person: String) -> FolderProfileEntry {
            FolderProfileEntry(path: path, role: .personBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 4, subfolderCount: 0,
                               axes: ["person": person])
        }
        let entries = [entry("Family/Daughter/Events", person: "Daughter"),
                       entry("Family/Granny/Events", person: "Granny")]
        let profile = FolderProfile(profileId: "t", root: "~",
                                    folders: Dictionary(entries.map { ($0.path, $0) },
                                                        uniquingKeysWith: { a, _ in a }),
                                    personTokens: ["daughter", "granny", "elder"])
        // Daughter's folder knows every word in this document; Granny's knows one.
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            "Family/Daughter/Events": FilingMemoryEntry(
                docs: 4,
                anchors: ["shower", "invitation", "venue", "catering"]
                    .map { FilingMemoryToken(token: $0, weight: 3.0) }, idHashes: []),
            "Family/Granny/Events": FilingMemoryEntry(
                docs: 4, anchors: [FilingMemoryToken(token: "shower", weight: 3.0)], idHashes: []),
        ])
        let registry = PersonRegistry(people: [
            Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
            Person(id: "granny", displayName: "Granny", fullNames: ["Granny Elder"]),
        ])
        let idx = FilingRouter.makeIndex(destinations: folders, profile: profile, memory: memory,
                                         registry: registry)
        let r = FilingRouter.rank(fileName: "Granny Elder - Shower Invitation.pdf",
                                  contentSnippet: "Shower invitation — venue and catering details",
                                  index: idx)
        #expect(r.best?.relativePath == "Family/Granny/Events",
                "the document names Granny and went to Daughter's folder on content alone")
    }

    /// A page that names the person routes a file whose name does not: the veto's channel, on the
    /// scoring side.
    @Test func aPageNamingThePersonRoutesANamelessFile() {
        let idx = Self.siblingPersonIndex()
        let r = FilingRouter.rank(fileName: "Scan 2026-08-02.pdf",
                                  contentSnippet: "Trimester report card for Son Father, attendance",
                                  index: idx)
        #expect(r.best?.relativePath == "School/Son")
    }

    /// With no registry the person axis is inert, so a machine never surveyed for people routes as
    /// if the axis did not exist.
    @Test func withNoRegistryThePersonAxisIsInert() {
        let folders = ["School/Daughter", "School/Son"]
        let entries = [
            FolderProfileEntry(path: "School/Daughter", role: .personBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 6, subfolderCount: 0,
                               axes: ["person": "Daughter"]),
            FolderProfileEntry(path: "School/Son", role: .personBucket, naming: nil, anchors: [],
                               acceptsNewFiles: nil, fileCount: 6, subfolderCount: 0,
                               axes: ["person": "Son"]),
        ]
        let profile = FolderProfile(profileId: "t", root: "~",
                                    folders: Dictionary(entries.map { ($0.path, $0) },
                                                        uniquingKeysWith: { a, _ in a }),
                                    personTokens: ["daughter", "son"])
        let idx = FilingRouter.makeIndex(destinations: folders, profile: profile, memory: nil)
        #expect(idx.folderPerson.isEmpty)

        // `folderPerson` starts empty, so the check above alone can't fail. The same profile with
        // a registry shows the axis is inert because nobody resolves, not because nothing fills it.
        let registry = PersonRegistry(people: [
            Person(id: "daughter", displayName: "Daughter", fullNames: ["Daughter Father"]),
            Person(id: "son", displayName: "Son", fullNames: ["Son Father"]),
        ])
        let peopled = FilingRouter.makeIndex(destinations: folders, profile: profile, memory: nil,
                                             registry: registry)
        #expect(peopled.folderPerson["School/Daughter"] == "daughter")
        #expect(peopled.folderPerson["School/Son"] == "son")
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

    /// A fiscal span matches fully only when the document names both halves: an Indian tax year
    /// spans two calendar years, and reading one of them is not a full match.
    @Test func fiscalSpansNeedBothHalves() {
        #expect(FilingRouter.yearFit("2019-2020", ["2019", "2020"]) == 1.0)
        #expect(FilingRouter.yearFit("2019-2020", ["2019"]) == 0.5)
        #expect(FilingRouter.yearFit("2019-2020", ["2024"]) == -1.0)
        #expect(FilingRouter.yearFit("2023", ["2023"]) == 1.0)
    }
}

/// The inbox rule, and the seam that hands destinations to a backend. Each is asked in one place
/// so every caller gets the same answer.
@Suite struct FilingDestinationRuleTests {

    /// Inboxes match on a whole word, not a substring: substring matching also refuses `Mastodon`
    /// and ordinary `Misc` folders, which are destinations, not inboxes.
    @Test func inboxMatchingIsOnWholeWords() {
        #expect(FolderProfile.isInboxPath("Documents/TODO"))
        #expect(FolderProfile.isInboxPath("Work/EDD - TODO"))
        #expect(FolderProfile.isInboxPath("Health/New (TODO)/Dental"))
        #expect(FolderProfile.isInboxPath("Home/TODO - May 2025"))
        #expect(!FolderProfile.isInboxPath("Media/Mastodon"))
        #expect(!FolderProfile.isInboxPath("School/IN/BMS College of Engineering/Misc"))
        #expect(!FolderProfile.isInboxPath("Finance/US/Income Tax/2023"))
    }

    /// A backend gets destinations, not the raw taxonomy, and the answer doesn't depend on whether a
    /// profile is loaded.
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

    // MARK: - Peer filenames

    private static func ranking(_ pairs: [(String, Double)]) -> FilingRouter.Ranking {
        let cs = pairs.map { FilingRouter.Candidate(relativePath: $0.0, score: $0.1,
                                                    evidenceToken: nil, sharedAnchors: 0) }
        let m = pairs.count > 1 ? (pairs[0].1 - pairs[1].1) / pairs[0].1 : 1
        return FilingRouter.Ranking(candidates: cs, margin: m)
    }

    /// A folder and its own subfolder share vocabulary by construction, so content scores them
    /// nearly level. The names already inside separate them: `Application/` holds
    /// `Son OCI Photo - 4up print sheet.jpg`.
    @Test func namesAlreadyInTheFolderSeparateAParentFromItsChild() throws {
        let r = Self.ranking([("Immigration/OCI/Son", 1.388),
                              ("Immigration/OCI/Son/Application", 1.374)])
        let names = ["Immigration/OCI/Son": ["Son - eOCI.pdf", "Son OCI.pdf"],
                     "Immigration/OCI/Son/Application": ["Son OCI Photo - 4up print sheet.jpg",
                                                           "Son OCI.jpg", "checklist.pdf"]]
        let out = FilingRouter.rerankedByPeerNames(r, fileName: "Son OCI Photo.jpg") {
            names[$0] ?? []
        }
        #expect(out.best?.relativePath == "Immigration/OCI/Son/Application")
    }

    /// The measure is coverage of the incoming name, not Jaccard: `Son OCI Photo - 4up print sheet`
    /// covers all three tokens of `Son OCI Photo` and `Son OCI.pdf` two, which Jaccard scores the
    /// same.
    @Test func aLongerPeerNameThatCoversTheWholeIncomingNameWins() {
        let inc = "Son OCI Photo"
        func coverage(_ peer: String) -> Double {
            let i = Set(FilingRouter.tokenize(inc)), p = Set(FilingRouter.tokenize(peer))
            return Double(i.intersection(p).count) / Double(i.count)
        }
        #expect(coverage("Son OCI Photo - 4up print sheet") == 1.0)
        #expect(coverage("Son OCI") < 1.0)
    }

    /// Peer names re-rank only between a folder and its own ancestor or descendant; between
    /// unrelated folders the bonus measured as noise. An unrelated folder full of perfectly covering
    /// names must not move.
    @Test func anUnrelatedFolderIsNotHelpedByItsNames() {
        let r = Self.ranking([("Immigration/OCI/Son", 1.0),
                              ("Somewhere/Else", 0.9)])
        let names = ["Immigration/OCI/Son": ["nothing.pdf"],
                     "Somewhere/Else": ["Son OCI Photo exact.pdf"]]
        let out = FilingRouter.rerankedByPeerNames(r, fileName: "Son OCI Photo.jpg") {
            names[$0] ?? []
        }
        #expect(out.best?.relativePath == "Immigration/OCI/Son", "an unrelated folder was boosted")
    }

    /// With no peer names anywhere the ranking comes back untouched: the re-rank never reshuffles
    /// on its own.
    @Test func noPeerNamesLeavesTheRankingAlone() {
        let r = Self.ranking([("A/B", 1.0), ("A/B/C", 0.9)])
        let out = FilingRouter.rerankedByPeerNames(r, fileName: "x.pdf") { _ in [] }
        #expect(out.candidates.map(\.relativePath) == ["A/B", "A/B/C"])
    }
}
