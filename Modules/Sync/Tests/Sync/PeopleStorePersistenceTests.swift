import Testing
import Foundation
@testable import Sync

/// What `people.json` keeps when the app writes it back.
///
/// **The file is hand-written as much as it is app-written.** The real roster carries a `_note`
/// explaining why Anuraag is on it, why listing a full name is what makes a shared surname
/// attributable, and why `Abhi` and `Shwe` are recorded as name forms rather than nicknames — all
/// of it prose no survey can regenerate. `PeopleFileOut` writes three keys and the save is a
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
}
