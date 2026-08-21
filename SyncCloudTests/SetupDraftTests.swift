import Events
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

    /// **Absent and unreadable both answer `nil`, and only one of them may do it quietly.**
    ///
    /// Returning `nil` is the whole of what the two states have in common, and it is what the two
    /// tests above already pin — so a test of the *return* cannot tell them apart, and neither
    /// could the code until v4.2: both were a bare `try?`. The difference is what it costs the
    /// user. Absent is every launch before they answer anything. Unreadable means the answers they
    /// *did* give are about to be asked for again, and this file is the only copy of them
    /// (`clear(at:)` refuses to run until they have reached a roster). That is the one worth a line
    /// in `~/sync-cloud.log`, and the line has to name the path or it cannot be looked at by hand.
    ///
    /// Read between two of this test's own markers rather than over the whole buffer:
    /// `Logger.shared` is process-wide and `entries` is a rolled 1000-line window, so a bare
    /// `contains` would let a rolled window pass the absence half for free. The opening marker is
    /// `#require`d, which is the eviction guard.
    ///
    /// **Matched on this test's own scratch paths, not on the words the line uses**, and that is
    /// what lets the suite stay unserialized. Two sibling tests here (`garbageIsIgnored…`,
    /// `aForeignSchema…`) now log about a draft too, and a phrase match would let either of them
    /// land inside this window and fail the absence half for a reason that is not this test's
    /// subject. The scratch directory carries a UUID, so no other test in the process can produce
    /// a line naming these files.
    @MainActor
    @Test func onlyAnUnreadableDraftSaysSoInTheLog() async throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        /// Everything logged between two fresh markers, with the read under test run between them.
        func window(_ act: () -> Void) async throws -> ArraySlice<String> {
            let token = UUID().uuidString.prefix(8)
            await Logger.shared.debug("setup-draft window open \(token)").value
            act()
            await Logger.shared.debug("setup-draft window close \(token)").value
            let messages = Logger.shared.entries.map(\.message)
            let opened = try #require(messages.firstIndex(where: { $0.contains("open \(token)") }),
                                      "the log window rolled past this test's own marker — this reading is vacuous")
            let tail = messages[opened...]
            let closed = try #require(tail.lastIndex(where: { $0.contains("close \(token)") }),
                                      "the closing marker never landed — this reading is vacuous")
            return tail[...closed]
        }

        // Absent: the ordinary case, on every launch before the user has answered anything.
        let missing = dir.appendingPathComponent("nothing.json")
        let quiet = try await window { _ = SetupDraftStore.read(at: missing) }
        #expect(!quiet.contains(where: { $0.contains(missing.path) }),
                "a draft that was never written logged a line — that fires on every launch and is how a log stops being read")

        // Present and undecodable: the user's answers are being discarded.
        let broken = dir.appendingPathComponent("setup-draft.json")
        try "not json at all".write(to: broken, atomically: true, encoding: .utf8)
        let noisy = try await window { _ = SetupDraftStore.read(at: broken) }
        let line = try #require(noisy.last(where: { $0.contains(broken.path) }),
                                "an unreadable draft threw away answers with nothing in the log naming the file")
        #expect(line.lowercased().contains("could not") || line.lowercased().contains("cannot decode"),
                "the line names the file but not what went wrong with it: \(line)")
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
