import Testing
import Foundation
@testable import Sync

/// What `people.json` keeps when the app writes it back. The file is hand-written as much as
/// app-written: notes and extra keys, on the file or on a person, are prose no survey can
/// regenerate. `PeopleFileOut` writes four keys and the save replaces the whole file, so anything
/// else must be carried across, and a roster this build can't read faithfully must never be
/// overwritten.
@MainActor
@Suite struct PeopleStorePersistenceTests {

    private func makeDirectory() throws -> URL { try makeProfilesDir(prefix: "people-store") }

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
          "_note": "Uncle is on this roster because the tree already files for him.",
          "somethingANewerBuildWrote": { "kind": "whatever", "n": 3 },
          "people": [
            { "id": "father", "displayName": "Father", "fullNames": ["Father Elder"] }
          ]
        }
        """

    /// The same hand-editing, one level down: keys written ON a person rather than beside them.
    private static let handWrittenPerPerson = """
        {
          "schemaVersion": 1,
          "people": [
            { "id": "father", "displayName": "Father", "fullNames": ["Father Elder"],
              "nickname": "Fath", "_why": "the tree files under his full name" },
            { "id": "granny", "displayName": "Granny" }
          ]
        }
        """

    // MARK: - The bug

    /// The edit itself lands too, or this would also pass if `save()` did nothing. And it is the
    /// non-vacuity case for the unreadable-roster guards below: if the guard read "any file at
    /// all", every edit would stop saving and they would still pass.
    @Test func anEditKeepsTheNoteAndAnythingElseInTheFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWritten, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable == false)
        store.add(displayName: "Mother")            // any edit at all rewrites the whole file

        let saved = try read(dir)
        let people = try #require(saved["people"] as? [[String: Any]])
        #expect(people.count == 2)
        #expect(Set(people.compactMap { $0["id"] as? String }) == ["father", "mother"])
        #expect(people.compactMap { $0["displayName"] as? String }.sorted() == ["Father", "Mother"],
                "the edit must still be written")
        #expect(saved["schemaVersion"] as? Int == FilingProfileStore.currentSchema)
        #expect(saved["_note"] as? String
                == "Uncle is on this roster because the tree already files for him.",
                "the note the user wrote was dropped by an edit made in the app")
        let carried = saved["somethingANewerBuildWrote"] as? [String: Any]
        #expect(carried?["kind"] as? String == "whatever")
        #expect(carried?["n"] as? Int == 3,
                "a key a newer build wrote must survive a round trip through this one")
    }

    /// A carried key can never shadow one the app owns. Keys are captured at load and re-applied at
    /// save, so a captured `people` would be the old roster and undo the edit. Modelled keys are
    /// excluded when captured.
    @Test func aStaleRosterInTheFileCannotOverwriteTheEditBeingSaved() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWritten, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.remove(id: "father")

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        #expect(people.isEmpty, "the removal was undone by the file's own earlier contents")
    }

    /// Rejections persist beside the roster, and still do with a note in the file.
    @Test func rejectedNameFormsSurviveAlongsideTheNote() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWritten, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.dismissSuggestion(PersonNameSuggestion(personId: "father", form: "Fath Elder",
                                                     occurrences: 2, exampleFile: "x.pdf"))
        let saved = try read(dir)
        #expect((saved["notNames"] as? [String])?.isEmpty == false)
        #expect(saved["_note"] != nil, "carrying the note must not cost the app its own keys")
    }

    // MARK: - Nothing to carry

    @Test func aFirstEverSaveWritesACleanFile() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No people.json at all: the seeded-roster case, where the file appears on first edit.
        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        // An absent file is a first launch: no protection, no load-time warning (the init warns
        // exactly when this flag is set), and the save lands.
        #expect(store.rosterIsUnreadable == false,
                "an absent file was mistaken for one that exists but cannot be read")
        store.add(displayName: "Daughter")

        let saved = try read(dir)
        #expect(Set(saved.keys) == ["schemaVersion", "people"],
                "a fresh file should carry nothing but what the app writes: \(saved.keys)")
    }

    /// A file that isn't JSON at all costs the carry, never the edit: bytes that parse as nothing
    /// hold no roster to protect.
    @Test func anUnreadableFileDoesNotBlockTheSave() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("this is not json {{{", to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Son")

        let saved = try read(dir)
        #expect((saved["people"] as? [[String: Any]])?.count == 1)
        #expect(store.rosterIsUnreadable == false,
                "bytes that parse as nothing hold no roster to protect — the edit must still land")
    }

    // MARK: - A roster this build cannot decode is never overwritten

    /// `carriedKeys` keeps only keys this build doesn't model, so a `people` that fails to decode
    /// can't be carried. The load falls back to a folder-name seed that looks ordinary in Settings,
    /// and an edit would replace the real household with it.
    @Test func aRosterWithOneBadEntryIsNotOverwrittenByAnEdit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Valid JSON, real household, one hand-edit typo: `fullNames` is a string, not an array.
        let broken = """
            {
              "schemaVersion": 1,
              "_note": "why Uncle is on this roster",
              "people": [
                { "id": "father", "displayName": "Father", "fullNames": "Father Elder" }
              ]
            }
            """
        try write(broken, to: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        #expect(store.rosterIsUnreadable, "an undecodable roster must be known to be undecodable")
        store.add(displayName: "Mother")

        let after = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))
        #expect(after == before, "the household was overwritten by a roster the app guessed")
    }

    /// A file a newer build wrote. The schema probe rightly rejects it, which makes it the case
    /// above: real data this build can't decode, and rewriting it would downgrade the roster.
    @Test func aRosterFromANewerSchemaIsNotOverwritten() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("""
            {
              "schemaVersion": 99,
              "people": [{ "id": "father", "displayName": "Father", "somethingNew": true }]
            }
            """, to: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Mother")

        let after = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))
        #expect(after == before, "a newer build's file was downgraded by this one")
    }

    // MARK: - A roster this build REINTERPRETED is never overwritten either

    /// A person block copy-pasted without changing its `id` decodes fine, so `rosterIsUnreadable`
    /// doesn't catch it. The registry collapses the repeat (last wins, see
    /// ``PersonRegistry/uniqueById(_:)``), and any whole-file write from that roster, even one for
    /// an unrelated person, would silently delete a block the user still has to reconcile. So the
    /// collapse happens in memory only, and the file is left alone for writes until they choose.
    @Test func aRosterWithARepeatedIdIsNotOverwrittenByAnEdit() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two blocks, one id, differing in every other field: the copy-paste this protects.
        try write("""
            {
              "schemaVersion": 1,
              "_note": "why Uncle is on this roster",
              "people": [
                { "id": "elder", "displayName": "Elder", "relationship": "father",
                  "fullNames": ["Elder Forebear"], "aliases": ["Dad"] },
                { "id": "elder", "displayName": "Elder F", "fullNames": ["Elder Kumar"] },
                { "id": "granny", "displayName": "Granny" }
              ]
            }
            """, to: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        // The premise: the file decoded (so the unreadable guard isn't what saves it), and the
        // roster really was collapsed (so there is something to lose).
        #expect(store.rosterIsUnreadable == false,
                "a repeated id is valid JSON — if this reads as unreadable the test proves nothing")
        #expect(store.people.count == 2, "the repeat was not collapsed, so no record is at risk")
        #expect(store.repeatedRosterIds == ["elder"], "the store does not know the roster repeats an id")

        // An edit to somebody else entirely: the trigger needn't touch the duplicate.
        store.add(displayName: "Mother")

        let after = try Data(contentsOf: dir.appendingPathComponent("p/people.json"))
        #expect(after == before, "the duplicated person's first record was deleted from people.json")
    }

    // MARK: - A roster the process cannot even READ is never overwritten

    /// A file that exists but can't be opened (mode 000, an ACL, an I/O error) must count as
    /// unreadable, not as no file. `contents(atPath:)` answers nil for both, and the save's atomic
    /// rename needs permission only on the directory, so an edit would replace the household with
    /// the folder-name seed.
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
        store.add(displayName: "Mother")

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let after = try Data(contentsOf: url)
        #expect(after == before,
                "the household was overwritten because a failed read was mistaken for no file")
    }

    /// The same hole through a symlink: `people.json` linked to an unmounted volume. The read
    /// fails, and the atomic write would replace the link itself with a plain file, orphaning the
    /// roster it points at.
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
        store.add(displayName: "Mother")

        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        #expect(dest == target, "the symlink was replaced by a plain file the app wrote")
    }

    // MARK: - The same failure inside a person record

    /// A key written on a person must survive an edit to anybody. `Person` models five keys and
    /// `init(from:)` ignores the rest, so without a per-person carry the whole-file write would
    /// drop them, leaving a well-formed file that looks complete.
    @Test func anEditKeepsKeysWrittenInsideAPersonRecord() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWrittenPerPerson, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.add(displayName: "Mother")            // an edit to somebody else entirely

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        let father = try #require(people.first { $0["id"] as? String == "father" })
        #expect(father["nickname"] as? String == "Fath",
                "a key written on a person was deleted by an edit to a different person")
        #expect(father["_why"] as? String == "the tree files under his full name",
                "prose on a person is the same kind of thing as prose beside them")
        // And the modelled fields still round-trip, so the merge did not replace the record.
        #expect(father["displayName"] as? String == "Father")
        #expect(father["fullNames"] as? [String] == ["Father Elder"])
        // A person with no extras gains none, and the new person is written normally: the merge
        // must not invent keys or skip records it has nothing for.
        let granny = try #require(people.first { $0["id"] as? String == "granny" })
        #expect(Set(granny.keys) == ["id", "displayName"])
        let mother = try #require(people.first { $0["displayName"] as? String == "Mother" })
        #expect(Set(mother.keys) == ["id", "displayName"])
    }

    /// Deleting a person takes their carried keys with them. The merge is driven by the records
    /// being written, not by the carried map, which would put a deleted record back.
    @Test func aRemovedPersonIsNotResurrectedByTheirCarriedKeys() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWrittenPerPerson, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        store.remove(id: "father")

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        #expect(!people.contains { $0["id"] as? String == "father" },
                "the deleted person came back through the carry")
        #expect(people.contains { $0["id"] as? String == "granny" })
    }

    /// A field this build models is this build's to write, as at the top level. Preferring the
    /// carried copy would pin a value the user can no longer change from the UI.
    @Test func aModelledFieldIsNotShadowedByTheCarriedCopy() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(Self.handWrittenPerPerson, to: dir)

        let store = PeopleStore(directory: dir, profileId: "p", profile: nil)
        let person = try #require(store.person(id: "father"))
        store.update(Person(id: person.id, displayName: "Father G",
                            relationship: person.relationship,
                            fullNames: person.fullNames, aliases: person.aliases))

        let people = try #require(try read(dir)["people"] as? [[String: Any]])
        let father = try #require(people.first { $0["id"] as? String == "father" })
        #expect(father["displayName"] as? String == "Father G")
        #expect(father["nickname"] as? String == "Fath", "the rename dropped the carried key")
    }
}
