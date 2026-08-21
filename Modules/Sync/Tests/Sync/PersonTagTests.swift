import Testing
import Foundation
@testable import Sync

/// `person-tags.json` — the file, its forward compatibility, and the store that writes it.
///
/// **Pinned against literal JSON, not against a round-trip through this build's own encoder.** A
/// round-trip test passes just as happily when both halves are wrong together, which is precisely
/// the failure that matters for a file another build has to read.
@Suite struct PersonTagTests {

    // MARK: - The file, as bytes

    /// The exact shape written today. A change to any of these key names is a change to a file
    /// other builds read, and has to be a deliberate one.
    static let literal = """
        {
          "schemaVersion": 1,
          "tags": [
            {
              "at": "Shared/Inbox/Scan 2026-03-14.pdf",
              "fingerprint": "pdf-text-1:9f2c",
              "person": "aditi",
              "verdict": "confirmed"
            },
            {
              "path": "Financial/Abhishek - Family insurance card.pdf",
              "person": "shweta",
              "verdict": "rejected"
            }
          ]
        }
        """

    @Test func decodesTheFileAsWritten() throws {
        let file = try JSONDecoder().decode(PersonTagFile.self,
                                            from: Data(Self.literal.utf8))
        #expect(file.tags.count == 2)
        let aditi = try #require(file.tags.first { $0.personId == "aditi" })
        #expect(aditi.key == .fingerprint("pdf-text-1:9f2c"))
        #expect(aditi.verdict == .confirmed)
        #expect(aditi.recordedPath == "Shared/Inbox/Scan 2026-03-14.pdf")
        let shweta = try #require(file.tags.first { $0.personId == "shweta" })
        #expect(shweta.key == .path("Financial/Abhishek - Family insurance card.pdf"))
        #expect(shweta.verdict == .rejected)
        // A path-keyed tag names its file in the key, so it needs no separate `at` to be readable.
        #expect(shweta.recordedPath == "Financial/Abhishek - Family insurance card.pdf")
    }

    /// What this build writes is what this build reads — asserted against the literal above rather
    /// than against itself.
    @Test func writesTheFileTheSameWayItReadsIt() throws {
        let decoded = try JSONDecoder().decode(PersonTagFile.self, from: Data(Self.literal.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(decoded)
        let text = String(decoding: data, as: UTF8.self)
        for fragment in ["\"person\" : \"aditi\"", "\"verdict\" : \"confirmed\"",
                         "\"fingerprint\" : \"pdf-text-1:9f2c\"",
                         "\"path\" : \"Financial/Abhishek - Family insurance card.pdf\"",
                         "\"schemaVersion\" : 1"] {
            #expect(text.contains(fragment), "missing \(fragment) in\n\(text)")
        }
    }

    // MARK: - The failure this file is shaped to avoid

    /// **A verdict this build has never heard of costs that tag and nothing else.**
    ///
    /// This is the `personIs` data-loss bug asked in a different place: rule conditions were one
    /// blob with a synthesized decoder, so meeting one unknown case threw on the whole array and
    /// silently wiped every rule the user had. Here the container decodes tag by tag, so a future
    /// `"maybe"` is skipped and the two verdicts either side of it survive.
    @Test func oneUnknownVerdictDoesNotTakeTheFileWithIt() throws {
        let fromTheFuture = """
            {
              "schemaVersion": 1,
              "tags": [
                { "path": "a.pdf", "person": "aditi", "verdict": "confirmed" },
                { "path": "b.pdf", "person": "aditi", "verdict": "maybe", "confidence": 0.4 },
                { "path": "c.pdf", "person": "divit", "verdict": "rejected" }
              ]
            }
            """
        let file = try JSONDecoder().decode(PersonTagFile.self, from: Data(fromTheFuture.utf8))
        #expect(file.tags.count == 3, "an unknown verdict must not cost the tags around it")
        #expect(file.tags.map(\.personId) == ["aditi", "aditi", "divit"])
        #expect(file.tags[1].verdict == .unrecognized("maybe"))
        #expect(file.tags[1].verdict.isActionable == false,
                "an unknown verdict must never be acted on — guessing it means yes is a wrong answer")
    }

    /// A structurally broken tag — one naming no document at all — costs itself, and the loop still
    /// advances past it rather than stopping there.
    @Test func aMalformedTagCostsOnlyItself() throws {
        let broken = """
            {
              "tags": [
                { "person": "aditi", "verdict": "confirmed" },
                { "path": "b.pdf", "person": "divit", "verdict": "confirmed" },
                "not even an object",
                { "path": "c.pdf", "person": "muktha", "verdict": "rejected" }
              ]
            }
            """
        let file = try JSONDecoder().decode(PersonTagFile.self, from: Data(broken.utf8))
        #expect(file.tags.map(\.personId) == ["divit", "muktha"],
                "the two readable tags after the broken ones must survive")
    }

    /// **An entry this build cannot read is a judgement, not litter.**
    ///
    /// The test above proves the two readable tags survive a broken neighbour. It says nothing
    /// about the neighbour — which was swallowed by an ignore-wrapper, uncounted and unlogged, and
    /// then deleted by the next save. Forty verdicts could go that way with nothing on screen and
    /// nothing in the log.
    @Test func anEntryThisBuildCannotReadIsKept() throws {
        let broken = """
            {
              "tags": [
                { "path": "b.pdf", "person": "divit", "verdict": "confirmed" },
                "not even an object",
                { "person": "aditi", "verdict": "confirmed" }
              ]
            }
            """
        let file = try JSONDecoder().decode(PersonTagFile.self, from: Data(broken.utf8))
        #expect(file.tags.map(\.personId) == ["divit"])
        // The string AND the object with neither key — both unreadable, both kept.
        #expect(file.unreadable.count == 2, "an unreadable entry was dropped; got \(file.unreadable)")
        #expect(file.unreadable.contains(.string("not even an object")))
    }

    /// And the save that would have destroyed them puts them back.
    @MainActor @Test func anUnreadableEntrySurvivesTheNextVerdict() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("person-tags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profileDir = dir.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let url = profileDir.appendingPathComponent("person-tags.json")
        try Data("""
            {
              "schemaVersion": 7,
              "tags": [
                { "at": "b.pdf", "person": "aditi", "verdict": "confirmed", "shape": "from-the-future" }
              ]
            }
            """.utf8).write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        #expect(store.tags.isEmpty, "the entry has no key this build understands")

        // Any write rewrites the whole file — the moment the entry would be lost.
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["divit"])
        #expect(reread.unreadable.count == 1, "the unreadable entry was destroyed by the save")
        // Verbatim: every field it arrived with, including the one this build has no case for.
        if case .object(let o) = reread.unreadable[0] {
            #expect(o["shape"] == .string("from-the-future"))
            #expect(o["person"] == .string("aditi"))
        } else {
            Issue.record("carried entry changed shape: \(reread.unreadable[0])")
        }

        /// **And the version is not stamped down.** A file written under a newer schema, rewritten
        /// by this build as version 1, would be the only thing left claiming the entry it just
        /// carried is v1 shaped.
        #expect(reread.schemaVersion == 7, "a newer schema was relabelled as this build's own")
    }

    /// **Clearing withdraws what recording would have replaced.**
    ///
    /// `record` supersedes across key KINDS at one recorded path — a fingerprint-keyed verdict and
    /// a path-keyed one about the same document are one answer given twice. `clear` matched the
    /// exact key only, so asking it to withdraw the verdict on a document whose tag is stored under
    /// the other kind removed nothing and said nothing: a silent no-op for exactly the documents
    /// the durable key exists for.
    @MainActor @Test func clearingWithdrawsAVerdictStoredUnderTheOtherKindOfKey() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Recorded durably, by fingerprint, at a known path.
        store.record(personId: "aditi", key: .fingerprint("fp-1"), verdict: .confirmed, path: "a.pdf")
        #expect(store.tags.count == 1)

        // The caller has the path — which is all the People queue ever has for a row.
        store.clear(personId: "aditi", key: .path("a.pdf"), path: "a.pdf")
        #expect(store.tags.isEmpty, "the verdict survived a withdrawal aimed at the same document")
    }

    /// And it stays narrow: another person's verdict at the same path is untouched.
    @MainActor @Test func clearingLeavesAnotherPersonsVerdictAlone() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "aditi", key: .fingerprint("fp-1"), verdict: .confirmed, path: "a.pdf")
        store.record(personId: "divit", key: .fingerprint("fp-1"), verdict: .rejected, path: "a.pdf")
        store.clear(personId: "aditi", key: .path("a.pdf"), path: "a.pdf")
        #expect(store.tags.map(\.personId) == ["divit"])
    }

    /// **The verbatim round-trip.** An unrecognized verdict read from a newer build has to go back
    /// to disk exactly as it arrived — a build that quietly rewrote `"maybe"` as `"rejected"`, or
    /// dropped it, would be destroying the newer build's data while looking like it worked.
    @MainActor @Test func anUnknownVerdictIsWrittenBackUntouched() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("person-tags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profileDir = dir.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let url = profileDir.appendingPathComponent("person-tags.json")
        try Data("""
            {
              "schemaVersion": 1,
              "tags": [
                { "at": "b.pdf", "fingerprint": "fp-b", "person": "aditi", "verdict": "maybe" }
              ]
            }
            """.utf8).write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        #expect(store.tags.isEmpty, "an unactionable verdict is carried, not offered as a verdict")
        // Any write at all rewrites the whole file — which is the moment a carried tag would be lost.
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.count == 2, "the carried tag must still be in the file")
        let carried = try #require(reread.tags.first { $0.personId == "aditi" })
        #expect(carried.verdict == .unrecognized("maybe"))
        #expect(carried.key == .fingerprint("fp-b"))
        #expect(carried.recordedPath == "b.pdf")
    }

    // MARK: - The store

    @MainActor
    private func makeStore() throws -> (PersonTagStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("person-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (PersonTagStore(directory: dir, profileId: "p"), dir)
    }

    /// Changing your mind leaves **one** verdict, not two that disagree.
    @MainActor @Test func aSecondVerdictReplacesTheFirst() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "aditi", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")
        store.record(personId: "aditi", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        #expect(store.tags.count == 1)
        #expect(store.tags[0].verdict == .confirmed)
    }

    /// The same document can belong to a verdict for two different people without them colliding.
    @MainActor @Test func verdictsAreKeyedPerPersonAsWellAsPerDocument() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "aditi", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")
        #expect(store.tags.count == 2)
        let index = store.index
        #expect(index.verdict(personId: "aditi", path: "a.pdf") == .confirmed)
        #expect(index.verdict(personId: "divit", path: "a.pdf") == .rejected)
        #expect(index.verdict(personId: "shweta", path: "a.pdf") == nil)
    }

    @MainActor @Test func aVerdictSurvivesReopeningTheStore() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "aditi", key: .fingerprint("fp"), verdict: .rejected, path: "a.pdf")
        let reopened = PersonTagStore(directory: dir, profileId: "p")
        #expect(reopened.index.verdict(personId: "aditi", path: "a.pdf", fingerprint: "fp")
                == .rejected)
    }

    /// Withdrawing puts the document back in front of the channels — the undo for a misclick, and
    /// the only way a row returns to the queue.
    @MainActor @Test func clearingAVerdictPutsTheRowBack() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "aditi", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")
        store.clear(personId: "aditi", key: .path("a.pdf"))
        #expect(store.tags.isEmpty)
        #expect(store.index.verdict(personId: "aditi", path: "a.pdf") == nil)
    }

    // MARK: - Finding a verdict again

    /// **A fingerprint-keyed verdict is findable at the path it was made at.**
    ///
    /// Without this the durable key would be inert in the surface that uses it: a gather walks
    /// paths, nothing computes 10,171 digests to answer "whose is this?", and the persisted
    /// fingerprint index only exists once a duplicates scan has run. The digest is still the key — it is
    /// what survives the file moving — but the recorded path is how the queue finds it before
    /// anything has fingerprinted the tree.
    @Test func aFingerprintKeyedVerdictIsFoundByPathWhenNoDigestIsInHand() {
        let index = PersonTagIndex(tags: [
            PersonTag(personId: "aditi", key: .fingerprint("fp"), verdict: .rejected,
                      recordedPath: "Shared/Inbox/Scan.pdf")
        ])
        #expect(index.verdict(personId: "aditi", path: "Shared/Inbox/Scan.pdf") == .rejected)
        #expect(index.verdict(personId: "aditi", path: "Moved/Scan.pdf", fingerprint: "fp")
                == .rejected,
                "the digest is the durable key — the file moving must not lose the verdict")
        #expect(index.verdict(personId: "aditi", path: "Other/Unrelated.pdf") == nil)
    }

    /// An unrecognized verdict is carried in the file but never answers a question.
    @Test func anUnknownVerdictIsNotAnAnswer() {
        let index = PersonTagIndex(tags: [
            PersonTag(personId: "aditi", key: .path("a.pdf"), verdict: .unrecognized("maybe"),
                      recordedPath: "a.pdf")
        ])
        #expect(index.verdict(personId: "aditi", path: "a.pdf") == nil)
        #expect(index.confirmedPaths(for: "aditi").isEmpty)
    }

    // MARK: One document, one verdict — whichever key each judgement happened to use

    /// **A reversal supersedes the original even when the key changed underneath it.**
    ///
    /// `recordPersonVerdict` picks the key at judgement time: a fingerprint when the PDF can be
    /// read, the path when it cannot. Both are live states for the same file — evicted to iCloud,
    /// or locked — so two judgements of one document can land under different keys, and matching
    /// only on `(personId, key)` stored the second beside the first.
    ///
    /// **This is the ordering that actually went stale.** `PersonFiles.gather` asks
    /// `verdict(personId:path:)` with no fingerprint, so the index consults `.path` FIRST — a
    /// path-keyed tag therefore beats a fingerprint-keyed one, and a path-keyed "yes" followed by
    /// a fingerprint-keyed "no" kept serving the withdrawn confirmation. (The first version of
    /// this test staged the reverse, which that same precedence already answered correctly.)
    @MainActor @Test func aReversalUnderADifferentKeySupersedesTheOriginal() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Judged while the file was evicted, so the key fell back to the path…
        store.record(personId: "aditi", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        // …then judged again once it could be read, so the key is the fingerprint.
        store.record(personId: "aditi", key: .fingerprint("d1"), verdict: .rejected, path: "a.pdf")

        #expect(store.tags.count == 1,
                "two tags for one document: \(store.tags.map { "\($0.key)=\($0.verdict)" })")
        let index = PersonTagIndex(tags: store.tags)
        #expect(index.verdict(personId: "aditi", path: "a.pdf") == .rejected,
                "the withdrawn confirmation still wins the lookup the gather actually makes")
    }

    /// The other ordering, which the lookup precedence already answered — but which still left the
    /// confirmation in `confirmedPaths`, so the `unseenConfirmations` sweep re-listed a document
    /// the user had rejected as "theirs". That is the outcome on screen, and it is what this
    /// asserts rather than the tag count.
    @MainActor @Test func aRejectionAlsoWithdrawsTheDocumentFromTheConfirmedSet() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(personId: "aditi", key: .fingerprint("d1"), verdict: .confirmed, path: "a.pdf")
        #expect(PersonTagIndex(tags: store.tags).confirmedPaths(for: "aditi") == ["a.pdf"],
                "the fixture never confirmed anything")

        store.record(personId: "aditi", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")
        #expect(PersonTagIndex(tags: store.tags).confirmedPaths(for: "aditi").isEmpty,
                "a rejected document is still listed as confirmed, so the gather re-lists it as theirs")
    }

    /// And the other direction, so the sweep is not simply deleting whatever it finds: a verdict on
    /// a **different** document is untouched, and so is another person's on the same one.
    @MainActor @Test func supersedingLeavesOtherDocumentsAndOtherPeopleAlone() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(personId: "aditi", key: .fingerprint("d1"), verdict: .confirmed, path: "a.pdf")
        store.record(personId: "aditi", key: .fingerprint("d2"), verdict: .confirmed, path: "b.pdf")
        store.record(personId: "divit", key: .fingerprint("d3"), verdict: .confirmed, path: "a.pdf")

        store.record(personId: "aditi", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")

        #expect(store.tags.count == 3, "the sweep took a tag it had no business taking")
        let index = PersonTagIndex(tags: store.tags)
        #expect(index.verdict(personId: "aditi", path: "b.pdf") == .confirmed)
        #expect(index.verdict(personId: "divit", path: "a.pdf") == .confirmed)
    }

    /// **Re-answering a document that has since moved takes.**
    ///
    /// The gather looks a fingerprint-keyed tag up by path, so once Organize files the document
    /// the row comes back as an open question — that much is expected, and `keyKind` says so. What
    /// was not expected: pressing the same answer again did nothing at all. `record` computed the
    /// same key, found the tag, saw the same verdict and returned before touching `recordedPath`,
    /// so the row reappeared on every gather afterwards and the button never took.
    @MainActor @Test func reAnsweringAMovedDocumentUpdatesWhereItWasRecorded() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(personId: "aditi", key: .fingerprint("d1"), verdict: .confirmed,
                     path: "Family/Aditi/OCI.pdf")
        // Organize files it; the user answers the re-opened question the same way.
        store.record(personId: "aditi", key: .fingerprint("d1"), verdict: .confirmed,
                     path: "Immigration/OCI/Aditi/OCI.pdf")

        #expect(store.tags.count == 1, "the re-answer appended a second tag")
        let index = PersonTagIndex(tags: store.tags)
        #expect(index.verdict(personId: "aditi", path: "Immigration/OCI/Aditi/OCI.pdf") == .confirmed,
                "the answer did not follow the document to where it now lives")
        #expect(index.confirmedPaths(for: "aditi") == ["Immigration/OCI/Aditi/OCI.pdf"],
                "the confirmed set still names the old path")
    }

    /// And the early return still does its job: re-recording the SAME answer at the SAME path
    /// writes nothing, which is what keeps a gather from rewriting the file on every pass.
    @MainActor @Test func reAnsweringTheSameDocumentIdenticallyIsANoOp() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "aditi", key: .fingerprint("d1"), verdict: .confirmed, path: "a.pdf")
        let before = try #require(try? Data(contentsOf: dir.appendingPathComponent("p/person-tags.json")))
        store.record(personId: "aditi", key: .fingerprint("d1"), verdict: .confirmed, path: "a.pdf")
        let after = try #require(try? Data(contentsOf: dir.appendingPathComponent("p/person-tags.json")))
        #expect(before == after, "an identical re-answer rewrote the file")
    }

    /// **Two fingerprint-keyed tags at one path are two documents, not one answered twice.**
    ///
    /// The supersede sweep matches on `recordedPath`, and a path is re-used: a scanner writes
    /// `Inbox/Scan.pdf` again, Organize files the first one away. Dropping the earlier tag there
    /// would discard a durable record about a document that still exists somewhere else — which is
    /// the opposite of what the fingerprint key is for. Only a cross-kind pair (a path claim and a
    /// fingerprint claim) is one document answered twice.
    @MainActor @Test func twoDocumentsThatOccupiedOnePathKeepTheirOwnVerdicts() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(personId: "aditi", key: .fingerprint("first"), verdict: .confirmed, path: "Inbox/Scan.pdf")
        // A different document now occupies the same path, and is judged the other way.
        store.record(personId: "aditi", key: .fingerprint("second"), verdict: .rejected, path: "Inbox/Scan.pdf")

        #expect(store.tags.count == 2,
                "a second document at the same path discarded the first document's verdict")
        let index = PersonTagIndex(tags: store.tags)
        #expect(index.verdict(personId: "aditi", path: "x", fingerprint: "first") == .confirmed,
                "the earlier document's answer was lost when its old path was re-used")
        #expect(index.verdict(personId: "aditi", path: "x", fingerprint: "second") == .rejected)
    }
}

/// **"Left on disk untouched" has to survive the next verdict, or it is not a promise.**
///
/// `load()` refuses to parse a file that is not JSON at all and says, in a comment and in the log,
/// that it leaves it alone so the user can recover it. That held exactly until the user judged
/// anything: `record` calls `save`, and `save` wrote a fresh file straight over it.
@MainActor
@Suite struct PersonTagCorruptFileTests {

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("person-tags-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        return dir
    }

    @Test func aVerdictDoesNotOverwriteAFileThisBuildCouldNotRead() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let corrupt = Data("{ this is not json — half a write, or a bad merge".utf8)
        try corrupt.write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        #expect(store.tags.isEmpty)

        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        // The bytes are still recoverable — beside the live file, not under it.
        let kept = dir.appendingPathComponent("p/person-tags.json.unreadable")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "the unreadable file was destroyed by the next verdict")
        // ...and the app kept working: the new verdict is on disk and readable.
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["divit"])
    }

    /// The set-aside copy is written once, not re-written on every later save — a second verdict
    /// must not replace the preserved bytes with the working file this build has since produced.
    @Test func theSetAsideCopyIsNotOverwrittenByLaterSaves() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        store.record(personId: "aditi", key: .path("b.pdf"), verdict: .rejected, path: "b.pdf")

        let kept = dir.appendingPathComponent("p/person-tags.json.unreadable")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt)
    }

    // MARK: - A file the process cannot even READ gets the same promise

    /// **The read layer has the same two states as the parse layer, and it lost them.** A file
    /// that exists but cannot be opened — mode 000, an ACL, an I/O error — failed the `try?` read
    /// exactly like no file at all, so `fileWasUnreadable` never armed, and the first verdict's
    /// atomic write (which needs permission on the *directory*, not the file) landed straight on
    /// top of every verdict the user had recorded.
    @Test func aVerdictDoesNotOverwriteAFileTheProcessCannotOpen() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("p/person-tags.json")
        let kept = dir.appendingPathComponent("p/person-tags.json.unreadable")
        let fm = FileManager.default
        defer {
            // Give the bytes back before the sweep, wherever they ended up.
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
            try? fm.removeItem(at: dir)
        }
        // A perfectly good file — real prior verdicts, not corruption. Only the read fails.
        let original = Data(PersonTagTests.literal.utf8)
        try original.write(to: url)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        let store = PersonTagStore(directory: dir, profileId: "p")
        #expect(store.tags.isEmpty)
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        // The set-aside keeps the mode with the bytes; open it up to compare them.
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
        #expect(fm.contents(atPath: kept.path) == original,
                "the verdicts were overwritten because a failed read was mistaken for no file")
        // ...and the app kept working: the new verdict is on disk and readable.
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["divit"])
    }

    /// The same hole through the other door: the store path symlinked somewhere that does not
    /// resolve right now — a volume that is not mounted. The read fails, and the write would
    /// replace the *link itself* with a plain file, orphaning the verdicts it points at.
    @Test func aDanglingSymlinkAtTheStorePathIsSetAsideNotReplaced() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let target = "/Volumes/NoSuchVolume/person-tags.json"
        try FileManager.default.createSymbolicLink(at: url,
                                                   withDestinationURL: URL(fileURLWithPath: target))

        let store = PersonTagStore(directory: dir, profileId: "p")
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        // The link survives, moved aside — still pointing where the user aimed it.
        let kept = dir.appendingPathComponent("p/person-tags.json.unreadable")
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: kept.path)
        #expect(dest == target, "the symlink was destroyed instead of being set aside")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["divit"])
    }

    /// **A failed set-aside must stay armed, or the guard lasts exactly one verdict.** The catch
    /// already refused to write when the move failed — but the flag was cleared *before* the move
    /// was attempted, so the NEXT verdict's save ran unguarded and landed its atomic write on the
    /// user's still-in-place file: the exact loss this suite exists to prevent, one save later.
    @Test func aFailedSetAsideKeepsRefusingUntilTheMoveSucceeds() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let corrupt = Data("{ not json — and the rename is about to fail too".utf8)
        try corrupt.write(to: url)

        let fm = MoveBlockedFileManager()
        fm.movesToRefuse = 2
        let store = PersonTagStore(directory: dir, profileId: "p", fileManager: fm)
        #expect(store.tags.isEmpty)

        // Save 1: the move fails. Nothing may land on the user's file.
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        #expect(FileManager.default.contents(atPath: url.path) == corrupt,
                "a failed set-aside let the write land on the unreadable file")

        // Save 2, the move still failing: the refusal must repeat — this is the observable form
        // of "the flag is still armed". Under the cleared-up-front flag this is the save that
        // overwrote.
        store.record(personId: "aditi", key: .path("b.pdf"), verdict: .rejected, path: "b.pdf")
        #expect(FileManager.default.contents(atPath: url.path) == corrupt,
                "one failed set-aside disarmed the guard, and the next verdict overwrote the file")

        // The obstruction clears: save 3 sets the ORIGINAL bytes aside and writes fresh —
        // carrying every verdict recorded while they could live only in memory.
        store.record(personId: "muktha", key: .path("c.pdf"), verdict: .confirmed, path: "c.pdf")
        let kept = dir.appendingPathComponent("p/person-tags.json.unreadable")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "the set-aside does not hold the user's original bytes")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId).sorted() == ["aditi", "divit", "muktha"],
                "a verdict recorded while the set-aside was failing was lost")
    }

    /// A leftover at the kept path — an earlier session's set-aside — must not block the rescue
    /// forever, and removing it is safe only because the armed flag means nothing has written the
    /// live file yet: what replaces the leftover is still the user's original, and the more
    /// current of the two records.
    @Test func aLeftoverSetAsideFromAnEarlierEpisodeDoesNotBlockTheRescue() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let kept = dir.appendingPathComponent("p/person-tags.json.unreadable")
        try Data("an earlier episode's set-aside".utf8).write(to: kept)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "the leftover blocked the set-aside, or survived in its place")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["divit"])
    }

    /// **A source that vanishes mid-session is the protection arriving by other means, not an
    /// obstruction.** With the guard armed, the user hand-deletes the corrupt file — the set-aside
    /// move then fails source-absent, an error the refusal arm was never meant for: there is
    /// nothing left to protect, so the move can never succeed, and a guard that stays armed
    /// refuses every save for the rest of the session and silently loses every verdict at quit.
    @Test func handDeletingTheCorruptFileMidSessionDoesNotLockOutEverySave() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        try Data("{ not json — and about to be hand-deleted".utf8).write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")   // the guard arms
        try FileManager.default.removeItem(at: url)                  // the user deletes the file

        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["divit"],
                "the save was refused although there was nothing left to set aside")

        // ...and it stays healed: the next save is ordinary, not another refusal.
        store.record(personId: "aditi", key: .path("b.pdf"), verdict: .rejected, path: "b.pdf")
        let again = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(again.tags.map(\.personId).sorted() == ["aditi", "divit"],
                "the guard stayed armed after the source was gone, and the next save was refused")
    }

    /// A first launch has no file, and must stay exactly as quiet and ordinary as it is today:
    /// nothing set aside, nothing protected, the first verdict simply writes the file.
    @Test func aGenuinelyAbsentFileStillWritesNormally() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")

        let store = PersonTagStore(directory: dir, profileId: "p")
        store.record(personId: "divit", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        let kept = dir.appendingPathComponent("p/person-tags.json.unreadable")
        #expect(!FileManager.default.fileExists(atPath: kept.path),
                "an absent file was mistaken for one that exists but cannot be read")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["divit"])
    }
}

/// A `FileManager` whose renames can be made to fail — injected through the seam the store
/// already takes. A real obstruction at the `.unreadable` path is not reliable (an existing file
/// there is exactly what the collision handling clears, and permission games gate on the euid),
/// so the refusal is thrown directly, the one spelling every filesystem shares.
private final class MoveBlockedFileManager: FileManager {
    /// How many more `moveItem` calls fail before the obstruction "clears". `FileManager` is
    /// `Sendable`, which a mutable stored property contradicts; unsafe is honest here because the
    /// store is `@MainActor` and the test drives it there too, so every access is one actor's.
    nonisolated(unsafe) var movesToRefuse = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if movesToRefuse > 0 {
            movesToRefuse -= 1
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
