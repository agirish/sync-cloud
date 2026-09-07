import Foundation
import Testing
@testable import Sync

/// The one place in the app that writes a filing artifact, tested as a store: what it does with an
/// absent file, an unreadable one, and — the rule with real money behind it — an unchanged memory.
///
/// ``FilingResurveyTests`` drives this through a whole re-survey and asserts the resulting bytes.
/// This asks the store its own questions directly, which is what makes a decode failure or a
/// spurious memory rewrite fail *here*, naming the store, rather than somewhere downstream.
@Suite struct FilingSurveyStoreTests {

    static func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FilingSurveyStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func corpus(documents: [String: FilingCorpusDocument] = [:]) -> FilingCorpus {
        FilingCorpus(profileId: "p1", salt: "s", documents: documents)
    }

    static let document = FilingCorpusDocument(size: 10, modified: 1_700_000_000,
                                               anchors: ["passport"], idHashes: ["ab12"])

    static func memory(folders: [String: FilingMemoryEntry]) -> FilingMemory {
        FilingMemory(profileId: "p1", salt: "s", folders: folders)
    }

    static func entry(docs: Int, token: String) -> FilingMemoryEntry {
        FilingMemoryEntry(docs: docs, anchors: [FilingMemoryToken(token: token, weight: 1)],
                          idHashes: [], folderModified: nil)
    }

    // MARK: - Reading

    /// Absent is a state, not a failure: the next survey reads every document instead of the
    /// changed ones. Slow and correct.
    @Test func anAbsentCorpusReadsAsNil() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FilingSurveyStore.corpus(id: "p1", in: dir) == nil)
    }

    /// **The case that must not throw.** A corpus that fails to decode is a survey that happened —
    /// the tree *has* been read — and the store's contract is to report nil and let the next survey
    /// do the work again, not to take the caller down with it.
    @Test func anUndecodableCorpusReadsAsNilRatherThanThrowing() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FilingSurveyStore.corpusURL(id: "p1", in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: url)

        #expect(FilingSurveyStore.corpus(id: "p1", in: dir) == nil)
    }

    static func writeCorpusFile(_ json: String, id: String = "p1", in dir: URL) throws {
        let url = FilingSurveyStore.corpusURL(id: id, in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    /// **A corpus written by another schema is discarded, not half-read** — the stated rule, and
    /// the one that costs only a re-survey when it fires.
    @Test func aCorpusFromAnotherSchemaReadsAsNil() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeCorpusFile(#"{"schemaVersion": 99, "profileId": "p1", "documents": {}}"#, in: dir)

        #expect(FilingSurveyStore.corpus(id: "p1", in: dir) == nil)
    }

    /// The neighbouring case, pinned because it is **not** the one above and reads very like it: a
    /// file with no `schemaVersion` at all is treated as a partial one and decodes to defaults —
    /// an *empty* corpus, not nil. Harmless where it matters (an empty corpus re-reads every
    /// document, exactly as an absent one does), but the two are different values and a caller
    /// that switches on nil sees only one of them.
    @Test func aVersionlessCorpusDecodesToAnEmptyOneRatherThanNil() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeCorpusFile(#"{"somethingElse": 3}"#, in: dir)

        let read = try #require(FilingSurveyStore.corpus(id: "p1", in: dir),
                                "a versionless file now reads as nil — the schema rule changed")
        #expect(read.isEmpty)
        #expect(read.documents.isEmpty)
    }

    /// Round-trip through the real files, including a document's fields — a write this store made
    /// is one it can read.
    @Test func aWrittenCorpusReadsBackWhole() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let written = Self.corpus(documents: ["Family/Granny/Passport.pdf": Self.document])
        let noon = Date(timeIntervalSince1970: 1_755_000_000)

        try FilingSurveyStore.write(corpus: written, memory: Self.memory(folders: [:]),
                                    previousMemory: nil, id: "p1", in: dir, root: "~/Documents",
                                    now: noon)

        let read = try #require(FilingSurveyStore.corpus(id: "p1", in: dir))
        // The stamp is the one field the store sets for you (§4.1) — everything else round-trips.
        var expected = written
        expected.surveyedAt = noon
        #expect(read == expected)
        let doc = try #require(read.documents["Family/Granny/Passport.pdf"])
        #expect(doc.anchors == ["passport"])
        #expect(doc.idHashes == ["ab12"])
        #expect(doc.size == 10)
    }

    /// Two profiles do not read each other's corpus — the id really is part of the path.
    @Test func corporaAreKeyedByProfileId() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FilingSurveyStore.write(corpus: Self.corpus(documents: ["a.pdf": Self.document]),
                                    memory: Self.memory(folders: [:]), previousMemory: nil,
                                    id: "p1", in: dir, root: "~")

        #expect(FilingSurveyStore.corpus(id: "p1", in: dir) != nil)
        #expect(FilingSurveyStore.corpus(id: "p2", in: dir) == nil)
    }

    // MARK: - The rule with money behind it

    /// **An unchanged memory must not be rewritten.** Its bytes are hashed into the profile
    /// fingerprint that keys every cached classification, so a rewrite with a fresh `generated`
    /// stamp throws away every cached verdict — a full paid re-classification — to record that
    /// nothing happened.
    ///
    /// Asserted on the file's modification date as well as the return value, because the return
    /// value alone would still be `false` if the write had happened and the flag were simply wrong.
    @Test func anUnchangedMemoryIsNotRewritten() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = Self.memory(folders: ["Family/Granny": Self.entry(docs: 3, token: "passport")])

        let first = try FilingSurveyStore.write(corpus: Self.corpus(), memory: memory,
                                                previousMemory: nil, id: "p1", in: dir, root: "~")
        #expect(first, "the first write should report that it wrote the memory")

        let url = FilingSurveyStore.memoryURL(id: "p1", in: dir)
        let stampBefore = try #require(try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        // A distinct-but-equal value: equality decides this, not identity.
        let same = Self.memory(folders: ["Family/Granny": Self.entry(docs: 3, token: "passport")])

        let second = try FilingSurveyStore.write(corpus: Self.corpus(), memory: same,
                                                 previousMemory: memory, id: "p1", in: dir,
                                                 root: "~", now: Date().addingTimeInterval(3600))

        #expect(!second, "reported writing a memory that had not changed")
        let stampAfter = try #require(try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        #expect(stampAfter == stampBefore, "rewrote an unchanged memory — every cached verdict is now void")
    }

    /// The other direction, so the guard above is not simply "never writes". A memory that differs
    /// is written, and the file changes.
    @Test func aChangedMemoryIsWritten() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Self.memory(folders: ["Family/Granny": Self.entry(docs: 3, token: "passport")])
        try FilingSurveyStore.write(corpus: Self.corpus(), memory: first, previousMemory: nil,
                                    id: "p1", in: dir, root: "~")

        let changed = Self.memory(folders: ["Family/Granny": Self.entry(docs: 4, token: "passport")])
        let wrote = try FilingSurveyStore.write(corpus: Self.corpus(), memory: changed,
                                                previousMemory: first, id: "p1", in: dir, root: "~")

        #expect(wrote)
        let data = try Data(contentsOf: FilingSurveyStore.memoryURL(id: "p1", in: dir))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let folders = try #require(object["folders"] as? [String: Any])
        #expect(folders.count == 1)
        #expect(object["folderCount"] as? Int == 1)
    }

    /// **The corpus is written even when the memory is not.** The early return that protects the
    /// memory sits *after* the corpus write, and a refactor moving it up would quietly stop
    /// recording which documents were read — the thing that makes the next survey incremental.
    @Test func theCorpusIsWrittenEvenWhenTheMemoryIsUnchanged() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = Self.memory(folders: ["Family/Granny": Self.entry(docs: 3, token: "passport")])
        try FilingSurveyStore.write(corpus: Self.corpus(), memory: memory, previousMemory: nil,
                                    id: "p1", in: dir, root: "~")

        let grown = Self.corpus(documents: ["Family/Granny/Passport.pdf": Self.document])
        let wrote = try FilingSurveyStore.write(corpus: grown, memory: memory,
                                                previousMemory: memory, id: "p1", in: dir, root: "~")

        #expect(!wrote, "this fixture is about the memory standing still")
        #expect(FilingSurveyStore.corpus(id: "p1", in: dir)?.documents.count == 1,
                "the corpus was not written, so the next survey re-reads every document")
    }

    // MARK: - The surveyed-at stamp (§4.1)

    /// **The pair that pulls both ways** (ROADMAP_V5 §4.1): a survey that changes nothing must
    /// still move the stamp — it answers "when did we last LOOK" — and must not move the
    /// fingerprint, because the fingerprint keys every cached verdict and the stamp lives on the
    /// corpus precisely so the two can move independently.
    @Test func theStampMovesWhenASurveyChangesNothingAndTheFingerprintDoesNot() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = Self.memory(folders: ["Family/Granny": Self.entry(docs: 3, token: "passport")])
        let first = Date(timeIntervalSince1970: 1_755_000_000)
        try FilingSurveyStore.write(corpus: Self.corpus(), memory: memory, previousMemory: nil,
                                    id: "p1", in: dir, root: "~", now: first)
        let fingerprintBefore = FilingProfileStore.fingerprint(id: "p1", in: dir)

        let later = first.addingTimeInterval(86_400)
        try FilingSurveyStore.write(corpus: Self.corpus(), memory: memory, previousMemory: memory,
                                    id: "p1", in: dir, root: "~", now: later)

        #expect(FilingSurveyStore.surveyedAt(id: "p1", in: dir) == later,
                "an unchanged survey must still say when it looked")
        #expect(FilingProfileStore.fingerprint(id: "p1", in: dir) == fingerprintBefore,
                "the stamp moved the fingerprint — every cached verdict is now void for nothing")
    }

    /// The stamp survives the trip through the shared artifact format — whole seconds, which is
    /// that format's stated resolution — and an absent or pre-§4.1 corpus answers nil.
    @Test func theStampRoundTripsAndPredatingCorporaAnswerNil() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FilingSurveyStore.surveyedAt(id: "p1", in: dir) == nil, "absent file")

        // A corpus written before the stamp existed — decodes, and the stamp is honestly unknown.
        try Self.writeCorpusFile(#"{"schemaVersion": 1, "profileId": "p1", "salt": "s"}"#, in: dir)
        #expect(FilingSurveyStore.surveyedAt(id: "p1", in: dir) == nil, "pre-stamp corpus")
        #expect(FilingSurveyStore.corpus(id: "p1", in: dir)?.surveyedAt == nil)

        let noon = Date(timeIntervalSince1970: 1_755_000_000)
        try FilingSurveyStore.write(corpus: Self.corpus(),
                                    memory: Self.memory(folders: [:]), previousMemory: nil,
                                    id: "p1", in: dir, root: "~", now: noon)
        #expect(FilingSurveyStore.surveyedAt(id: "p1", in: dir) == noon)
        #expect(FilingSurveyStore.corpus(id: "p1", in: dir)?.surveyedAt == noon,
                "the full decode and the stamp-only read must agree")
    }

    /// The header a person opening this file by hand needs. It is not decoration — these artifacts
    /// get read when a suggestion looks wrong.
    @Test func theMemoryFileSaysWhatItIsAndWhatItSampled() throws {
        let dir = try Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = Self.corpus(documents: [
            "a.pdf": Self.document,
            // Blank documents are not "source documents" — nothing was learned from them.
            "b.pdf": FilingCorpusDocument(size: 1, modified: 1, anchors: [], idHashes: []),
        ])

        try FilingSurveyStore.write(corpus: corpus,
                                    memory: Self.memory(folders: ["F": Self.entry(docs: 1, token: "t")]),
                                    previousMemory: nil, id: "p1", in: dir, root: "~/Documents")

        let data = try Data(contentsOf: FilingSurveyStore.memoryURL(id: "p1", in: dir))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["profileId"] as? String == "p1")
        #expect(object["root"] as? String == "~/Documents")
        #expect(object["portable"] as? Bool == false)
        #expect(object["sourceDocuments"] as? Int == 1, "counted a blank document as a source")
        #expect(object["salt"] as? String == "s")
        #expect((object["generated"] as? String)?.isEmpty == false)
        #expect((object["note"] as? String)?.isEmpty == false)
    }
}
