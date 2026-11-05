import Events
import Foundation
import Sync
import Testing
@testable import SyncCloud

/// The answers setup collects before there is anywhere to put them.
///
/// `people.json` lives inside a profile, and a fresh machine has no profile until the folder survey
/// mints one. These tests pin that gap being crossed once, in one direction, without duplicating
/// anybody.
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
        draft.yourName = "Father"
        draft.yourFullNames = ["Father Elder", "Father I Elder"]
        draft.others = [SetupDraft.DraftPerson(displayName: "Mother", relationship: "wife")]
        SetupDraftStore.write(draft, to: url)

        #expect(SetupDraftStore.read(at: url) == draft)
    }

    @Test func anAbsentDraftIsNotAnError() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SetupDraftStore.read(at: dir.appendingPathComponent("nothing.json")) == nil)
    }

    /// A draft this build cannot read is asked for again, never half-applied: asking again costs a
    /// minute, while a partly decoded draft builds a wrong household that every document is then
    /// attributed through.
    @Test func aForeignSchemaIsIgnoredRatherThanGuessedAt() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("setup-draft.json")
        try #"{"schemaVersion": 99, "draft": {"yourName": "Father", "yourFullNames": [], "others": []}}"#
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

    /// Absent and unreadable both answer `nil`, and only unreadable says so in the log.
    ///
    /// Absent is every launch before the user answers anything. Unreadable means answers they gave
    /// are about to be asked for again, and this file is their only copy, so it earns a line in
    /// `~/sync-cloud.log` naming the path.
    ///
    /// Read from a capture opened before each read, since `Logger.shared` is process-wide and
    /// rolled; each window requires its own closing line, so one that saw nothing can't pass.
    /// Matched on this test's UUID scratch paths, not the line's words, so sibling tests that also
    /// log about a draft can't land in the window, and the suite can stay unserialized.
    @MainActor
    @Test func onlyAnUnreadableDraftSaysSoInTheLog() async throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        /// Everything logged while the read under test runs, from a capture opened before it.
        func window(_ act: () -> Void) async throws -> [String] {
            let log = LogCapture()
            act()
            let close = "setup-draft window close \(UUID().uuidString.prefix(8))"
            Logger.shared.debug(close)
            let messages = await log.entries.map(\.message)
            let closed = messages.contains(close)
            try #require(closed, "the capture never saw this window's own closing line — this reading is vacuous")
            return messages
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
        var named = SetupDraft(); named.yourName = "Father"
        #expect(!named.isEmpty)
        var blank = SetupDraft(); blank.yourName = "   "
        #expect(blank.isEmpty, "whitespace is not a name")
    }

    /// You lead the roster, and the order matters: `PeopleStore.add` makes an id unique within the
    /// roster as it stands, so the first added gets the plain id. Your own record is what every
    /// other surface resolves through.
    @Test func youLeadTheRosterAndAreMarkedAsYou() throws {
        var draft = SetupDraft()
        draft.yourName = "Father"
        draft.yourFullNames = ["Father Elder"]
        draft.others = [SetupDraft.DraftPerson(displayName: "Mother")]

        let everyone = draft.everyone
        #expect(everyone.count == 2)
        let first = try #require(everyone.first)
        #expect(first.displayName == "Father")
        #expect(first.relationship == "me")
        #expect(first.fullNames == ["Father Elder"])
    }

    @Test func anUnnamedYouIsSimplyAbsentFromTheRoster() {
        var draft = SetupDraft()
        draft.others = [SetupDraft.DraftPerson(displayName: "Mother")]
        #expect(draft.everyone.map(\.displayName) == ["Mother"])
    }

    // MARK: - As a registry for the walk

    /// The draft becomes the household the walk is built with.
    @Test func theDraftBecomesARegistryTheWalkCanUse() throws {
        var draft = SetupDraft()
        draft.yourName = "Father"
        draft.others = [SetupDraft.DraftPerson(displayName: "Mother")]

        let registry = try #require(draft.registry)
        #expect(Set(registry.people.map(\.displayName)) == ["Father", "Mother"])
        #expect(registry.people.first?.relationship == "me", "you should lead, marked as you")
    }

    @Test func anEmptyDraftIsNoRegistryAtAll() {
        #expect(SetupDraft().registry == nil, "an empty registry is not the same as none")
    }

    /// Two names that derive the same id both survive. `PersonRegistry` collapses a repeated id to
    /// the last one, so a draft handing it duplicates would silently lose somebody. `Anne Marie` and
    /// `Anne-Marie` both fold to `anne-marie`.
    @Test func twoNamesThatShareAnIdBothReachTheWalk() throws {
        var draft = SetupDraft()
        draft.others = [SetupDraft.DraftPerson(displayName: "Anne Marie"),
                        SetupDraft.DraftPerson(displayName: "Anne-Marie")]

        let registry = try #require(draft.registry)
        #expect(registry.people.count == 2, "one of them was collapsed away before the walk saw it")
        #expect(Set(registry.people.map(\.id)).count == 2, "the ids are still the same id")
    }

    /// The control: those two names really do derive one id, or the test above proves nothing.
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
        draft.yourName = "Father"
        draft.yourFullNames = ["Father Elder"]
        draft.others = [SetupDraft.DraftPerson(displayName: "Mother", relationship: "wife")]

        let result = SetupDraft.apply(draft, to: store)
        #expect(result.added == 2)
        #expect(Set(store.people.map(\.displayName)) == ["Father", "Mother"])
        let me = try #require(store.people.first { $0.displayName == "Father" })
        #expect(me.relationship == "me")
        #expect(me.fullNames == ["Father Elder"])
    }

    /// Applying twice must not produce two of anybody. It runs more than once by design: on every
    /// step commit when a profile exists, and again after the survey mints one. Two records for one
    /// person split the matcher, which keeps the last in one half and both in the other.
    @MainActor
    @Test func applyingIsIdempotent() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)

        var draft = SetupDraft()
        draft.yourName = "Father"
        draft.others = [SetupDraft.DraftPerson(displayName: "Mother")]

        SetupDraft.apply(draft, to: store)
        let second = SetupDraft.apply(draft, to: store)

        #expect(second.added == 0)
        #expect(store.people.count == 2)
        #expect(store.people.filter { $0.displayName == "Father" }.count == 1)
    }

    /// A name that differs only in case is the same person.
    @MainActor
    @Test func applyingMatchesAnExistingPersonCaseInsensitively() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)
        store.add(displayName: "mother")

        var draft = SetupDraft()
        draft.others = [SetupDraft.DraftPerson(displayName: "Mother")]
        SetupDraft.apply(draft, to: store)

        #expect(store.people.count == 1, "“Mother” and “mother” are one person")
    }

    /// Setup adds to a record, never takes from one: the user may have typed a full name into
    /// Settings ▸ People before the draft applies, and overwriting it would delete their work.
    @MainActor
    @Test func applyingAddsFullNamesWithoutRemovingOnesTheUserTyped() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)
        store.add(displayName: "Father", relationship: "me",
                  fullNames: ["Father Inlaw Elder"])

        var draft = SetupDraft()
        draft.yourName = "Father"
        draft.yourFullNames = ["Father Elder"]
        let result = SetupDraft.apply(draft, to: store)

        #expect(result.updated == 1)
        let me = try #require(store.people.first)
        #expect(me.fullNames.contains("Father Inlaw Elder"), "the hand-typed form was deleted")
        #expect(me.fullNames.contains("Father Elder"))
    }

    /// The same form in a different case is not a new form.
    @MainActor
    @Test func applyingDoesNotGrowAFullNameListWithRestatements() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)
        store.add(displayName: "Father", fullNames: ["father elder"])

        var draft = SetupDraft()
        draft.yourName = "Father"
        draft.yourFullNames = ["Father Elder"]
        SetupDraft.apply(draft, to: store)

        let me = try #require(store.people.first)
        #expect(me.fullNames.count == 1, "“Father Elder” was added beside “father elder”")
    }

    /// The control for the two tests above, which assert a list did not grow: an `apply` that
    /// wrote nothing would pass them. This shows the same call writes when it has something new.
    @MainActor
    @Test func applyingReallyDoesWriteWhenItHasSomethingNew() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = emptyStore(in: dir)
        store.add(displayName: "Father", fullNames: ["Father Elder"])

        var draft = SetupDraft()
        draft.yourName = "Father"
        draft.yourFullNames = ["F. I. Elder"]
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
