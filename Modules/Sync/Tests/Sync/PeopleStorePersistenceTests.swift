import Testing
import Foundation
@testable import Sync

/// What `people.json` keeps when the app writes it back.
///
/// **The file is hand-written as much as it is app-written.** The real roster carries a `_note`
/// explaining why Anuraag is on it, why listing a full name is what makes a shared surname
/// attributable, and why `Abhi` and `Shwe` are recorded as name forms rather than nicknames — all
/// of it prose no survey can regenerate. `PeopleFileOut` writes four keys (the fourth, `order`, only once the list is hand-arranged) and the save is a
/// whole-file atomic replace, so before this the first edit in Settings ▸ People deleted every
/// other key in the file without saying so.
///
/// This suite exists because there were **no persistence tests for this store at all**: the roster
/// is the one filing artifact the app writes, and nothing checked what it wrote.
@MainActor
@Suite struct PeopleStorePersistenceTests {

    private func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("people-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("p"),
                                                withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: String, to dir: URL) throws {
        try Data(json.utf8).write(to: dir.appendingPathComponent("p/people.json"))
    }

    private func read(_ dir: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A file with prose in it, and a key no build has ever modelled.
    private static let handWritten = """
        {
          "schemaVersion": 1,
          "_note": "Anuraag is on this roster because the tree already files for him.",
          "somethingANewerBuildWrote": { "kind": "whatever", "n": 3 },
          "people": [
            { "id": "abhishek", "displayName": "Abhishek", "fullNames": ["Abhishek Girish"] }
          ]
        }
        """

    /// The same hand-editing, one level down: keys written ON a person rather than beside them.
    private static let handWrittenPerPerson = """
        {
          "schemaVersion": 1,
          "people": [
            { "id": "abhishek", "displayName": "Abhishek", "fullNames": ["Abhishek Girish"],
              "nickname": "Abhi", "_why": "the tree files under his full name" },
            { "id": "muktha", "displayName": "Muktha" }
          ]
        }
        """

    // MARK: - The bug

    @Test func anEditKeepsTheNoteAndAnythingElseInTheFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWritten, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Shweta")            // any edit at all rewrites the whole file

        let saved = try read(dir)
        #expect(saved["_note"] as? String
                == "Anuraag is on this roster because the tree already files for him.",
                "the note the user wrote was dropped by an edit made in the app")
        let carried = saved["somethingANewerBuildWrote"] as? [String: Any]
        #expect(carried?["kind"] as? String == "whatever")
        #expect(carried?["n"] as? Int == 3,
                "a key a newer build wrote must survive a round trip through this one")
    }

    /// **Non-vacuity: the edit has to have actually landed.** Everything above would also pass if
    /// `save()` had quietly done nothing and left the original file in place.
    @Test func theEditItselfIsWritten() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWritten, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Shweta")

        let saved = try read(dir)
        let people = try #require(saved["people"] as? [[String: Any]])
        #expect(people.count == 2)
        #expect(Set(people.compactMap { $0["id"] as? String }) == ["abhishek", "shweta"])
        #expect(saved["schemaVersion"] as? Int == FilingProfileStore.currentSchema)
    }

    /// **A carried key can never shadow one the app owns.**
    ///
    /// The keys are captured at load and re-applied at save, so a `people` array captured then
    /// would be the *old* roster — merging it back would silently undo the edit being saved. It
    /// cannot happen, because the modelled keys are excluded when they are captured rather than
    /// when they are written, and this is the test that says so.
    @Test func aStaleRosterInTheFileCannotOverwriteTheEditBeingSaved() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWritten, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.remove(id: "abhishek")

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        #expect(people.isEmpty, "the removal was undone by the file's own earlier contents")
    }

    /// Rejections persist beside the roster, and still do with a note in the file.
    @Test func rejectedNameFormsSurviveAlongsideTheNote() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWritten, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.dismissSuggestion(PersonNameSuggestion(personId: "abhishek", form: "Abhi Girish",
                                                     occurrences: 2, exampleFile: "x.pdf"))
        let saved = try read(dir)
        #expect((saved["notNames"] as? [String])?.isEmpty == false)
        #expect(saved["_note"] != nil, "carrying the note must not cost the app its own keys")
    }

    // MARK: - Nothing to carry

    @Test func aFirstEverSaveWritesACleanFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No people.json at all — the seeded-roster case, where the file appears on first edit.
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        // Genuinely absent must stay indistinguishable from a first launch: no protection, no
        // load-time warning (the init warns exactly when this flag is set), and the save lands.
        #expect(store.rosterIsUnreadable == false,
                "an absent file was mistaken for one that exists but cannot be read")
        store.add(displayName: "Aditi")

        let saved = try read(dir)
        #expect(Set(saved.keys) == ["schemaVersion", "people"],
                "a fresh file should carry nothing but what the app writes: \(saved.keys)")
    }

    /// A file that is not JSON at all costs the carry, never the edit. The roster is what the file
    /// is *for*, and losing a change to it because a comment could not be re-attached would be the
    /// worse trade.
    @Test func anUnreadableFileDoesNotBlockTheSave() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("this is not json {{{", to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Divit")

        let saved = try read(dir)
        #expect((saved["people"] as? [[String: Any]])?.count == 1)
        #expect(store.rosterIsUnreadable == false,
                "bytes that parse as nothing hold no roster to protect — the edit must still land")
    }

    // MARK: - A roster this build cannot decode is never overwritten

    /// **The other half of the carry, and the one that loses the household.** `carriedKeys` keeps
    /// the keys this build does not model; `people` is one it *does*, so when the decode fails the
    /// roster is precisely what a carry cannot save. The load falls back to a folder-name seed, the
    /// list looks ordinary in Settings, and the first edit atomically replaces the real file.
    @Test func aRosterWithOneBadEntryIsNotOverwrittenByAnEdit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Valid JSON, real household, one hand-edit typo: `fullNames` is a string, not an array.
        let broken = """
            {
              "schemaVersion": 1,
              "_note": "why Anuraag is on this roster",
              "people": [
                { "id": "abhishek", "displayName": "Abhishek", "fullNames": "Abhishek Girish" }
              ]
            }
            """
        try write(broken, to: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable, "an undecodable roster must be known to be undecodable")
        store.add(displayName: "Shweta")

        let after = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))
        #expect(after == before, "the household was overwritten by a roster the app guessed")
    }

    /// A file a NEWER build wrote. The schema probe rejects it wholesale — which is right — but that
    /// makes it exactly the shape above: real data, not decodable here, and rewriting it downgrades
    /// the user's roster to whatever this build could guess.
    @Test func aRosterFromANewerSchemaIsNotOverwritten() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("""
            {
              "schemaVersion": 99,
              "people": [{ "id": "abhishek", "displayName": "Abhishek", "somethingNew": true }]
            }
            """, to: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Shweta")

        let after = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))
        #expect(after == before, "a newer build's file was downgraded by this one")
    }

    /// **Non-vacuity, and the direction that would hide a permanent lockout.** If the guard read
    // MARK: - A roster this build REINTERPRETED is never overwritten either

    /// **A repeated id decodes perfectly, and that is exactly why it slipped past the guard above.**
    ///
    /// `rosterIsUnreadable` asks "did this decode", and a person block copy-pasted without changing
    /// its `id` decodes fine — so the protection that covers a typo did not cover this. The registry
    /// collapses the repeat to one record (last wins, deliberately: see
    /// ``PersonRegistry/uniqueById(_:)``), and the store's `people` is that collapsed roster. Every
    /// edit path then writes the whole file from it — `add`, `update`, `remove` and even dismissing
    /// a single name suggestion — so **an edit to a completely unrelated person deletes the
    /// duplicated block from disk**, with no prompt, no backup, and nothing in the log: `save()`'s
    /// only loss warning covers unmodelled top-level keys, and those are carried faithfully, so the
    /// rewrite looks clean.
    ///
    /// The advice in the load-time warning — "give each person a unique id in this file" — is what
    /// makes it worst: by the time the user opens the file to do that, the record they needed to
    /// reconcile can already be gone, and it will never warn again, because the file is now clean.
    ///
    /// So a reinterpreted roster is treated like an unreadable one for WRITES. The collapse still
    /// happens in memory — one id has to mean one person for the app to work at all — but the file
    /// is left alone until the person who wrote it decides which record they meant.
    @Test func aRosterWithARepeatedIdIsNotOverwrittenByAnEdit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two blocks, one id, differing in every other field — the copy-paste this protects.
        try write("""
            {
              "schemaVersion": 1,
              "_note": "why Anuraag is on this roster",
              "people": [
                { "id": "girish", "displayName": "Girish", "relationship": "father",
                  "fullNames": ["Girish Krishnamurthy"], "aliases": ["Dad"] },
                { "id": "girish", "displayName": "Girish K", "fullNames": ["Girish Kumar"] },
                { "id": "muktha", "displayName": "Muktha" }
              ]
            }
            """, to: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        // The premise, both halves. The file decoded (so the unreadable guard is NOT what saves it
        // here), and the roster really was collapsed (so there is something to lose).
        #expect(store.rosterIsUnreadable == false,
                "a repeated id is valid JSON — if this reads as unreadable the test proves nothing")
        #expect(store.people.count == 2, "the repeat was not collapsed, so no record is at risk")
        #expect(store.repeatedRosterIds == ["girish"], "the store does not know the roster repeats an id")

        // An edit to somebody else entirely — the trigger does not have to touch the duplicate.
        store.add(displayName: "Shweta")

        let after = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))
        #expect(after == before, "the duplicated person's first record was deleted from people.json")
    }

    // MARK: - A roster the process cannot even READ is never overwritten

    /// **The read layer has the same two states as the parse layer, and it lost them.** A file
    /// that exists but cannot be opened — mode 000, an ACL, an I/O error — came back from
    /// `contents(atPath:)` as nil, exactly like no file at all, so the unreadable guard never
    /// armed. The save's atomic rename needs permission on the *directory*, not the file, so the
    /// first edit then succeeded precisely where the read had failed and replaced the household
    /// with the folder-name seed.
    @Test func aRosterTheProcessCannotOpenIsNotOverwrittenByAnEdit() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("p/people.json")
        let fm = FileManager.default
        defer {
            // Give the bytes back before the sweep, or the temp dir outlives the test.
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? fm.removeItem(at: dir)
        }
        try write(Self.handWritten, to: dir)
        let before = try Data(contentsOf: url)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable,
                "a file that exists but cannot be opened holds a household this session cannot see")
        store.add(displayName: "Shweta")

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let after = try Data(contentsOf: url)
        #expect(after == before,
                "the household was overwritten because a failed read was mistaken for no file")
    }

    /// The same hole through the other door: `people.json` symlinked somewhere that does not
    /// resolve right now — a volume that is not mounted. The read fails, and the atomic write
    /// would replace the *link itself* with a plain file, orphaning the roster it points at.
    @Test func aDanglingSymlinkAtTheRosterPathIsNotReplacedByAnEdit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p/people.json")
        let target = "/Volumes/NoSuchVolume/people.json"
        try FileManager.default.createSymbolicLink(at: url,
                                                   withDestinationURL: URL(fileURLWithPath: target))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable,
                "a link whose target is missing is not the same as no roster at all")
        store.add(displayName: "Shweta")

        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        #expect(dest == target, "the symlink was replaced by a plain file the app wrote")
    }

    /// "any file at all", every ordinary edit would stop saving and the two tests above would still
    /// pass. A readable roster must save exactly as before.
    @Test func aReadableRosterStillSavesEveryEdit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWritten, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable == false)
        store.add(displayName: "Shweta")

        let saved = try read(dir)
        let names = (saved["people"] as? [[String: Any]])?.compactMap { $0["displayName"] as? String }
        #expect(names?.sorted() == ["Abhishek", "Shweta"], "the edit must still be written")
        #expect(saved["_note"] as? String == "Anuraag is on this roster because the tree already files for him.")
    }

    // MARK: - The same failure inside a person record

    /// **A key written ON a person is destroyed by the first edit to ANYBODY.**
    ///
    /// `carriedKeys` reads the top-level object and filters it against `PeopleFileOut.modelledKeys`
    /// — so `_note` beside `people` survives, and `nickname` on Abhishek does not. `Person` models
    /// exactly five keys and `init(from:)` ignores the rest, so the record re-encodes without them
    /// and the whole-file write puts that on disk. Nothing fails: the file is well-formed and looks
    /// complete, which is why this needed a test rather than a bug report.
    @Test func anEditKeepsKeysWrittenInsideAPersonRecord() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWrittenPerPerson, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Shweta")            // an edit to somebody else entirely

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        let abhishek = try #require(people.first { $0["id"] as? String == "abhishek" })
        #expect(abhishek["nickname"] as? String == "Abhi",
                "a key written on a person was deleted by an edit to a different person")
        #expect(abhishek["_why"] as? String == "the tree files under his full name",
                "prose on a person is the same kind of thing as prose beside them")
        // And the modelled fields still round-trip, so the merge did not replace the record.
        #expect(abhishek["displayName"] as? String == "Abhishek")
        #expect(abhishek["fullNames"] as? [String] == ["Abhishek Girish"])
    }

    /// A person with no extras gains none, and the new person is written normally — the merge must
    /// not invent keys or skip records it has nothing for.
    @Test func recordsWithNothingCarriedAreUntouched() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWrittenPerPerson, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Shweta")

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        let muktha = try #require(people.first { $0["id"] as? String == "muktha" })
        #expect(Set(muktha.keys) == ["id", "displayName"])
        let shweta = try #require(people.first { $0["displayName"] as? String == "Shweta" })
        #expect(Set(shweta.keys) == ["id", "displayName"])
    }

    /// **Deleting a person takes their carried keys with them.**
    ///
    /// The merge is driven by the records being written, not by the carried map, so a person the
    /// user just removed has nothing to merge into. Driving it the other way would put a record
    /// back that was deliberately deleted — a whole-file write is the one place that mistake is
    /// invisible.
    @Test func aRemovedPersonIsNotResurrectedByTheirCarriedKeys() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWrittenPerPerson, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.remove(id: "abhishek")

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        #expect(!people.contains { $0["id"] as? String == "abhishek" },
                "the deleted person came back through the carry")
        #expect(people.contains { $0["id"] as? String == "muktha" })
    }

    /// A field this build DOES model is this build's to write, even if the file had it too —
    /// the same rule the top-level merge follows, checked because preferring the carried copy
    /// would pin a value the user can no longer change from the UI.
    @Test func aModelledFieldIsNotShadowedByTheCarriedCopy() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWrittenPerPerson, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        let person = try #require(store.person(id: "abhishek"))
        store.update(Person(id: person.id, displayName: "Abhishek G",
                            relationship: person.relationship,
                            fullNames: person.fullNames, aliases: person.aliases))

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        let abhishek = try #require(people.first { $0["id"] as? String == "abhishek" })
        #expect(abhishek["displayName"] as? String == "Abhishek G")
        #expect(abhishek["nickname"] as? String == "Abhi", "the rename dropped the carried key")
    }
}
