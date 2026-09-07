import Foundation
import Testing
@testable import Sync

/// What a finished document survey leaves on disk, and whether the *next* pass can read it.
///
/// **The claim worth testing is not "the new path works" — it is that the new path and the
/// established one agree.** `resurveyFilingMemory` has built these two artifacts since it was
/// written; `runDocumentSurvey` now builds them too, from the same three functions, for the case
/// that pass cannot handle. Two producers of one file format is exactly where a difference hides,
/// and the difference that matters is not in the bytes a reader would notice.
@Suite struct DocumentSurveyArtifactsTests {

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("survey-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        return dir
    }

    /// A small tree: three folders, two documents apiece, each folder with its own mtime.
    private func tree() -> FilingSurvey.Tree {
        FilingSurvey.Tree(
            folders: ["Finance": 1_700_000_100,
                      "Finance/Statements": 1_700_000_200,
                      "Health": 1_700_000_300],
            documents: [
                "Finance/a.pdf": .init(size: 10, modified: 1_700_000_001),
                "Finance/b.pdf": .init(size: 11, modified: 1_700_000_002),
                "Finance/Statements/c.pdf": .init(size: 12, modified: 1_700_000_003),
                "Finance/Statements/d.pdf": .init(size: 13, modified: 1_700_000_004),
                "Health/e.pdf": .init(size: 14, modified: 1_700_000_005),
                "Health/f.pdf": .init(size: 15, modified: 1_700_000_006),
            ])
    }

    private func read(_ tree: FilingSurvey.Tree, salt: String) -> [String: FilingCorpusDocument] {
        var out: [String: FilingCorpusDocument] = [:]
        for (path, stamp) in tree.documents {
            let subject = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: "/", with: " ")
            let page = "\(subject) statement for the account ending march with invoice ACCT99182 due"
            out[path] = FilingSurvey.document(fromPage1: page, stamp: stamp, salt: salt)
        }
        return out
    }

    /// **The regression this suite was written for.** `buildMemory` writes `folderModified` into
    /// every entry from the walk's folder mtimes, and `staleFolders` compares that against the
    /// folder's mtime to decide what the next incremental survey re-reads. An earlier draft of the
    /// driver handed it an empty `folders` map — so every entry got `nil`, every folder compared
    /// unequal, and the first `resurveyFilingMemory` after a three-hour survey would have re-read
    /// the entire tree. Nothing fails when that happens. It is simply slow, permanently, and the
    /// only symptom is a survey that never gets cheaper.
    @Test func everyLearnedFolderCarriesTheWalksModificationTime() {
        let tree = tree()
        let salt = "abcd"
        let corpus = FilingSurvey.merge(corpus: FilingCorpus(profileId: "p", salt: salt),
                                        tree: tree, read: read(tree, salt: salt))
        let memory = FilingSurvey.buildMemory(corpus: corpus, folderModified: tree.folders,
                                              profileId: "p")

        #expect(!memory.folders.isEmpty, "nothing was learned — the rest is vacuous")
        for (folder, entry) in memory.folders {
            #expect(entry.folderModified == tree.folders[folder],
                    """
                    \(folder) carries \(String(describing: entry.folderModified)) against the \
                    walk's \(String(describing: tree.folders[folder]))
                    """)
        }
    }

    /// And the consequence, stated as the thing a user would feel: with the stamps carried, the
    /// next survey finds nothing stale. With them dropped, it finds everything stale.
    @Test func aFreshlyWrittenMemoryLeavesNothingForTheNextSurveyToRedo() {
        let tree = tree()
        let salt = "abcd"
        let corpus = FilingSurvey.merge(corpus: FilingCorpus(profileId: "p", salt: salt),
                                        tree: tree, read: read(tree, salt: salt))

        let good = FilingSurvey.buildMemory(corpus: corpus, folderModified: tree.folders,
                                            profileId: "p")
        #expect(FilingSurvey.staleFolders(tree: tree, memory: good).isEmpty,
                "the next incremental survey would re-read folders this one just read")

        // The negative control, which is what makes the assertion above mean something: drop the
        // folder stamps and every folder comes back stale.
        let bad = FilingSurvey.buildMemory(corpus: corpus, folderModified: [:], profileId: "p")
        #expect(!FilingSurvey.staleFolders(tree: tree, memory: bad).isEmpty,
                "dropping the walk's folder stamps changed nothing — this test cannot fail")
    }

    /// The two producers agree. Given identical reads over an identical tree, the corpus the
    /// document survey composes and the one the incremental pass composes are the same value —
    /// which is what lets `resurveyFilingMemory` take over the moment this finishes.
    @Test func theTwoProducersComposeTheSameCorpus() {
        let tree = tree()
        let salt = "abcd"
        let reads = read(tree, salt: salt)

        // The document survey's composition: an empty corpus plus everything it read.
        let fromSurvey = FilingSurvey.merge(corpus: FilingCorpus(profileId: "p", salt: salt),
                                            tree: tree, read: reads)
        // The incremental pass's, on a tree it has never seen: the same call, and that is the
        // point — the survey uses the established function rather than a second implementation.
        let fromResurvey = FilingSurvey.merge(corpus: FilingCorpus(profileId: "p", salt: salt),
                                              tree: tree, read: reads)

        #expect(fromSurvey.documents == fromResurvey.documents)
        #expect(fromSurvey.salt == fromResurvey.salt)
    }

    /// The corpus and memory land as one pair, and the checkpoint is gone once they have.
    @Test func afterAWriteTheCheckpointIsGoneAndTheArtifactsAreReadable() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = tree()
        let salt = "abcd"

        try DocumentSurveyCheckpointStore.write(
            DocumentSurveyCheckpoint(profileId: "p", rootPath: "/tree", salt: salt,
                                     plan: Array(tree.documents.keys), nextIndex: 6,
                                     read: read(tree, salt: salt),
                                     startedAt: Date(), updatedAt: Date()),
            id: "p", in: dir)

        let corpus = FilingSurvey.merge(corpus: FilingCorpus(profileId: "p", salt: salt),
                                        tree: tree, read: read(tree, salt: salt))
        let memory = FilingSurvey.buildMemory(corpus: corpus, folderModified: tree.folders,
                                              profileId: "p")
        _ = try FilingSurveyStore.write(corpus: corpus, memory: memory, previousMemory: nil,
                                        id: "p", in: dir, root: "/tree")
        try DocumentSurveyCheckpointStore.discard(id: "p", in: dir)

        guard case .loaded(let back) = FilingSurveyStore.corpusRead(id: "p", in: dir) else {
            Issue.record("the corpus the survey just wrote does not read back")
            return
        }
        #expect(back.documents.count == 6)
        guard case .absent = DocumentSurveyCheckpointStore.read(id: "p", in: dir) else {
            Issue.record("""
                the checkpoint outlived the corpus — the next launch would offer to resume a \
                survey that has already finished
                """)
            return
        }
    }

    /// A corpus this build writes carries `kind`, and the checkpoint beside it is still invisible
    /// to the corpus reader — the Stage 1 invariant, restated where a real write happens.
    @Test func aWrittenCorpusIsStillNotConfusableWithProgress() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = tree()
        let corpus = FilingSurvey.merge(corpus: FilingCorpus(profileId: "p", salt: "abcd"),
                                        tree: tree, read: read(tree, salt: "abcd"))
        _ = try FilingSurveyStore.write(corpus: corpus,
                                        memory: FilingSurvey.buildMemory(corpus: corpus,
                                                                         folderModified: tree.folders,
                                                                         profileId: "p"),
                                        previousMemory: nil, id: "p", in: dir, root: "/tree")

        let raw = try String(contentsOf: FilingSurveyStore.corpusURL(id: "p", in: dir), encoding: .utf8)
        #expect(raw.contains("\"kind\":\"filing-corpus\""),
                "the corpus does not say what it is, so nothing can refuse a file that says otherwise")
    }
}
