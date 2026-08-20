import Foundation
import Sync
import Testing
@testable import SyncCloud

/// The answers setup collects before there is anywhere to put them.
///
/// **The draft exists because of an ordering problem**: `people.json` lives *inside* a profile, and
/// a fresh machine — the only machine setup is for — has no profile until the folder survey mints
/// one. Everything here is about that gap being crossed exactly once, in one direction, without
/// duplicating anybody.
@Suite struct SetupDraftTests {

    private static func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The file

    @Test func aDraftSurvivesARoundTrip() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("setup-draft.json")

        var draft = SetupDraft()
        draft.yourName = "Abhishek"
        draft.yourFullNames = ["Abhishek Girish", "Abhishek R Girish"]
        draft.others = [SetupDraft.DraftPerson(displayName: "Shweta", relationship: "wife")]
        SetupDraftStore.write(draft, to: url)

        #expect(SetupDraftStore.read(at: url) == draft)
    }

    @Test func anAbsentDraftIsNotAnError() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SetupDraftStore.read(at: dir.appendingPathComponent("nothing.json")) == nil)
    }

    /// A draft this build cannot read is one setup asks for again — never one it half-applies.
    ///
    /// The cost of the two failures is not symmetric: asking again costs the user a minute, while a
    /// partly-decoded draft costs them a wrong household, and the roster is the file every document
    /// is attributed through.
    @Test func aForeignSchemaIsIgnoredRatherThanGuessedAt() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("setup-draft.json")
        try #"{"schemaVersion": 99, "draft": {"yourName": "Abhishek", "yourFullNames": [], "others": []}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(SetupDraftStore.read(at: url) == nil)
    }

    @Test func garbageIsIgnoredRatherThanGuessedAt() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("setup-draft.json")
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)
        #expect(SetupDraftStore.read(at: url) == nil)
    }

    @Test func clearingRemovesTheFileAndToleratesItsAbsence() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("setup-draft.json")
        SetupDraftStore.write(SetupDraft(), to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        SetupDraftStore.clear(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        SetupDraftStore.clear(at: url)  // must not throw on a second pass
    }

    // MARK: - Shape

    @Test func anEmptyDraftKnowsItIsEmpty() {
        #expect(SetupDraft().isEmpty)
        var named = SetupDraft(); named.yourName = "Abhishek"
        #expect(!named.isEmpty)
        var blank = SetupDraft(); blank.yourName = "   "
        #expect(blank.isEmpty, "whitespace is not a name")
    }

    /// You lead the roster, and the order is load-bearing.
    ///
    /// `PeopleStore.add` derives an id from the display name and makes it unique *within the roster
    /// as it stands*, so whoever is added first gets the plain id and a later namesake gets the
    /// suffixed one. Your own record is what every other surface resolves through.
    @Test func youLeadTheRosterAndAreMarkedAsYou() throws {
        var draft = SetupDraft()
        draft.yourName = "Abhishek"
        draft.yourFullNames = ["Abhishek Girish"]
        draft.others = [SetupDraft.DraftPerson(displayName: "Shweta")]

        let everyone = draft.everyone
        #expect(everyone.count == 2)
        let first = try #require(everyone.first)
        #expect(first.displayName == "Abhishek")
        #expect(first.relationship == "me")
        #expect(first.fullNames == ["Abhishek Girish"])
    }

    @Test func anUnnamedYouIsSimplyAbsentFromTheRoster() {
        var draft = SetupDraft()
        draft.others = [SetupDraft.DraftPerson(displayName: "Shweta")]
        #expect(draft.everyone.map(\.displayName) == ["Shweta"])
    }

    // MARK: - As a registry for the walk

    /// The draft becomes the household the walk is built with.
    @Test func theDraftBecomesARegistryTheWalkCanUse() throws {
        var draft = SetupDraft()
        draft.yourName = "Abhishek"
        draft.others = [SetupDraft.DraftPerson(displayName: "Shweta")]

        let registry = try #require(draft.registry)
        #expect(Set(registry.people.map(\.displayName)) == ["Abhishek", "Shweta"])
        #expect(registry.people.first?.relationship == "me", "you should lead, marked as you")
    }

    @Test func anEmptyDraftIsNoRegistryAtAll() {
        #expect(SetupDraft().registry == nil, "an empty registry is not the same as none")
    }

    /// Two names that derive the same id both survive.
    ///
    /// **`PersonRegistry` collapses a repeated id to last-one-wins**, which is right there — an id
    /// must name one person — and means a draft handing it duplicates would lose somebody silently
    /// on the way into the walk. `Anne Marie` and `Anne-Marie` both fold to `anne-marie`.
    @Test func twoNamesThatShareAnIdBothReachTheWalk() throws {
        var draft = SetupDraft()
        draft.others = [SetupDraft.DraftPerson(displayName: "Anne Marie"),
                        SetupDraft.DraftPerson(displayName: "Anne-Marie")]

        let registry = try #require(draft.registry)
        #expect(registry.people.count == 2, "one of them was collapsed away before the walk saw it")
        #expect(Set(registry.people.map(\.id)).count == 2, "the ids are still the same id")
    }

    /// The control: those two names really do derive one id.
    ///
    /// Without it the test above passes on any two names, and proves nothing about collisions.
    @Test func thoseTwoNamesReallyDoCollide() {
        #expect(Person.idCandidate(from: "Anne Marie") == Person.idCandidate(from: "Anne-Marie"),
                "the fixture no longer collides, so the uniquing is untested")
    }

    // MARK: - Applying it

    @MainActor
    private func emptyStore(in directory: URL) -> PeopleStore {
        PeopleStore(directory: directory, profileId: "test", profile: nil)
    }

    @MainActor
    @Test func applyingWritesEveryoneIntoTheRoster() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)

        var draft = SetupDraft()
        draft.yourName = "Abhishek"
        draft.yourFullNames = ["Abhishek Girish"]
        draft.others = [SetupDraft.DraftPerson(displayName: "Shweta", relationship: "wife")]

        let result = SetupDraft.apply(draft, to: store)
        #expect(result.added == 2)
        #expect(Set(store.people.map(\.displayName)) == ["Abhishek", "Shweta"])
        let me = try #require(store.people.first { $0.displayName == "Abhishek" })
        #expect(me.relationship == "me")
        #expect(me.fullNames == ["Abhishek Girish"])
    }

    /// Applying twice must not produce two of anybody.
    ///
    /// **It is called more than once by design** — a machine with a profile applies on every step
    /// commit, and the survey stage applies again after minting one. This is the assertion that
    /// makes that safe, and a duplicate here is not cosmetic: two records claiming one person is
    /// the state `PersonRegistry` had to grow a collapse for, because one half of the matcher took
    /// the last and the other accumulated both.
    @MainActor
    @Test func applyingIsIdempotent() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)

        var draft = SetupDraft()
        draft.yourName = "Abhishek"
        draft.others = [SetupDraft.DraftPerson(displayName: "Shweta")]

        SetupDraft.apply(draft, to: store)
        let second = SetupDraft.apply(draft, to: store)

        #expect(second.added == 0)
        #expect(store.people.count == 2)
        #expect(store.people.filter { $0.displayName == "Abhishek" }.count == 1)
    }

    /// A name that differs only in case is the same person.
    @MainActor
    @Test func applyingMatchesAnExistingPersonCaseInsensitively() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)
        store.add(displayName: "shweta")

        var draft = SetupDraft()
        draft.others = [SetupDraft.DraftPerson(displayName: "Shweta")]
        SetupDraft.apply(draft, to: store)

        #expect(store.people.count == 1, "“Shweta” and “shweta” are one person")
    }

    /// Setup adds to a record; it never takes anything out of one.
    ///
    /// The user may have typed a full name into Settings ▸ People between running setup and setup
    /// applying its draft — a form re-run overwriting that would delete work the user did by hand
    /// in the surface that is supposed to own it.
    @MainActor
    @Test func applyingAddsFullNamesWithoutRemovingOnesTheUserTyped() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)
        store.add(displayName: "Abhishek", relationship: "me",
                  fullNames: ["Abhishek Ravindra Girish"])

        var draft = SetupDraft()
        draft.yourName = "Abhishek"
        draft.yourFullNames = ["Abhishek Girish"]
        let result = SetupDraft.apply(draft, to: store)

        #expect(result.updated == 1)
        let me = try #require(store.people.first)
        #expect(me.fullNames.contains("Abhishek Ravindra Girish"), "the hand-typed form was deleted")
        #expect(me.fullNames.contains("Abhishek Girish"))
    }

    /// The same form in a different case is not a new form.
    @MainActor
    @Test func applyingDoesNotGrowAFullNameListWithRestatements() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)
        store.add(displayName: "Abhishek", fullNames: ["abhishek girish"])

        var draft = SetupDraft()
        draft.yourName = "Abhishek"
        draft.yourFullNames = ["Abhishek Girish"]
        SetupDraft.apply(draft, to: store)

        let me = try #require(store.people.first)
        #expect(me.fullNames.count == 1, "“Abhishek Girish” was added beside “abhishek girish”")
    }

    /// The mutation that proves the two tests above are looking at anything.
    ///
    /// Both assert that a list did *not* grow, which a broken `apply` that wrote nothing at all
    /// would satisfy perfectly. This one shows the same call really does write when it has
    /// something new to say.
    @MainActor
    @Test func applyingReallyDoesWriteWhenItHasSomethingNew() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)
        store.add(displayName: "Abhishek", fullNames: ["Abhishek Girish"])

        var draft = SetupDraft()
        draft.yourName = "Abhishek"
        draft.yourFullNames = ["A. R. Girish"]
        SetupDraft.apply(draft, to: store)

        let me = try #require(store.people.first)
        #expect(me.fullNames.count == 2)
    }

    @MainActor
    @Test func anEmptyNameIsNeverAddedToTheRoster() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)

        var draft = SetupDraft()
        draft.others = [SetupDraft.DraftPerson(displayName: "   ")]
        SetupDraft.apply(draft, to: store)

        #expect(store.people.isEmpty)
    }
}
