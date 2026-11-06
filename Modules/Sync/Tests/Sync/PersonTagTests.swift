import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// `person-tags.json`: the file, its forward compatibility, and the store that writes it. Pinned
/// against literal JSON, not a round-trip through this build's encoder, which passes when both
/// halves are wrong together, the failure that matters for a file another build reads.
@Suite struct PersonTagTests {

    // MARK: - The file, as bytes

    /// The exact shape written. Changing a key name changes a file other builds read, so it must
    /// be deliberate.
    static let literal = """
        {
          "schemaVersion": 1,
          "tags": [
            {
              "at": "Shared/Inbox/Scan 2026-03-14.pdf",
              "fingerprint": "pdf-text-1:9f2c",
              "person": "daughter",
              "verdict": "confirmed"
            },
            {
              "path": "Financial/Father - Family insurance card.pdf",
              "person": "mother",
              "verdict": "rejected"
            }
          ]
        }
        """

    @Test func decodesTheFileAsWritten() throws {
        let file = try JSONDecoder().decode(PersonTagFile.self,
                                            from: Data(Self.literal.utf8))
        #expect(file.tags.count == 2)
        let daughter = try #require(file.tags.first { $0.personId == "daughter" })
        #expect(daughter.key == .fingerprint("pdf-text-1:9f2c"))
        #expect(daughter.verdict == .confirmed)
        #expect(daughter.recordedPath == "Shared/Inbox/Scan 2026-03-14.pdf")
        let mother = try #require(file.tags.first { $0.personId == "mother" })
        #expect(mother.key == .path("Financial/Father - Family insurance card.pdf"))
        #expect(mother.verdict == .rejected)
        // A path-keyed tag names its file in the key, so it needs no separate `at` to be readable.
        #expect(mother.recordedPath == "Financial/Father - Family insurance card.pdf")
    }

    /// What this build writes is what it reads, asserted against the literal above rather than
    /// against itself.
    @Test func writesTheFileTheSameWayItReadsIt() throws {
        let decoded = try JSONDecoder().decode(PersonTagFile.self, from: Data(Self.literal.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(decoded)
        let text = String(decoding: data, as: UTF8.self)
        for fragment in ["\"person\" : \"daughter\"", "\"verdict\" : \"confirmed\"",
                         "\"fingerprint\" : \"pdf-text-1:9f2c\"",
                         "\"path\" : \"Financial/Father - Family insurance card.pdf\"",
                         "\"schemaVersion\" : 1"] {
            #expect(text.contains(fragment), "missing \(fragment) in\n\(text)")
        }
    }

    // MARK: - The failure this file is shaped to avoid

    /// A verdict this build has never heard of costs that tag and nothing else. The container
    /// decodes tag by tag, so one unknown case can't throw for the whole array and wipe every
    /// verdict; a future `"maybe"` is carried and the verdicts either side survive.
    @Test func oneUnknownVerdictDoesNotTakeTheFileWithIt() throws {
        let fromTheFuture = """
            {
              "schemaVersion": 1,
              "tags": [
                { "path": "a.pdf", "person": "daughter", "verdict": "confirmed" },
                { "path": "b.pdf", "person": "daughter", "verdict": "maybe", "confidence": 0.4 },
                { "path": "c.pdf", "person": "son", "verdict": "rejected" }
              ]
            }
            """
        let file = try JSONDecoder().decode(PersonTagFile.self, from: Data(fromTheFuture.utf8))
        #expect(file.tags.count == 3, "an unknown verdict must not cost the tags around it")
        #expect(file.tags.map(\.personId) == ["daughter", "daughter", "son"])
        #expect(file.tags[1].verdict == .unrecognized("maybe"))
        #expect(file.tags[1].verdict.isActionable == false,
                "an unknown verdict must never be acted on — guessing it means yes is a wrong answer")
    }

    /// A structurally broken tag, such as one naming no document, costs only itself, and the loop
    /// still advances past it.
    @Test func aMalformedTagCostsOnlyItself() throws {
        let broken = """
            {
              "tags": [
                { "person": "daughter", "verdict": "confirmed" },
                { "path": "b.pdf", "person": "son", "verdict": "confirmed" },
                "not even an object",
                { "path": "c.pdf", "person": "granny", "verdict": "rejected" }
              ]
            }
            """
        let file = try JSONDecoder().decode(PersonTagFile.self, from: Data(broken.utf8))
        #expect(file.tags.map(\.personId) == ["son", "granny"],
                "the two readable tags after the broken ones must survive")
    }

    /// An entry this build can't read is a judgement, not litter: it is kept, not swallowed and
    /// then deleted by the next save with nothing on screen or in the log.
    @Test func anEntryThisBuildCannotReadIsKept() throws {
        let broken = """
            {
              "tags": [
                { "path": "b.pdf", "person": "son", "verdict": "confirmed" },
                "not even an object",
                { "person": "daughter", "verdict": "confirmed" }
              ]
            }
            """
        let file = try JSONDecoder().decode(PersonTagFile.self, from: Data(broken.utf8))
        #expect(file.tags.map(\.personId) == ["son"])
        // The string and the object with neither key: both unreadable, both kept.
        #expect(file.unreadable.count == 2, "an unreadable entry was dropped; got \(file.unreadable)")
        #expect(file.unreadable.contains(.string("not even an object")))
    }

    /// The next save writes them back.
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
                { "at": "b.pdf", "person": "daughter", "verdict": "confirmed", "shape": "from-the-future" }
              ]
            }
            """.utf8).write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        #expect(store.tags.isEmpty, "the entry has no key this build understands")

        // Any write rewrites the whole file: the moment the entry would be lost.
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["son"])
        #expect(reread.unreadable.count == 1, "the unreadable entry was destroyed by the save")
        // Verbatim: every field it arrived with, including the one this build has no case for.
        if case .object(let o) = reread.unreadable[0] {
            #expect(o["shape"] == .string("from-the-future"))
            #expect(o["person"] == .string("daughter"))
        } else {
            Issue.record("carried entry changed shape: \(reread.unreadable[0])")
        }

        /// The version isn't stamped down: rewritten as version 1, a newer schema's file would
        /// claim the entry it carried is v1 shaped.
        #expect(reread.schemaVersion == 7, "a newer schema was relabelled as this build's own")
    }

    /// Clearing withdraws what recording would have replaced. `record` supersedes across key kinds
    /// at one recorded path, since a fingerprint-keyed and a path-keyed verdict on one document are
    /// one answer given twice. Matching the exact key only, `clear` would silently do nothing for
    /// the documents the durable key exists for.
    @MainActor @Test func clearingWithdrawsAVerdictStoredUnderTheOtherKindOfKey() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Recorded durably, by fingerprint, at a known path.
        store.record(personId: "daughter", key: .fingerprint("fp-1"), verdict: .confirmed, path: "a.pdf")
        #expect(store.tags.count == 1)

        // The caller has the path, which is all the People queue ever has for a row.
        store.clear(personId: "daughter", key: .path("a.pdf"), path: "a.pdf")
        #expect(store.tags.isEmpty, "the verdict survived a withdrawal aimed at the same document")
    }

    /// And it stays narrow: another person's verdict at the same path is untouched.
    @MainActor @Test func clearingLeavesAnotherPersonsVerdictAlone() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "daughter", key: .fingerprint("fp-1"), verdict: .confirmed, path: "a.pdf")
        store.record(personId: "son", key: .fingerprint("fp-1"), verdict: .rejected, path: "a.pdf")
        store.clear(personId: "daughter", key: .path("a.pdf"), path: "a.pdf")
        #expect(store.tags.map(\.personId) == ["son"])
    }

    /// An unrecognized verdict from a newer build goes back to disk exactly as it arrived.
    /// Rewriting `"maybe"` as `"rejected"`, or dropping it, would destroy the newer build's data
    /// while looking like it worked.
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
                { "at": "b.pdf", "fingerprint": "fp-b", "person": "daughter", "verdict": "maybe" }
              ]
            }
            """.utf8).write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        #expect(store.tags.isEmpty, "an unactionable verdict is carried, not offered as a verdict")
        // Any write rewrites the whole file: the moment a carried tag would be lost.
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.count == 2, "the carried tag must still be in the file")
        let carried = try #require(reread.tags.first { $0.personId == "daughter" })
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

    /// Changing your mind leaves one verdict, not two that disagree.
    @MainActor @Test func aSecondVerdictReplacesTheFirst() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "daughter", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")
        store.record(personId: "daughter", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        #expect(store.tags.count == 1)
        #expect(store.tags[0].verdict == .confirmed)
    }

    /// The same document can belong to a verdict for two different people without them colliding.
    @MainActor @Test func verdictsAreKeyedPerPersonAsWellAsPerDocument() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "daughter", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        store.record(personId: "son", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")
        #expect(store.tags.count == 2)
        let index = store.index
        #expect(index.verdict(personId: "daughter", path: "a.pdf") == .confirmed)
        #expect(index.verdict(personId: "son", path: "a.pdf") == .rejected)
        #expect(index.verdict(personId: "mother", path: "a.pdf") == nil)
    }

    @MainActor @Test func aVerdictSurvivesReopeningTheStore() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "daughter", key: .fingerprint("fp"), verdict: .rejected, path: "a.pdf")
        let reopened = PersonTagStore(directory: dir, profileId: "p")
        #expect(reopened.index.verdict(personId: "daughter", path: "a.pdf", fingerprint: "fp")
                == .rejected)
    }

    /// Withdrawing puts the document back in front of the channels: the undo for a misclick, and
    /// the only way a row returns to the queue.
    @MainActor @Test func clearingAVerdictPutsTheRowBack() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "daughter", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")
        store.clear(personId: "daughter", key: .path("a.pdf"))
        #expect(store.tags.isEmpty)
        #expect(store.index.verdict(personId: "daughter", path: "a.pdf") == nil)
    }

    // MARK: - Finding a verdict again

    /// A fingerprint-keyed verdict is findable at the path it was made at. A gather walks paths and
    /// computes no digests, and the fingerprint index exists only after a duplicates scan. The
    /// digest is still the key, surviving a move; the recorded path is how the queue finds it
    /// before anything has fingerprinted the tree.
    @Test func aFingerprintKeyedVerdictIsFoundByPathWhenNoDigestIsInHand() {
        let index = PersonTagIndex(tags: [
            PersonTag(personId: "daughter", key: .fingerprint("fp"), verdict: .rejected,
                      recordedPath: "Shared/Inbox/Scan.pdf")
        ])
        #expect(index.verdict(personId: "daughter", path: "Shared/Inbox/Scan.pdf") == .rejected)
        #expect(index.verdict(personId: "daughter", path: "Moved/Scan.pdf", fingerprint: "fp")
                == .rejected,
                "the digest is the durable key — the file moving must not lose the verdict")
        #expect(index.verdict(personId: "daughter", path: "Other/Unrelated.pdf") == nil)
    }

    /// An unrecognized verdict is carried in the file but never answers a question.
    @Test func anUnknownVerdictIsNotAnAnswer() {
        let index = PersonTagIndex(tags: [
            PersonTag(personId: "daughter", key: .path("a.pdf"), verdict: .unrecognized("maybe"),
                      recordedPath: "a.pdf")
        ])
        #expect(index.verdict(personId: "daughter", path: "a.pdf") == nil)
        #expect(index.confirmedPaths(for: "daughter").isEmpty)
    }

    // MARK: One document, one verdict — whichever key each judgement happened to use

    /// A reversal supersedes the original even when the key changed underneath it.
    /// `recordPersonVerdict` keys by fingerprint when the PDF can be read and by path when it can't
    /// (evicted, locked), so one document's two judgements can land under different keys. This
    /// order matters most: `PersonFiles.gather` looks up by path first, so a path-keyed "yes" left
    /// beside a fingerprint-keyed "no" would keep serving the withdrawn confirmation.
    @MainActor @Test func aReversalUnderADifferentKeySupersedesTheOriginal() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Judged while the file was evicted, so the key fell back to the path…
        store.record(personId: "daughter", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        // …then judged again once it could be read, so the key is the fingerprint.
        store.record(personId: "daughter", key: .fingerprint("d1"), verdict: .rejected, path: "a.pdf")

        #expect(store.tags.count == 1,
                "two tags for one document: \(store.tags.map { "\($0.key)=\($0.verdict)" })")
        let index = PersonTagIndex(tags: store.tags)
        #expect(index.verdict(personId: "daughter", path: "a.pdf") == .rejected,
                "the withdrawn confirmation still wins the lookup the gather actually makes")
    }

    /// The other ordering. The lookup precedence answers it, but a confirmation left in
    /// `confirmedPaths` would have the `unseenConfirmations` sweep re-list a rejected document as
    /// "theirs". Asserted on that outcome, not on the tag count.
    @MainActor @Test func aRejectionAlsoWithdrawsTheDocumentFromTheConfirmedSet() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(personId: "daughter", key: .fingerprint("d1"), verdict: .confirmed, path: "a.pdf")
        #expect(PersonTagIndex(tags: store.tags).confirmedPaths(for: "daughter") == ["a.pdf"],
                "the fixture never confirmed anything")

        store.record(personId: "daughter", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")
        #expect(PersonTagIndex(tags: store.tags).confirmedPaths(for: "daughter").isEmpty,
                "a rejected document is still listed as confirmed, so the gather re-lists it as theirs")
    }

    /// The sweep doesn't delete whatever it finds: a verdict on a different document is untouched,
    /// and so is another person's on the same one.
    @MainActor @Test func supersedingLeavesOtherDocumentsAndOtherPeopleAlone() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(personId: "daughter", key: .fingerprint("d1"), verdict: .confirmed, path: "a.pdf")
        store.record(personId: "daughter", key: .fingerprint("d2"), verdict: .confirmed, path: "b.pdf")
        store.record(personId: "son", key: .fingerprint("d3"), verdict: .confirmed, path: "a.pdf")

        store.record(personId: "daughter", key: .path("a.pdf"), verdict: .rejected, path: "a.pdf")

        #expect(store.tags.count == 3, "the sweep took a tag it had no business taking")
        let index = PersonTagIndex(tags: store.tags)
        #expect(index.verdict(personId: "daughter", path: "b.pdf") == .confirmed)
        #expect(index.verdict(personId: "son", path: "a.pdf") == .confirmed)
    }

    /// Re-answering a document that has moved takes. The gather finds a fingerprint-keyed tag by
    /// path, so once Organize files the document the row comes back as an open question (as
    /// `keyKind` says). The same answer must then update `recordedPath`, not return early on an
    /// unchanged verdict, or the row reappears on every gather.
    @MainActor @Test func reAnsweringAMovedDocumentUpdatesWhereItWasRecorded() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(personId: "daughter", key: .fingerprint("d1"), verdict: .confirmed,
                     path: "Family/Daughter/OCI.pdf")
        // Organize files it; the user answers the re-opened question the same way.
        store.record(personId: "daughter", key: .fingerprint("d1"), verdict: .confirmed,
                     path: "Immigration/OCI/Daughter/OCI.pdf")

        #expect(store.tags.count == 1, "the re-answer appended a second tag")
        let index = PersonTagIndex(tags: store.tags)
        #expect(index.verdict(personId: "daughter", path: "Immigration/OCI/Daughter/OCI.pdf") == .confirmed,
                "the answer did not follow the document to where it now lives")
        #expect(index.confirmedPaths(for: "daughter") == ["Immigration/OCI/Daughter/OCI.pdf"],
                "the confirmed set still names the old path")
    }

    /// The early return still does its job: the same answer at the same path writes nothing, so a
    /// gather doesn't rewrite the file on every pass.
    @MainActor @Test func reAnsweringTheSameDocumentIdenticallyIsANoOp() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.record(personId: "daughter", key: .fingerprint("d1"), verdict: .confirmed, path: "a.pdf")
        let before = try #require(try? Data(contentsOf: dir.appendingPathComponent("p/person-tags.json")))
        store.record(personId: "daughter", key: .fingerprint("d1"), verdict: .confirmed, path: "a.pdf")
        let after = try #require(try? Data(contentsOf: dir.appendingPathComponent("p/person-tags.json")))
        #expect(before == after, "an identical re-answer rewrote the file")
    }

    /// Two fingerprint-keyed tags at one path are two documents, not one answered twice. Paths are
    /// re-used (a scanner writes `Inbox/Scan.pdf` again after Organize filed the first), and
    /// dropping the earlier tag would discard a record of a document that still exists. Only a
    /// cross-kind pair at one path is one document answered twice.
    @MainActor @Test func twoDocumentsThatOccupiedOnePathKeepTheirOwnVerdicts() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.record(personId: "daughter", key: .fingerprint("first"), verdict: .confirmed, path: "Inbox/Scan.pdf")
        // A different document now occupies the same path, and is judged the other way.
        store.record(personId: "daughter", key: .fingerprint("second"), verdict: .rejected, path: "Inbox/Scan.pdf")

        #expect(store.tags.count == 2,
                "a second document at the same path discarded the first document's verdict")
        let index = PersonTagIndex(tags: store.tags)
        #expect(index.verdict(personId: "daughter", path: "x", fingerprint: "first") == .confirmed,
                "the earlier document's answer was lost when its old path was re-used")
        #expect(index.verdict(personId: "daughter", path: "x", fingerprint: "second") == .rejected)
    }
}

/// A tags file this build can't read is left for the user to recover, and that must survive the
/// next verdict: `record` calls `save`, which must set the file aside rather than write over it.
@MainActor
@Suite struct PersonTagCorruptFileTests {

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("person-tags-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        return dir
    }

    /// Every set-aside beside the store, sorted by name (``setAsidesBeside(_:)``). The kept name is
    /// unique per episode, so tests discover the files rather than assume one fixed slot.
    private func setAsides(in dir: URL) -> [URL] {
        setAsidesBeside(dir.appendingPathComponent("p/person-tags.json"))
    }

    @Test func aVerdictDoesNotOverwriteAFileThisBuildCouldNotRead() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let corrupt = Data("{ this is not json — half a write, or a bad merge".utf8)
        try corrupt.write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        #expect(store.tags.isEmpty)

        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        // The bytes are still recoverable, beside the live file, not under it.
        let kept = try #require(setAsides(in: dir).first, "no set-aside was written")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "the unreadable file was destroyed by the next verdict")
        // ...and the app kept working: the new verdict is on disk and readable.
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["son"])
    }

    /// The set-aside copy is written once: a later save must not replace the preserved bytes with
    /// the working file this build has since produced.
    @Test func theSetAsideCopyIsNotOverwrittenByLaterSaves() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        store.record(personId: "daughter", key: .path("b.pdf"), verdict: .rejected, path: "b.pdf")

        // One episode, one set-aside: the second save neither rewrites it nor adds another.
        let kept = setAsides(in: dir)
        #expect(kept.count == 1, "one unreadable episode produced \(kept.count) set-aside(s)")
        #expect(kept.first.flatMap { FileManager.default.contents(atPath: $0.path) } == corrupt)
    }

    // MARK: - A file the process cannot even READ gets the same promise

    /// A file that exists but can't be opened (mode 000, an ACL, an I/O error) must arm
    /// `fileWasUnreadable`, not read as no file. The atomic write needs permission only on the
    /// directory, so the first verdict would land on every verdict the user had recorded.
    @Test func aVerdictDoesNotOverwriteAFileTheProcessCannotOpen() throws {
        let dir = try makeDir()
        let url = dir.appendingPathComponent("p/person-tags.json")
        let fm = FileManager.default
        defer {
            // Give the bytes back before the sweep, wherever they ended up.
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            for aside in setAsides(in: dir) {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: aside.path)
            }
            try? fm.removeItem(at: dir)
        }
        // A good file with real prior verdicts, not corruption. Only the read fails.
        let original = Data(PersonTagTests.literal.utf8)
        try original.write(to: url)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        let store = PersonTagStore(directory: dir, profileId: "p")
        #expect(store.tags.isEmpty)
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        // The set-aside keeps the mode with the bytes; open it up to compare them.
        let kept = try #require(setAsides(in: dir).first, "no set-aside was written")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: kept.path)
        #expect(fm.contents(atPath: kept.path) == original,
                "the verdicts were overwritten because a failed read was mistaken for no file")
        // ...and the app kept working: the new verdict is on disk and readable.
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["son"])
    }

    /// The same hole through a symlink: the store path linked to an unmounted volume. The read
    /// fails, and the write would replace the link itself with a plain file, orphaning the verdicts
    /// it points at.
    @Test func aDanglingSymlinkAtTheStorePathIsSetAsideNotReplaced() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let target = "/Volumes/NoSuchVolume/person-tags.json"
        try FileManager.default.createSymbolicLink(at: url,
                                                   withDestinationURL: URL(fileURLWithPath: target))

        let store = PersonTagStore(directory: dir, profileId: "p")
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        // The link survives, moved aside, still pointing where the user aimed it.
        let kept = try #require(setAsides(in: dir).first, "no set-aside was written")
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: kept.path)
        #expect(dest == target, "the symlink was destroyed instead of being set aside")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["son"])
    }

    /// A failed set-aside must stay armed, or the guard lasts exactly one verdict. If the flag were
    /// cleared before the move, the next save would run unguarded and write over the user's
    /// still-in-place file.
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
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        #expect(FileManager.default.contents(atPath: url.path) == corrupt,
                "a failed set-aside let the write land on the unreadable file")

        // Save 2, the move still failing: the refusal must repeat, which is how "the flag is still
        // armed" shows. Must fail if the flag is cleared before the move.
        store.record(personId: "daughter", key: .path("b.pdf"), verdict: .rejected, path: "b.pdf")
        #expect(FileManager.default.contents(atPath: url.path) == corrupt,
                "one failed set-aside disarmed the guard, and the next verdict overwrote the file")

        // The obstruction clears: save 3 sets the original bytes aside and writes fresh, carrying
        // every verdict recorded while they lived only in memory.
        store.record(personId: "granny", key: .path("c.pdf"), verdict: .confirmed, path: "c.pdf")
        let kept = try #require(setAsides(in: dir).first, "no set-aside was written")
        #expect(FileManager.default.contents(atPath: kept.path) == corrupt,
                "the set-aside does not hold the user's original bytes")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId).sorted() == ["daughter", "granny", "son"],
                "a verdict recorded while the set-aside was failing was lost")
    }

    /// A leftover set-aside from an earlier session, including one under the fixed
    /// `person-tags.json.unreadable` name older builds wrote, neither blocks the rescue nor is
    /// destroyed by it: the kept name is unique per episode, so the move lands beside it.
    @Test func aLeftoverSetAsideFromAnEarlierEpisodeNeitherBlocksNorIsDestroyed() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let legacy = dir.appendingPathComponent("p/person-tags.json.unreadable")
        let earlier = Data("an earlier episode's set-aside".utf8)
        try earlier.write(to: legacy)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        #expect(FileManager.default.contents(atPath: legacy.path) == earlier,
                "the earlier episode's set-aside was destroyed by this one")
        let keptBytes = setAsides(in: dir).compactMap { FileManager.default.contents(atPath: $0.path) }
        #expect(keptBytes.contains(corrupt), "the leftover blocked this episode's set-aside")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["son"])
    }

    /// Two episodes composing their kept name from the same second get distinct names. A frozen
    /// date makes this deterministic; the two-episode test only reaches the disambiguator when both
    /// rescues happen to land in one second.
    @Test func sameInstantEpisodesGetDistinctSetAsideNames() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let now = Date(timeIntervalSince1970: 1_766_000_000)

        let first = UnreadableSetAside.destination(for: url, at: now, fileManager: .default)
        #expect(first.lastPathComponent.hasPrefix("person-tags.json.unreadable-"))
        try Data("episode one".utf8).write(to: first)

        let second = UnreadableSetAside.destination(for: url, at: now, fileManager: .default)
        #expect(second != first, "a same-instant episode was aimed at the occupied kept path")
        try Data("episode two".utf8).write(to: second)

        let third = UnreadableSetAside.destination(for: url, at: now, fileManager: .default)
        #expect(third != first && third != second)
    }

    /// The disambiguator terminates whatever the probe answers. It asks `attributesOfItem` for
    /// candidate after candidate until one is absent, so a manager that never says absent would
    /// spin forever. Bounded rather than made to give up: no destination means the caller refuses
    /// its write, and refusing every write over a stat that keeps saying "yes" is the worse failure.
    @Test func theDisambiguatorTerminatesAgainstAProbeThatNeverSaysAbsent() throws {
        final class AlwaysPresent: FileManager, @unchecked Sendable {
            override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
                [.size: NSNumber(value: 0)]
            }
        }
        let url = URL(fileURLWithPath: "/tmp/never-absent/person-tags.json")
        let now = Date(timeIntervalSince1970: 1_766_000_000)

        // No `waitUntil`: the failure is a hang, so the assertion is that control comes back at
        // all. A bounded loop returns in microseconds.
        let dest = UnreadableSetAside.destination(for: url, at: now, fileManager: AlwaysPresent())
        #expect(dest != url, "the set-aside would land on the file it is rescuing")
        #expect(dest.lastPathComponent.hasPrefix("person-tags.json.unreadable-"))
    }

    /// A second unreadable episode must not destroy the first episode's rescue. Episode 1 sets the
    /// original aside and never re-reads it, so the set-aside is the only copy of those verdicts; a
    /// later episode's set-aside is not more current, and must land beside it.
    @Test func aSecondUnreadableEpisodeDoesNotDestroyTheFirstEpisodesRescue() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")

        // Episode 1: an unreadable file, rescued by the first verdict's save.
        let episode1 = Data("{ episode one — the only copy of these bytes".utf8)
        try episode1.write(to: url)
        let store1 = PersonTagStore(directory: dir, profileId: "p")
        store1.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        // Episode 2: the fresh file corrupts too, and a later session rescues again.
        let episode2 = Data("{ episode two — corrupted again".utf8)
        try episode2.write(to: url)
        let store2 = PersonTagStore(directory: dir, profileId: "p")
        store2.record(personId: "daughter", key: .path("b.pdf"), verdict: .rejected, path: "b.pdf")

        let keptBytes = setAsides(in: dir).compactMap { FileManager.default.contents(atPath: $0.path) }
        #expect(keptBytes.contains(episode1),
                "episode 2's set-aside destroyed the only copy of episode 1's rescue")
        #expect(keptBytes.contains(episode2), "episode 2's own bytes were not set aside")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["daughter"])
    }

    /// A failed set-aside move must not have removed anything first. A move that fails (here a
    /// permissions refusal) leaves an earlier set-aside's bytes untouched, whatever name it sits
    /// under. Must fail if a remove-then-move comes back.
    @Test func aMoveThatFailsForAnotherReasonDoesNotCostAnEarlierSetAside() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        let kept = dir.appendingPathComponent("p/person-tags.json.unreadable")
        let earlier = Data("an earlier episode's rescued verdicts".utf8)
        try earlier.write(to: kept)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)

        let fm = MoveBlockedFileManager()
        fm.movesToRefuse = 1
        let store = PersonTagStore(directory: dir, profileId: "p", fileManager: fm)
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        #expect(FileManager.default.contents(atPath: kept.path) == earlier,
                "a move that failed for a reason other than collision cost the earlier set-aside")
        #expect(FileManager.default.contents(atPath: url.path) == corrupt,
                "the refused save landed on the unreadable file anyway")
    }

    /// A source that vanishes mid-session is not an obstruction: with nothing left to protect, the
    /// guard disarms. If the user hand-deletes the corrupt file, the set-aside move fails
    /// source-absent and can never succeed; a guard that stayed armed would refuse every save and
    /// lose every verdict at quit.
    @Test func handDeletingTheCorruptFileMidSessionDoesNotLockOutEverySave() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        try Data("{ not json — and about to be hand-deleted".utf8).write(to: url)

        let store = PersonTagStore(directory: dir, profileId: "p")   // the guard arms
        try FileManager.default.removeItem(at: url)                  // the user deletes the file

        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["son"],
                "the save was refused although there was nothing left to set aside")

        // And it stays healed: the next save is ordinary, not another refusal.
        store.record(personId: "daughter", key: .path("b.pdf"), verdict: .rejected, path: "b.pdf")
        let again = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(again.tags.map(\.personId).sorted() == ["daughter", "son"],
                "the guard stayed armed after the source was gone, and the next save was refused")
    }

    /// The verdict line may only claim what happened. While persistence is refusing (the guard
    /// armed and the set-aside failing), `record`'s "People: X is Y's" line must say NOT saved, or
    /// the log reads like durable records right up to the quit that loses them.
    @Test func aRefusedSaveIsSaidOutLoudInTheVerdictLine() async throws {
        let log = LogCapture()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        try Data("{ not json — and the rename will keep failing".utf8).write(to: url)

        let fm = MoveBlockedFileManager()
        fm.movesToRefuse = 99                                       // persistence never recovers
        let store = PersonTagStore(directory: dir, profileId: "p", fileManager: fm)
        let path = "honesty-\(UUID().uuidString).pdf"
        store.record(personId: "son", key: .path(path), verdict: .confirmed, path: path)

        let entry = try #require(await log.entries.last {
            $0.message.hasPrefix("People: \(path) is son's")
        }, "the verdict line was not logged at all")
        #expect(entry.message.contains("NOT saved"),
                "a refused save logged a success-looking verdict line: \(entry.message)")
        #expect(store.savedRevision == 0, "a refused save bumped the saved-revision signal")
    }

    /// The counterpart: an ordinary landed save keeps the line unqualified.
    @Test func aLandedSaveKeepsTheVerdictLineUnqualified() async throws {
        let log = LogCapture()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PersonTagStore(directory: dir, profileId: "p")
        let path = "honesty-\(UUID().uuidString).pdf"
        store.record(personId: "son", key: .path(path), verdict: .confirmed, path: path)

        let entry = try #require(await log.entries.last {
            $0.message.hasPrefix("People: \(path) is son's")
        })
        #expect(!entry.message.contains("NOT saved"),
                "a landed save was reported as refused: \(entry.message)")
        #expect(store.savedRevision == 1, "a landed save did not bump the saved-revision signal")
    }

    /// A first launch has no file and stays quiet: nothing set aside, nothing protected, and the
    /// first verdict simply writes the file.
    @Test func aGenuinelyAbsentFileStillWritesNormally() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")

        let store = PersonTagStore(directory: dir, profileId: "p")
        store.record(personId: "son", key: .path("a.pdf"), verdict: .confirmed, path: "a.pdf")

        #expect(setAsides(in: dir).isEmpty,
                "an absent file was mistaken for one that exists but cannot be read")
        let reread = try JSONDecoder().decode(PersonTagFile.self, from: try Data(contentsOf: url))
        #expect(reread.tags.map(\.personId) == ["son"])
    }

    /// The same rule for `clear`: a withdrawal is a save like any other, so while the guard is
    /// armed and the set-aside keeps failing it lives only in memory, and its line must say so.
    @Test func aRefusedWithdrawalIsSaidOutLoudInTheLine() async throws {
        let log = LogCapture()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/person-tags.json")
        try Data("{ not json — and the rename will keep failing".utf8).write(to: url)

        let fm = MoveBlockedFileManager()
        fm.movesToRefuse = 99                                       // persistence never recovers
        let store = PersonTagStore(directory: dir, profileId: "p", fileManager: fm)
        let path = "withdrawal-\(UUID().uuidString).pdf"
        store.record(personId: "son", key: .path(path), verdict: .confirmed, path: path)
        store.clear(personId: "son", key: .path(path))
        #expect(store.tags.isEmpty, "the withdrawal did not take effect in memory")

        let entry = try #require(await log.entries.last {
            $0.message.hasPrefix("People: withdrew the verdict on \(path)")
        }, "the withdrawal line was not logged at all")
        #expect(entry.message.contains("NOT saved"),
                "a refused save logged a durable-looking withdrawal: \(entry.message)")
        #expect(store.savedRevision == 0, "a refused save bumped the saved-revision signal")
    }

    /// The counterpart: a withdrawal that reached disk keeps the line unqualified.
    @Test func aLandedWithdrawalKeepsTheLineUnqualified() async throws {
        let log = LogCapture()
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PersonTagStore(directory: dir, profileId: "p")
        let path = "withdrawal-\(UUID().uuidString).pdf"
        store.record(personId: "son", key: .path(path), verdict: .confirmed, path: path)
        store.clear(personId: "son", key: .path(path))

        let entry = try #require(await log.entries.last {
            $0.message.hasPrefix("People: withdrew the verdict on \(path)")
        })
        #expect(!entry.message.contains("NOT saved"),
                "a landed withdrawal was reported as memory-only: \(entry.message)")
        let reread = try JSONDecoder().decode(PersonTagFile.self,
                                              from: try Data(contentsOf: store.fileURL))
        #expect(reread.tags.isEmpty, "the withdrawal did not reach disk")
    }

}
