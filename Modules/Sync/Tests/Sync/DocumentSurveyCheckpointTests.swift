import Foundation
import Testing
@testable import Sync

/// The survey checkpoint must never be taken for the corpus, because that failure looks like
/// success. ``FilingSurvey/surveyedRegion(corpus:memory:)`` comes from the corpus and
/// ``FilingSurvey/documentsToRead(tree:corpus:memory:)`` scopes on it, so a half-finished corpus
/// makes the next survey skip the unread rest of the tree forever, reporting *0 documents read*,
/// with no error or log line. So these assert a file is not seen, and that two files in one
/// directory are never taken for each other.
@Suite struct DocumentSurveyCheckpointTests {

    private func makeDir() throws -> URL { try makeProfilesDir(prefix: "survey-checkpoint", id: "t") }

    private func sample(profileId: String = "t", rootPath: String = "/tmp/tree",
                        salt: String = "abcd", nextIndex: Int = 2) -> DocumentSurveyCheckpoint {
        DocumentSurveyCheckpoint(
            profileId: profileId, rootPath: rootPath, salt: salt,
            plan: ["a.pdf", "b.pdf", "c.pdf", "d.pdf"],
            nextIndex: nextIndex,
            read: ["a.pdf": FilingCorpusDocument(size: 10, modified: 20,
                                                 anchors: ["chase", "statement"], idHashes: ["ff00"]),
                   "b.pdf": FilingCorpusDocument(size: 30, modified: 40, anchors: [], idHashes: [])],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_003_600))
    }

    // MARK: - The invariant

    /// The core invariant: a checkpoint on disk is invisible to the corpus reader. Not an empty
    /// corpus, not a partial one: absent.
    @Test func aCheckpointOnDiskIsNotACorpus() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try DocumentSurveyCheckpointStore.write(sample(), id: "t", in: dir)

        #expect(FileManager.default.fileExists(
            atPath: DocumentSurveyCheckpointStore.url(id: "t", in: dir).path),
                "the fixture did not land — everything below would be vacuously true")
        #expect(FilingSurveyStore.corpus(id: "t", in: dir) == nil)
        guard case .absent = FilingSurveyStore.corpusRead(id: "t", in: dir) else {
            Issue.record("""
                a survey checkpoint was read as a corpus — the surveyed region would then cover \
                only what has been read, and the rest of the tree would be skipped on every \
                future survey
                """)
            return
        }
    }

    /// The two files are in the same directory and must not share a path.
    @Test func theTwoFilesDoNotShareAPath() {
        let dir = URL(fileURLWithPath: "/tmp/profiles")
        let checkpoint = DocumentSurveyCheckpointStore.url(id: "t", in: dir)
        #expect(checkpoint != FilingSurveyStore.corpusURL(id: "t", in: dir))
        #expect(checkpoint != FilingSurveyStore.memoryURL(id: "t", in: dir))
        #expect(checkpoint.lastPathComponent == "survey-progress.json")
        // The name is part of the guard, not only the path: a `corpus*` glob in a backup script or
        // a support instruction to "delete the corpus files" must not reach this.
        #expect(!checkpoint.lastPathComponent.contains("corpus"))
    }

    /// `FilingCorpus`'s decoder is lenient by design, so without the `kind` guard a checkpoint that
    /// lands at the corpus path (a recovery script, a hand copy, a refactor reusing `corpusURL`)
    /// would decode as an empty `.loaded` corpus. The survey's byte-preserving refusal wouldn't
    /// run, and the next write would replace the memory with nothing.
    @Test func aCheckpointCOPIEDToTheCorpusPathIsUnreadableNotEmpty() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try DocumentSurveyCheckpointStore.write(sample(), id: "t", in: dir)
        try FileManager.default.copyItem(at: DocumentSurveyCheckpointStore.url(id: "t", in: dir),
                                         to: FilingSurveyStore.corpusURL(id: "t", in: dir))

        guard case .unreadable = FilingSurveyStore.corpusRead(id: "t", in: dir) else {
            Issue.record("""
                survey progress at the corpus path did not read as unreadable. An empty `.loaded` \
                corpus is merged into and written over filing-memory.json, which discards every \
                learned folder and moves the fingerprint every cached verdict is keyed on.
                """)
            return
        }
    }

    /// And the guard is not a ban on the key: a real corpus still round-trips.
    @Test func aRealCorpusStillLoads() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let corpus = FilingCorpus(profileId: "t", salt: "abcd",
                                  documents: ["x.pdf": FilingCorpusDocument(
                                      size: 1, modified: 2, anchors: ["kaiser"], idHashes: [])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(corpus).write(to: FilingSurveyStore.corpusURL(id: "t", in: dir))

        guard case .loaded(let back) = FilingSurveyStore.corpusRead(id: "t", in: dir) else {
            Issue.record("a corpus this build wrote no longer reads back — the kind guard is a ban")
            return
        }
        #expect(back.documents["x.pdf"]?.anchors == ["kaiser"])
    }

    /// A corpus with no `kind` (the offline builder's output, and older corpora on disk) still
    /// loads. The guard fires on a `kind` that names something else, never on its absence.
    @Test func aCorpusPredatingTheKindKeyStillLoads() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(#"{"profileId":"t","salt":"abcd","documents":{"x.pdf":{"s":1,"m":2,"a":["kaiser"]}}}"#.utf8)
            .write(to: FilingSurveyStore.corpusURL(id: "t", in: dir))

        guard case .loaded(let back) = FilingSurveyStore.corpusRead(id: "t", in: dir) else {
            Issue.record("a corpus with no `kind` no longer loads — every corpus on disk today has none")
            return
        }
        #expect(back.documents["x.pdf"]?.anchors == ["kaiser"])
    }

    // MARK: - Round trip

    @Test func itRoundTripsThroughDisk() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = sample()
        try DocumentSurveyCheckpointStore.write(original, id: "t", in: dir)

        guard case .loaded(let back) = DocumentSurveyCheckpointStore.read(id: "t", in: dir) else {
            Issue.record("the checkpoint did not read back")
            return
        }
        #expect(back.profileId == original.profileId)
        #expect(back.rootPath == original.rootPath)
        #expect(back.salt == original.salt)
        #expect(back.plan == original.plan)
        #expect(back.nextIndex == original.nextIndex)
        #expect(back.read == original.read)
        // The stamps go through `FilingArtifactStamp`, which keeps whole seconds, so compare at
        // that resolution.
        #expect(abs(back.startedAt.timeIntervalSince(original.startedAt)) < 1)
        #expect(abs(back.updatedAt.timeIntervalSince(original.updatedAt)) < 1)
    }

    @Test func anAbsentCheckpointIsAbsent() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .absent = DocumentSurveyCheckpointStore.read(id: "t", in: dir) else {
            Issue.record("no checkpoint was written and one was reported")
            return
        }
    }

    @Test func aCorruptCheckpointIsUnreadableNotAbsent() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ this is not json".utf8)
            .write(to: DocumentSurveyCheckpointStore.url(id: "t", in: dir))
        guard case .unreadable = DocumentSurveyCheckpointStore.read(id: "t", in: dir) else {
            Issue.record("""
                unparseable progress read as absent — a caller would restart a survey that a \
                fixed file would have resumed
                """)
            return
        }
    }

    /// A corpus that arrives at the *checkpoint's* path is refused too. The guard is symmetric on
    /// purpose: `kind` is required here, so a document that does not say it is progress is not.
    @Test func aCorpusAtTheCheckpointPathIsRefused() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let corpus = FilingCorpus(profileId: "t", salt: "abcd")
        try JSONEncoder().encode(corpus)
            .write(to: DocumentSurveyCheckpointStore.url(id: "t", in: dir))

        guard case .unreadable = DocumentSurveyCheckpointStore.read(id: "t", in: dir) else {
            Issue.record("""
                a corpus read as survey progress — a resume would then walk an empty plan and \
                report a finished survey that never ran
                """)
            return
        }
    }

    @Test func aForeignSchemaIsDiscarded() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"kind":"survey-progress","schemaVersion":99,"profileId":"t","rootPath":"/r","salt":"ab"}"#.utf8)
            .write(to: DocumentSurveyCheckpointStore.url(id: "t", in: dir))
        guard case .unreadable = DocumentSurveyCheckpointStore.read(id: "t", in: dir) else {
            Issue.record("a checkpoint from a future schema was half-read")
            return
        }
    }

    // MARK: - Resuming

    @Test func itResumesOnlyTheRunItDescribes() {
        let c = sample()
        #expect(c.resumes(profileId: "t", rootPath: "/tmp/tree", salt: "abcd"))
        #expect(!c.resumes(profileId: "other", rootPath: "/tmp/tree", salt: "abcd"))
        #expect(!c.resumes(profileId: "t", rootPath: "/tmp/elsewhere", salt: "abcd"))
        // The salt is the one that would fail silently: hashes from two salts never match, so a
        // resumed run would contribute id hashes nothing can ever look up.
        #expect(!c.resumes(profileId: "t", rootPath: "/tmp/tree", salt: "dcba"))
    }

    @Test func remainingIsWhatHasNotBeenLookedAt() {
        #expect(Array(sample(nextIndex: 2).remaining) == ["c.pdf", "d.pdf"])
        #expect(Array(sample(nextIndex: 0).remaining) == ["a.pdf", "b.pdf", "c.pdf", "d.pdf"])
        #expect(Array(sample(nextIndex: 4).remaining).isEmpty)
    }

    /// The file is on disk and can be hand-edited, so an index past the end must mean "nothing
    /// left" rather than trapping on the slice — a crash on resume is a worse answer than a survey
    /// that thinks it is done.
    @Test func anOutOfRangeIndexDoesNotTrap() {
        #expect(Array(sample(nextIndex: 99).remaining).isEmpty)
        #expect(Array(sample(nextIndex: -1).remaining).count == 4)
        #expect(sample(nextIndex: 99).progress == (4, 4))
        #expect(sample(nextIndex: -1).progress == (0, 4))
    }

    @Test func progressCountsAgainstThePlan() {
        #expect(sample(nextIndex: 2).progress == (2, 4))
    }

    // MARK: - Discarding

    @Test func discardingRemovesItAndToleratesItBeingGone() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try DocumentSurveyCheckpointStore.write(sample(), id: "t", in: dir)
        try DocumentSurveyCheckpointStore.discard(id: "t", in: dir)
        guard case .absent = DocumentSurveyCheckpointStore.read(id: "t", in: dir) else {
            Issue.record("the checkpoint survived being discarded")
            return
        }
        // Twice: a caller that just finished a long survey must not get an error because the
        // checkpoint was already gone.
        try DocumentSurveyCheckpointStore.discard(id: "t", in: dir)
    }

    /// Discarding the checkpoint must not touch the artifacts beside it.
    @Test func discardingLeavesTheCorpusAlone() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let corpus = FilingCorpus(profileId: "t", salt: "abcd",
                                  documents: ["x.pdf": FilingCorpusDocument(
                                      size: 1, modified: 2, anchors: ["kaiser"], idHashes: [])])
        try JSONEncoder().encode(corpus).write(to: FilingSurveyStore.corpusURL(id: "t", in: dir))
        try DocumentSurveyCheckpointStore.write(sample(), id: "t", in: dir)

        try DocumentSurveyCheckpointStore.discard(id: "t", in: dir)

        #expect(FilingSurveyStore.corpus(id: "t", in: dir)?.documents["x.pdf"]?.anchors == ["kaiser"])
    }
}
