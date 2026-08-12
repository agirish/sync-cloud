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
    /// fingerprint index only exists once a Tidy scan has run. The digest is still the key — it is
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
}
