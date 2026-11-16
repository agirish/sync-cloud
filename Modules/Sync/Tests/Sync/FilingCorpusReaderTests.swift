import Foundation
import Testing
@testable import Sync

/// The reader stamp on corpus entries: a PDF an older reader recorded blank is read once more,
/// because since 113e76fb1 the app reads a garbled text layer with OCR, and a stamp that never
/// moves would otherwise keep it blank for good (all 50 live PG&E statements on his tree).
@Suite struct FilingCorpusReaderTests {

    static let salt = "reader-salt"

    static func doc(_ anchors: [String] = [], reader: Int, size: Int = 1000,
                    modified: Int = 1_700_000_000) -> FilingCorpusDocument {
        FilingCorpusDocument(size: size, modified: modified, anchors: anchors, idHashes: [],
                             reader: reader)
    }

    static func corpus(_ documents: [String: FilingCorpusDocument]) -> FilingCorpus {
        FilingCorpus(profileId: "t", salt: salt, documents: documents)
    }

    static let stamp = FilingSurvey.Stamp(size: 1000, modified: 1_700_000_000)
    static let legacy = FilingCorpusDocument.legacyReader
    static let current = FilingCorpusDocument.currentReader

    // MARK: - What is read again

    /// Only a blank PDF from the legacy reader. One stamped by today's reader was read with OCR
    /// already; one with tokens was read; an image was OCR'd by every reader; an Office file can't
    /// be read here, so its tokens or blank are the offline builder's to keep.
    @Test func onlyABlankPDFFromTheLegacyReaderIsReadAgain() {
        let paths = ["F/soup.pdf", "F/scan-read-today.pdf", "F/read.pdf", "F/photo.jpg",
                     "F/memo.docx", "F/notes.txt", "F/UPPER.PDF"]
        let tree = FilingSurvey.Tree(folders: ["F": 1],
                                     documents: Dictionary(uniqueKeysWithValues: paths.map { ($0, Self.stamp) }))
        let existing = Self.corpus([
            "F/soup.pdf": Self.doc(reader: Self.legacy),
            "F/scan-read-today.pdf": Self.doc(reader: Self.current),
            "F/read.pdf": Self.doc(["kaiser"], reader: Self.legacy),
            "F/photo.jpg": Self.doc(reader: Self.legacy),
            "F/memo.docx": Self.doc(reader: Self.legacy),
            "F/notes.txt": Self.doc(reader: Self.legacy),
            "F/UPPER.PDF": Self.doc(reader: Self.legacy),
        ])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: existing) == ["F/UPPER.PDF", "F/soup.pdf"])
    }

    /// Once: the read stamps today's reader whether or not it found anything, so a real scan
    /// costs one PDFKit open and is never opened again.
    @Test func theReadStampsTodaysReaderSoItIsNotReadAThirdTime() {
        let tree = FilingSurvey.Tree(folders: ["F": 1], documents: ["F/scan.pdf": Self.stamp])
        let before = Self.corpus(["F/scan.pdf": Self.doc(reader: Self.legacy)])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: before) == ["F/scan.pdf"])

        let blank = FilingSurvey.document(fromPage1: "", stamp: Self.stamp, salt: Self.salt)
        #expect(blank.isBlank && blank.reader == Self.current)
        let after = FilingSurvey.merge(corpus: before, tree: tree, read: ["F/scan.pdf": blank])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: after).isEmpty)
    }

    /// A legacy blank that moved is read at its new path, not carried there blank.
    @Test func aLegacyBlankThatMovedIsReadAtItsNewPath() {
        // The older statement puts Home inside the surveyed region.
        let older = FilingSurvey.Stamp(size: 9, modified: 9)
        let before = Self.corpus(["Inbox/bill.pdf": Self.doc(reader: Self.legacy),
                                  "Home/PG&E/older.pdf": Self.doc(["pge"], reader: Self.legacy, size: 9, modified: 9)])
        let tree = FilingSurvey.Tree(folders: ["Home": 1], documents: ["Home/PG&E/bill.pdf": Self.stamp,
                                                                      "Home/PG&E/older.pdf": older])
        #expect(FilingSurvey.relocations(tree: tree, corpus: before) == ["Home/PG&E/bill.pdf": "Inbox/bill.pdf"])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: before) == ["Home/PG&E/bill.pdf"])
    }

    /// The other side of that: a moved document today's reader stamped still travels unread.
    @Test func aMovedDocumentFromTodaysReaderStillTravelsUnread() {
        let older = FilingSurvey.Stamp(size: 9, modified: 9)
        let before = Self.corpus(["Inbox/scan.pdf": Self.doc(reader: Self.current),
                                  "Home/older.pdf": Self.doc(["pge"], reader: Self.legacy, size: 9, modified: 9)])
        let tree = FilingSurvey.Tree(folders: ["Home": 1], documents: ["Home/scan.pdf": Self.stamp,
                                                                      "Home/older.pdf": older])
        #expect(FilingSurvey.relocations(tree: tree, corpus: before) == ["Home/scan.pdf": "Inbox/scan.pdf"])
        #expect(FilingSurvey.documentsToRead(tree: tree, corpus: before).isEmpty)
    }

    // MARK: - On disk

    /// An entry written before the stamp existed, by the offline builder or an older app, decodes
    /// as the legacy reader; a new one keeps its reader through the round trip, and a legacy one
    /// writes no `r` at all, so it reads back the same.
    @Test func theReaderSurvivesTheRoundTripAndItsAbsenceIsLegacy() throws {
        let old = Data(#"{"s":5,"m":7}"#.utf8)
        #expect(try JSONDecoder().decode(FilingCorpusDocument.self, from: old).reader == Self.legacy)

        let today = FilingSurvey.document(fromPage1: "", stamp: Self.stamp, salt: Self.salt)
        let back = try JSONDecoder().decode(FilingCorpusDocument.self, from: JSONEncoder().encode(today))
        #expect(back == today && back.reader == Self.current)

        let written = try JSONEncoder().encode(Self.doc(reader: Self.legacy))
        let keys = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any]).keys
        #expect(!keys.contains("r"))
    }

    // MARK: - End to end

    /// The frozen state on his tree, through the real re-survey: a folder whose statements the
    /// corpus holds blank from the legacy reader learns them, and the survey after reads nothing.
    @MainActor @Test func aFolderWhoseStatementsWereFrozenBlankLearnsThem() async throws {
        let (manager, docs, profiles, reads, root) = try FilingResurveyTests.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // A third folder, so a word only PG&E's statements hold is rare enough to keep (`minimumIDF`).
        try FilingResurveyTests.write(docs.appendingPathComponent("Home/Xfinity/2026/march.pdf"),
                                      FilingResurveyTests.page("Xfinity Comcast internet service"))
        _ = await manager.resurveyFilingMemory(root: docs)

        // Freeze the PG&E statements the way the corpus holds them: blank, no reader stamp.
        guard case .loaded(let learned) = FilingSurveyStore.corpusRead(id: "t", in: profiles) else {
            Issue.record("fixture: the first survey wrote no corpus"); return
        }
        var frozen = learned
        let statements = frozen.documents.keys.filter { $0.hasPrefix("Home/PG&E/") }.sorted()
        try #require(statements.count == 2, "fixture: both statements must be in the corpus")
        for path in statements {
            let d = frozen.documents[path]!
            frozen.documents[path] = FilingCorpusDocument(size: d.size, modified: d.modified, anchors: [],
                                                          idHashes: [], reader: Self.legacy)
        }
        try JSONEncoder().encode(frozen)
            .write(to: FilingSurveyStore.corpusURL(id: "t", in: profiles), options: .atomic)
        let before = FilingSurvey.buildMemory(corpus: frozen, folderModified: [:], profileId: "t")
        #expect(before.folders["Home/PG&E/2024"] == nil, "fixture: the frozen folder must have learned nothing")
        reads.reset()

        let report = await manager.resurveyFilingMemory(root: docs)

        #expect(reads.paths.map { $0.replacingOccurrences(of: docs.path + "/", with: "") }.sorted()
                == statements, "exactly the frozen statements are read again")
        #expect(report.documentsRead == 2)
        let entry = try #require(manager.filingMemory?.folders["Home/PG&E/2024"])
        #expect(entry.anchors.contains { $0.token == "pacific" }, "the folder learned its statements")

        reads.reset()
        _ = await manager.resurveyFilingMemory(root: docs)
        #expect(reads.paths.isEmpty, "the stamp moved, so a third survey opens nothing")
    }
}
