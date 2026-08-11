import Foundation
import Testing
@testable import Sync

/// The re-survey's rules. Every one of these fails *silently* when it breaks — a folder that keeps
/// recommending itself for a document that left it, a weight computed on the wrong denominator, a
/// hash that stops matching — so each is pinned against a case where the wrong answer is still a
/// perfectly well-formed memory.
@Suite struct FilingSurveyTests {

    // MARK: - Fixtures

    static let salt = "0123456789abcdef"

    /// A file node with the two fields a survey reads.
    static func file(_ name: String, size: Int = 1000, modified: Int = 1_700_000_000) -> FileNode {
        FileNode(id: "/x/" + name, name: name, isDirectory: false,
                 modificationDate: Date(timeIntervalSince1970: TimeInterval(modified)),
                 fileSize: size)
    }

    static func folder(_ name: String, modified: Int = 1_700_000_000, _ children: [FileNode]) -> FileNode {
        FileNode(id: "/x/" + name, name: name, isDirectory: true, children: children,
                 modificationDate: Date(timeIntervalSince1970: TimeInterval(modified)))
    }

    /// A document carrying the given readable tokens, stamped however the caller likes.
    static func doc(_ anchors: [String], ids: [String] = [], size: Int = 1000,
                    modified: Int = 1_700_000_000) -> FilingCorpusDocument {
        FilingCorpusDocument(size: size, modified: modified, anchors: anchors,
                             idHashes: ids.map { FilingMemory.hash($0, salt: salt) })
    }

    static func corpus(_ documents: [String: FilingCorpusDocument]) -> FilingCorpus {
        FilingCorpus(profileId: "t", salt: salt, documents: documents)
    }

    // MARK: - Flattening the walk

    @Test func flattenBuildsPathsStructurallyAndSkipsDotFiles() {
        let tree = FilingSurvey.flatten([
            Self.folder("Home", modified: 111, [
                Self.folder("Utilities", modified: 222, [Self.file("bill.pdf", size: 42, modified: 333)]),
                Self.file(".DS_Store"),
            ]),
        ])
        #expect(tree.folders == ["Home": 111, "Home/Utilities": 222])
        #expect(tree.documents == ["Home/Utilities/bill.pdf": FilingSurvey.Stamp(size: 42, modified: 333)])
    }

    /// A folder the walk stopped at has children nobody looked at, so its mtime must not be recorded
    /// as having vouched for them — the next survey would skip it for good.
    @Test func flattenRefusesToStampAnUnexploredFolder() {
        var capped = Self.folder("Deep", modified: 999, [])
        capped.isUnexplored = true
        let tree = FilingSurvey.flatten([Self.folder("Home", modified: 111, [capped])])
        #expect(tree.folders == ["Home": 111])
    }

    /// The other half of the same fact: a folder the walk stopped at is *recorded* as unexplored,
    /// not merely skipped. Without the record, "nobody looked here" and "these are gone" are the
    /// same reading — see `aDocumentUnderAnUnwalkedFolderIsNotDropped`.
    @Test func flattenRemembersWhichFoldersItCouldNotEnter() {
        var capped = Self.folder("Deep", modified: 999, [])
        capped.isUnexplored = true
        let tree = FilingSurvey.flatten([Self.folder("Home", modified: 111, [capped])])
        #expect(tree.unexplored == ["Home/Deep"])
        #expect(tree.wasNotWalked("Home/Deep/tax return.pdf"))
        #expect(!tree.wasNotWalked("Home/bill.pdf"), "a walked branch must not be excused")
        // Prefix matching is on path SEGMENTS: a sibling that merely starts with the same letters
        // was walked, and excusing it would keep documents that really are gone.
        #expect(!tree.wasNotWalked("Home/Deeper/x.pdf"))
    }

    // MARK: - What is stale

    @Test func aFolderIsStaleWhenItsMtimeMovedOrItIsUnknown() {
        let memory = FilingMemory(profileId: "t", salt: Self.salt, folders: [
            "Home": FilingMemoryEntry(docs: 2, anchors: [], idHashes: [], folderModified: 111),
            "Work": FilingMemoryEntry(docs: 2, anchors: [], idHashes: [], folderModified: 222),
        ])
        let tree = FilingSurvey.Tree(folders: ["Home": 111, "Work": 999, "New": 333], documents: [:])
        #expect(FilingSurvey.staleFolders(tree: tree, memory: memory) == ["Work", "New"])
    }

    /// An entry from a build that never stamped anything reads as stale rather than as current —
    /// otherwise upgrading to a stamping builder would freeze the tree in place.
    @Test func anUnstampedEntryIsStale() {
        let memory = FilingMemory(profileId: "t", salt: Self.salt,
                                  folders: ["Home": FilingMemoryEntry(docs: 2, anchors: [], idHashes: [])])
        let tree = FilingSurvey.Tree(folders: ["Home": 111], documents: [:])
        #expect(FilingSurvey.staleFolders(tree: tree, memory: memory) == ["Home"])
    }

    @Test func onlyChangedAndUnknownDocumentsAreRead() {
        let tree = FilingSurvey.Tree(folders: ["F": 1], documents: [
            "F/same.pdf": FilingSurvey.Stamp(size: 10, modified: 100),
            "F/edited.pdf": FilingSurvey.Stamp(size: 11, modified: 101),
            "F/new.pdf": FilingSurvey.Stamp(size: 12, modified: 102),
        ])
        let existing = Self.corpus([
            "F/same.pdf": Self.doc(["kaiser"], size: 10, modified: 100),
            "F/edited.pdf": Self.doc(["kaiser"], size: 10, modified: 100),
        ])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: existing) == ["F/edited.pdf", "F/new.pdf"])
    }

    /// The whole point, stated as a number: an untouched tree costs no reads at all.
    @Test func anUnchangedTreeReadsNothing() {
        let tree = FilingSurvey.Tree(folders: ["F": 1], documents: [
            "F/a.pdf": FilingSurvey.Stamp(size: 10, modified: 100), "F/b.pdf": FilingSurvey.Stamp(size: 20, modified: 200),
        ])
        let existing = Self.corpus(["F/a.pdf": Self.doc(["x"], size: 10, modified: 100),
                                    "F/b.pdf": Self.doc(["y"], size: 20, modified: 200)])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: existing).isEmpty)
    }

    /// A type the app cannot read is not queued for reading — the alternative is opening it every
    /// survey, failing, and recording a blank over tokens the offline generator produced.
    @Test func unreadableTypesAreNeverQueued() {
        let tree = FilingSurvey.Tree(folders: ["F": 1],
                                     documents: ["F/deck.pptx": FilingSurvey.Stamp(size: 1, modified: 1)])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: nil).isEmpty)
    }

    /// Markdown is not a filed document here, and adding it would mix notes written under a
    /// different rule into the same IDF as the corpus it extends.
    @Test func markdownIsOutsideTheDocumentSet() {
        #expect(!FilingSurvey.readableExtensions.contains("md"))
        let tree = FilingSurvey.Tree(folders: ["F": 1], documents: [
            "F/notes.md": FilingSurvey.Stamp(size: 1, modified: 1),
            "F/bill.pdf": FilingSurvey.Stamp(size: 1, modified: 1),
        ])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: nil) == ["F/bill.pdf"])
    }

    // MARK: - Scope

    /// **A survey extends a corpus; it does not decide what the corpus should have been.** A branch
    /// nothing was ever surveyed in stays out — on the real tree that is `Claude/`, 554 readable
    /// files of project notes the offline survey deliberately skipped, which the app cannot tell
    /// from a leaf destination by looking at the profile.
    @Test func aBranchNothingWasEverSurveyedInStaysOut() {
        let existing = Self.corpus(["Home/Utilities/PG&E/2024/jan.pdf": Self.doc(["pge"])])
        let tree = FilingSurvey.Tree(folders: ["Home": 1, "Claude": 1], documents: [
            "Home/Utilities/PG&E/2024/jan.pdf": FilingSurvey.Stamp(size: 1000, modified: 1_700_000_000),
            "Claude/Projects/report.pdf": FilingSurvey.Stamp(size: 5, modified: 5),
        ])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: existing).isEmpty)
    }

    /// The other half, and the reason scope is closed *upwards*: a folder created today under a
    /// branch that has been surveyed is exactly what this feature exists to learn.
    @Test func aNewFolderUnderASurveyedBranchIsInScope() {
        let existing = Self.corpus(["Home/Utilities/PG&E/2024/jan.pdf": Self.doc(["pge"])])
        let tree = FilingSurvey.Tree(folders: ["Home": 1], documents: [
            "Home/Utilities/PG&E/2024/jan.pdf": FilingSurvey.Stamp(size: 1000, modified: 1_700_000_000),
            "Home/Xfinity/2026/march.pdf": FilingSurvey.Stamp(size: 5, modified: 5),
        ])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: existing) == ["Home/Xfinity/2026/march.pdf"])
    }

    /// A memory with no corpus still bounds the region — the state of any machine whose artifacts
    /// were installed before this existed.
    @Test func theMemoryAloneBoundsTheRegion() {
        let memory = FilingMemory(profileId: "t", salt: Self.salt, folders: [
            "Home/Utilities/PG&E/2024": FilingMemoryEntry(docs: 2, anchors: [], idHashes: []),
        ])
        let tree = FilingSurvey.Tree(folders: ["Home": 1, "Claude": 1], documents: [
            "Home/new.pdf": FilingSurvey.Stamp(size: 5, modified: 5),
            "Claude/notes.pdf": FilingSurvey.Stamp(size: 5, modified: 5),
        ])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: nil, memory: memory) == ["Home/new.pdf"])
    }

    /// A machine with nothing to extend reads everything — the only thing a first survey could
    /// sensibly do, and the case where an empty region must not mean an empty scope.
    @Test func aMachineWithNoArtifactsSurveysTheWholeTree() {
        let tree = FilingSurvey.Tree(folders: ["Anywhere": 1],
                                     documents: ["Anywhere/a.pdf": FilingSurvey.Stamp(size: 5, modified: 5)])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: nil, memory: nil) == ["Anywhere/a.pdf"])
    }

    // MARK: - Moves

    @Test func aMovedDocumentCarriesItsTokensInsteadOfBeingReread() {
        let before = Self.corpus(["Docs/Inbox/bill.pdf": Self.doc(["pge", "electric"], size: 77, modified: 500)])
        let tree = FilingSurvey.Tree(folders: ["Home": 1],
                                     documents: ["Docs/Home/PG&E/bill.pdf": FilingSurvey.Stamp(size: 77, modified: 500)])
        #expect(FilingSurvey.relocations(tree: tree, corpus: before) == ["Docs/Home/PG&E/bill.pdf": "Docs/Inbox/bill.pdf"])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: before).isEmpty)

        let after = FilingSurvey.merge(corpus: before, tree: tree, read: [:])
        #expect(after.documents["Docs/Home/PG&E/bill.pdf"]?.anchors == ["pge", "electric"])
        #expect(after.documents["Docs/Inbox/bill.pdf"] == nil)
    }

    /// **Two** documents left wearing the same stamp and **one** arrived: whichever of the two it
    /// is, half the time the wrong one's content lands in the new folder. Two files sharing a size
    /// to the byte and an mtime to the second cannot be told apart, so neither is guessed at.
    @Test func twoDeparturesMatchingOneArrivalAreRefused() {
        let before = Self.corpus(["Docs/Inbox/a.pdf": Self.doc(["alpha"], size: 77, modified: 500),
                                  "Docs/Inbox/b.pdf": Self.doc(["beta"], size: 77, modified: 500)])
        let tree = FilingSurvey.Tree(folders: ["Home": 1],
                                     documents: ["Docs/Home/x.pdf": FilingSurvey.Stamp(size: 77, modified: 500)])
        #expect(FilingSurvey.relocations(tree: tree, corpus: before).isEmpty)
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: before) == ["Docs/Home/x.pdf"])
    }

    /// The other half of ambiguity, and the half that is easy to leave untested: **one** document
    /// left, **two** arrived wearing its stamp. Matching it to either one attributes its content to
    /// a folder it may never have been in — and picks which by whichever path hashed first.
    @Test func oneDepartureMatchingTwoArrivalsIsAlsoRefused() {
        let before = Self.corpus(["Docs/Inbox/scan.pdf": Self.doc(["kaiser"], size: 77, modified: 500)])
        let tree = FilingSurvey.Tree(folders: ["Home": 1], documents: [
            "Docs/Health/a.pdf": FilingSurvey.Stamp(size: 77, modified: 500),
            "Docs/Finance/b.pdf": FilingSurvey.Stamp(size: 77, modified: 500),
        ])
        #expect(FilingSurvey.relocations(tree: tree, corpus: before).isEmpty)
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: before) == ["Docs/Finance/b.pdf", "Docs/Health/a.pdf"])
    }

    /// A stamp is a coincidence, not an identity. Two documents of different types that happen to
    /// share one are not the same document — a page of tokens from a PDF has no business being
    /// attributed to an image.
    @Test func aStampMatchAcrossTypesIsNotAMove() {
        let before = Self.corpus(["Docs/Inbox/a.pdf": Self.doc(["alpha"], size: 77, modified: 500)])
        let tree = FilingSurvey.Tree(folders: ["Docs": 1],
                                     documents: ["Docs/Home/a.png": FilingSurvey.Stamp(size: 77, modified: 500)])
        #expect(FilingSurvey.relocations(tree: tree, corpus: before).isEmpty)
    }

    /// Every filing move is a departure from somewhere. A corpus that only grows keeps the folder a
    /// document left recommending itself for it.
    @Test func aDocumentThatLeftStopsCountingTowardsItsOldFolder() {
        let before = Self.corpus(["Old/gone.pdf": Self.doc(["kaiser"], size: 5, modified: 5),
                                  "Old/stays.pdf": Self.doc(["kaiser"], size: 6, modified: 6)])
        let tree = FilingSurvey.Tree(folders: ["Old": 1],
                                     documents: ["Old/stays.pdf": FilingSurvey.Stamp(size: 6, modified: 6)])
        let after = FilingSurvey.merge(corpus: before, tree: tree, read: [:])
        #expect(after.documents.keys.sorted() == ["Old/stays.pdf"])
        let memory = FilingSurvey.buildMemory(corpus: after, folderModified: ["Old": 1])
        #expect(memory.folders["Old"]?.docs == 1)
    }

    /// **The drop rule must fire on evidence of departure, never on absence of coverage.** One
    /// permission-denied folder contributes nothing to `tree.documents`, so before this every
    /// document under it read as deleted and was erased from the corpus — months of page-1 reads,
    /// gone on a pass that reports "0 documents read".
    @Test func aDocumentUnderAnUnwalkedFolderIsNotDropped() {
        let before = Self.corpus(["Locked/deed.pdf": Self.doc(["grant"], size: 5, modified: 5),
                                  "Open/gone.pdf": Self.doc(["kaiser"], size: 6, modified: 6),
                                  "Open/stays.pdf": Self.doc(["kaiser"], size: 7, modified: 7)])
        // The walk entered `Open` and found one of its two documents; it could not enter `Locked`.
        let tree = FilingSurvey.Tree(
            folders: ["Open": 1],
            documents: ["Open/stays.pdf": FilingSurvey.Stamp(size: 7, modified: 7)],
            unexplored: ["Locked"])

        let after = FilingSurvey.merge(corpus: before, tree: tree, read: [:])

        #expect(after.documents.keys.sorted() == ["Locked/deed.pdf", "Open/stays.pdf"])
        // Both directions in one fixture: the unwalked branch is kept AND the real departure from
        // the walked branch is still dropped. A guard that simply stopped dropping would pass the
        // first half and fail here.
        #expect(after.documents["Open/gone.pdf"] == nil,
                "a document the walk looked for and did not find must still be dropped")
    }

    /// An empty walk is the whole-root version of the same mistake, and the one that erases
    /// everything at once. `merge` alone cannot tell it from a tree wiped clean, which is why the
    /// survey refuses before reaching here — this pins what `merge` does if it ever does arrive.
    @Test func anEmptyWalkUnderAnUnexploredRootKeepsTheWholeCorpus() {
        let before = Self.corpus(["A/one.pdf": Self.doc(["x"], size: 1, modified: 1),
                                  "B/two.pdf": Self.doc(["y"], size: 2, modified: 2)])
        let tree = FilingSurvey.Tree(folders: [:], documents: [:], unexplored: ["A", "B"])
        let after = FilingSurvey.merge(corpus: before, tree: tree, read: [:])
        #expect(after.documents.count == 2)
    }

    // MARK: - Reading one document

    @Test func glyphSoupIsRecordedAsBlankRatherThanAsAnchors() {
        let soup = "') ! ) ) ! A A @ A 1 < H < d9 lm g8 ') ! ) ) ! A A @ A 1 < H < d9 lm g8"
        let read = FilingSurvey.document(fromPage1: soup, stamp: FilingSurvey.Stamp(size: 1, modified: 1), salt: Self.salt)
        #expect(read.isBlank)
    }

    @Test func aRealPageYieldsReadableAnchorsAndHashedIdentifiers() {
        let page = "Pacific Gas and Electric Company. Your account statement for the service period. "
            + "Account number 8412330091. Please pay the total amount due by the date shown."
        let read = FilingSurvey.document(fromPage1: page, stamp: FilingSurvey.Stamp(size: 1, modified: 1), salt: Self.salt)
        #expect(read.anchors.contains("pacific"))
        #expect(read.anchors.contains("electric"))
        // The account number is present, and present only as a hash.
        #expect(read.idHashes.contains(FilingMemory.hash("8412330091", salt: Self.salt)))
        #expect(!read.anchors.contains("8412330091"))
        #expect(!read.anchors.contains(where: { $0.contains(where: \.isNumber) }))
    }

    /// The sample is bounded at page 1's first 400 characters, and nothing past it may reach a token.
    @Test func onlyTheFirstFourHundredCharactersAreRead() {
        let page = String(repeating: "the account statement is here. ", count: 40) + " zebrafish"
        #expect(page.count > FilingSurvey.snippetChars)
        let read = FilingSurvey.document(fromPage1: page, stamp: FilingSurvey.Stamp(size: 1, modified: 1), salt: Self.salt)
        #expect(!read.anchors.contains("zebrafish"))
    }

    // MARK: - Building the memory

    /// Rarity is counted in folders. A token every folder holds must not outrank one only this
    /// folder holds, however often it appears.
    @Test func aTokenInEveryFolderIsDroppedAndARareOneIsKept() {
        var documents: [String: FilingCorpusDocument] = [:]
        for i in 0..<10 {
            documents["F\(i)/a.pdf"] = Self.doc(["common"], size: i, modified: i)
            documents["F\(i)/b.pdf"] = Self.doc(["common"], size: 100 + i, modified: i)
        }
        documents["F0/c.pdf"] = Self.doc(["kaiser"], size: 900, modified: 9)
        documents["F0/d.pdf"] = Self.doc(["kaiser"], size: 901, modified: 9)
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: [:])
        let anchors = memory.folders["F0"]?.anchors.map(\.token) ?? []
        #expect(anchors.contains("kaiser"))
        #expect(!anchors.contains("common"))
    }

    /// A token seen in exactly one of a folder's documents is usually extraction noise, and noise
    /// takes the *highest* rarity precisely because it occurs nowhere else.
    @Test func aOnceSeenTokenIsDroppedOnceAFolderHasEnoughDocuments() {
        var documents: [String: FilingCorpusDocument] = [:]
        for i in 0..<3 { documents["F/\(i).pdf"] = Self.doc(["pge"], size: i, modified: i) }
        documents["F/2.pdf"] = Self.doc(["pge", "d9x"], size: 2, modified: 2)
        // Somewhere else to be rare against.
        for i in 0..<6 { documents["G\(i)/x.pdf"] = Self.doc(["unrelated\(i)"], size: i, modified: i) }
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: [:])
        let anchors = memory.folders["F"]?.anchors.map(\.token) ?? []
        #expect(anchors.contains("pge"))
        #expect(!anchors.contains("d9x"))
    }

    /// Under three documents there is no recurrence to require, so a folder with one filed document
    /// still learns from it — the case that matters most for a folder created yesterday.
    @Test func aBrandNewFolderWithOneDocumentStillLearns() {
        var documents = ["New/first.pdf": Self.doc(["xfinity", "internet"])]
        for i in 0..<8 { documents["Old\(i)/x.pdf"] = Self.doc(["unrelated\(i)"], size: i, modified: i) }
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: ["New": 42])
        #expect(memory.folders["New"]?.docs == 1)
        #expect(memory.folders["New"]?.anchors.map(\.token).contains("xfinity") == true)
        #expect(memory.folders["New"]?.folderModified == 42)
    }

    /// The filename is part of what a document says, and it is derived at build time so a rename
    /// costs a re-key rather than a re-read.
    @Test func filenameTokensJoinTheContentTokens() {
        var documents = ["F/Kaiser Explanation of Benefits.pdf": Self.doc(["cardiology"])]
        for i in 0..<8 { documents["G\(i)/x.pdf"] = Self.doc(["unrelated\(i)"], size: i, modified: i) }
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: [:])
        let anchors = memory.folders["F"]?.anchors.map(\.token) ?? []
        #expect(anchors.contains("kaiser"))
        #expect(anchors.contains("cardiology"))
    }

    /// A blank document is stamped so it is not re-read, and counts towards nothing.
    @Test func blankDocumentsCountTowardsNothing() {
        let documents = ["F/scan.pdf": Self.doc([]), "F/real.pdf": Self.doc(["kaiser"])]
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: [:])
        #expect(memory.folders["F"]?.docs == 1)
    }

    /// What is stored is the plain rarity, not the score the ordering used — the router weighs how
    /// much a token discriminates, and reading back the selection score would double-count the
    /// folder's own volume.
    @Test func theStoredWeightIsRarityNotTheSelectionScore() {
        var documents: [String: FilingCorpusDocument] = [:]
        for i in 0..<4 { documents["F/\(i).pdf"] = Self.doc(["kaiser"], size: i, modified: i) }
        for i in 0..<6 { documents["G\(i)/x.pdf"] = Self.doc(["unrelated\(i)"], size: i, modified: i) }
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: [:])
        let kaiser = memory.folders["F"]?.anchors.first { $0.token == "kaiser" }
        // Seven folders hold a token; only F holds "kaiser" → log(8/2) = 1.386…, stored to 2dp.
        #expect(kaiser?.weight == 1.39)
    }

    /// **Recurrence is recorded, and survives being written out.** It is optional *by position*, so
    /// a writer that stops emitting it produces a file that still decodes perfectly and quietly takes
    /// the rule proposer back to keying on the rarest word instead of the recurring one — no error,
    /// anywhere. A token in three of a folder's four documents reads back as 0.75.
    @Test func recurrenceIsBuiltAndSurvivesTheRoundTrip() throws {
        var documents: [String: FilingCorpusDocument] = [:]
        for i in 0..<4 { documents["F/\(i).pdf"] = Self.doc(i < 3 ? ["autopay", "tmobile"] : ["tmobile"],
                                                            size: i, modified: i) }
        for i in 0..<8 { documents["G\(i)/x.pdf"] = Self.doc(["unrelated\(i)"], size: i, modified: i) }
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: [:])
        let autopay = try #require(memory.folders["F"]?.anchors.first { $0.token == "autopay" })
        #expect(autopay.docFrequency == 0.75)

        let data = try JSONEncoder().encode(memory.folders)
        let read = try JSONDecoder().decode([String: FilingMemoryEntry].self, from: data)
        #expect(read["F"]?.anchors.first { $0.token == "autopay" }?.docFrequency == 0.75)
        #expect(read == memory.folders)
    }

    /// The router hashes a candidate file's identifiers with the memory's salt and compares for
    /// equality. A memory built under a different salt matches nothing — silently.
    @Test func identifiersSurviveTheRoundTripToTheRouter() {
        var documents = ["F/eob.pdf": Self.doc(["kaiser"], ids: ["mrn4471902"])]
        for i in 0..<8 { documents["G\(i)/x.pdf"] = Self.doc(["unrelated\(i)"], size: i, modified: i) }
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: [:])
        let stored = memory.folders["F"]?.idHashes.map(\.token) ?? []
        #expect(stored.contains(memory.hash("mrn4471902")))
    }

    /// Two runs over the same corpus must produce the same file, or every survey looks like a change
    /// and throws away the verdict cache.
    @Test func theBuildIsDeterministic() {
        var documents: [String: FilingCorpusDocument] = [:]
        for i in 0..<40 {
            documents["F\(i % 5)/\(i).pdf"] = Self.doc(["tok\(i % 7)", "tok\(i % 11)", "shared"],
                                                       size: i, modified: i)
        }
        let c = Self.corpus(documents)
        #expect(FilingSurvey.buildMemory(corpus: c, folderModified: [:])
                == FilingSurvey.buildMemory(corpus: c, folderModified: [:]))
    }

    /// Caps are what keep the file to a few megabytes; they are also the boundary where a
    /// tie-breaking difference would show up as a different set of anchors.
    @Test func anchorsAndIdentifiersAreCapped() {
        var anchors: [String] = [], ids: [String] = []
        for i in 0..<60 { anchors.append("word\(i)a"); ids.append("id\(i)9999") }
        var documents = ["F/a.pdf": Self.doc(anchors, ids: ids, size: 1, modified: 1),
                         "F/b.pdf": Self.doc(anchors, ids: ids, size: 2, modified: 2)]
        for i in 0..<8 { documents["G\(i)/x.pdf"] = Self.doc(["unrelated\(i)"], size: i, modified: i) }
        let memory = FilingSurvey.buildMemory(corpus: Self.corpus(documents), folderModified: [:])
        #expect(memory.folders["F"]?.anchors.count == FilingSurvey.maxAnchors)
        #expect(memory.folders["F"]?.idHashes.count == FilingSurvey.maxIdHashes)
    }
}
