import Foundation
import Testing
@testable import Sync

/// What the cross-person rule has stopped, and whether it survives a launch.
///
/// The veto's decision is tested where the rule lives; this is its record, which the People section
/// reads to say what a person's record has bought. It persists, so it is tested from stored bytes,
/// not only a live object: a `PersonVetoEvent` decode that silently fails would empty the log.
@MainActor
@Suite struct PersonVetoLogTests {

    static func event(named: String, proposed: String = "daughter", file: String = "Passport.pdf",
                      destination: String = "School/Daughter",
                      at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> PersonVetoEvent {
        PersonVetoEvent(namedPerson: named, proposedPerson: proposed, fileName: file,
                        destination: destination, at: at)
    }

    /// A store on its own defaults suite, wiped after.
    static func store(_ suite: String) -> PersonVetoLog {
        PersonVetoLog(userDefaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: - Recording

    @Test func aRefusalIsRecordedNewestFirst() {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let log = Self.store(suite)

        log.record(Self.event(named: "granny", file: "First.pdf"))
        log.record(Self.event(named: "granny", file: "Second.pdf"))

        #expect(log.events.map(\.fileName) == ["Second.pdf", "First.pdf"])
    }

    /// The count is for the named person, whose document was headed into somebody else's folder.
    /// Counting by `proposedPerson` would make the opposite claim.
    @Test func theCountIsForThePersonTheDocumentNames() {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let log = Self.store(suite)

        log.record(Self.event(named: "granny", proposed: "daughter"))
        log.record(Self.event(named: "granny", proposed: "father"))
        log.record(Self.event(named: "daughter", proposed: "granny"))

        #expect(log.count(namedPerson: "granny") == 2)
        #expect(log.count(namedPerson: "daughter") == 1)
        #expect(log.count(namedPerson: "nobody") == 0)
    }

    @Test func theMostRecentRefusalIsTheOneJustRecorded() throws {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let log = Self.store(suite)

        log.record(Self.event(named: "granny", file: "Older.pdf"))
        log.record(Self.event(named: "daughter", file: "Someone else's.pdf"))
        log.record(Self.event(named: "granny", file: "Newer.pdf"))

        #expect(try #require(log.mostRecent(namedPerson: "granny")).fileName == "Newer.pdf")
        #expect(log.mostRecent(namedPerson: "nobody") == nil)
    }

    /// Capped and lossy on purpose: an illustration, not an audit trail. The oldest fall off, so
    /// what remains is the newest `capacity`.
    @Test func theOldestEventsFallOffTheEnd() {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let log = Self.store(suite)

        for i in 0..<(PersonVetoLog.capacity + 10) {
            log.record(Self.event(named: "granny", file: "\(i).pdf"))
        }

        #expect(log.events.count == PersonVetoLog.capacity)
        #expect(log.events.first?.fileName == "\(PersonVetoLog.capacity + 9).pdf")
        #expect(log.events.last?.fileName == "10.pdf", "kept the oldest and dropped the newest")
        #expect(!log.events.contains { $0.fileName == "0.pdf" })
    }

    // MARK: - Across a launch

    /// A count survives the process: a second store over the same suite, as the next launch makes.
    @Test func aRecordedRefusalSurvivesTheNextLaunch() throws {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }

        let first = Self.store(suite)
        first.record(Self.event(named: "granny", file: "Passport.pdf", destination: "School/Daughter"))

        let relaunched = Self.store(suite)
        #expect(relaunched.count(namedPerson: "granny") == 1)
        let event = try #require(relaunched.mostRecent(namedPerson: "granny"))
        #expect(event.fileName == "Passport.pdf")
        #expect(event.destination == "School/Daughter")
        #expect(event.proposedPerson == "daughter")
        #expect(event.at == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// From stored bytes this test wrote, not anything the app encoded: the fixture a schema change
    /// must keep satisfying. A renamed `PersonVetoEvent` field fails here instead of silently
    /// emptying the log at the next launch.
    @Test func aStoredLogDecodesFieldForField() throws {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let stored = """
            [{"namedPerson":"granny","proposedPerson":"daughter","fileName":"Granny Elder Passport.pdf",\
            "destination":"School/Daughter","at":747248400}]
            """
        defaults.set(Data(stored.utf8), forKey: PersonVetoLog.defaultsKey)

        let log = PersonVetoLog(userDefaults: defaults)

        let event = try #require(log.events.first)
        #expect(log.events.count == 1)
        #expect(event.namedPerson == "granny")
        #expect(event.proposedPerson == "daughter")
        #expect(event.fileName == "Granny Elder Passport.pdf")
        #expect(event.destination == "School/Daughter")
        #expect(log.count(namedPerson: "granny") == 1)
    }

    /// A stored value this build can't read shows an empty log rather than taking the launch with
    /// it; "nothing refused yet" is the honest thing to show.
    @Test func anUnreadableStoredLogStartsEmpty() {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("not a log at all".utf8), forKey: PersonVetoLog.defaultsKey)

        #expect(PersonVetoLog(userDefaults: defaults).events.isEmpty)
    }

    @Test func clearingRemovesTheStoredRecordToo() {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let log = Self.store(suite)
        log.record(Self.event(named: "granny"))

        log.clear()

        #expect(log.events.isEmpty)
        #expect(Self.store(suite).events.isEmpty, "the cleared log came back at the next launch")
    }

    // MARK: - Absent, unreadable, and the write that used to collapse them

    /// A stored value this build can't decode must not be overwritten by the next refusal, which
    /// would write over history it never read. A newer build adding a non-optional field to
    /// `PersonVetoEvent` produces this. Asserted on the stored bytes, since `events` is empty
    /// either way.
    @Test func anUnreadableStoredLogIsNotOverwrittenByANewRefusal() throws {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let theirs = Data("{\"schema\":2,\"events\":[]}".utf8)   // valid JSON, not our shape
        defaults.set(theirs, forKey: PersonVetoLog.defaultsKey)

        let log = PersonVetoLog(userDefaults: defaults)
        #expect(log.events.isEmpty, "fixture: an unreadable value shows as no refusals")

        log.record(Self.event(named: "granny", file: "Passport.pdf"))

        #expect(defaults.data(forKey: PersonVetoLog.defaultsKey) == theirs,
                "the refusal overwrote a stored log this build never read")
    }

    /// The session still works: the refusal is visible now, just not persisted over something
    /// unreadable. A guard that also stopped recording would trade data loss for a dead feature.
    @Test func anUnreadableStoredLogStillShowsThisSessionsRefusals() throws {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(Data("not our shape at all".utf8), forKey: PersonVetoLog.defaultsKey)

        let log = PersonVetoLog(userDefaults: defaults)
        log.record(Self.event(named: "granny", file: "Passport.pdf"))

        #expect(log.events.count == 1)
        #expect(log.count(namedPerson: "granny") == 1)
    }

    /// The other direction, so the guard can't become "never persist": with nothing stored, the
    /// ordinary state, a refusal is written.
    @Test func anAbsentLogIsStillWrittenToOnFirstRefusal() throws {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        #expect(defaults.data(forKey: PersonVetoLog.defaultsKey) == nil, "fixture: nothing stored")

        let log = PersonVetoLog(userDefaults: defaults)
        log.record(Self.event(named: "granny", file: "Passport.pdf"))

        let stored = try #require(defaults.data(forKey: PersonVetoLog.defaultsKey),
                                  "an absent log was treated as unreadable and never persisted")
        let decoded = try JSONDecoder().decode([PersonVetoEvent].self, from: stored)
        #expect(decoded.map(\.fileName) == ["Passport.pdf"])
    }

    /// A readable log keeps being appended to across launches: the flag comes from the decode, not
    /// from "there were bytes".
    @Test func aReadableLogIsStillAppendedToAfterARelaunch() throws {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))

        let first = PersonVetoLog(userDefaults: defaults)
        first.record(Self.event(named: "granny", file: "First.pdf"))

        let second = PersonVetoLog(userDefaults: defaults)          // the relaunch
        #expect(second.events.map(\.fileName) == ["First.pdf"])
        second.record(Self.event(named: "granny", file: "Second.pdf"))

        let third = PersonVetoLog(userDefaults: defaults)
        #expect(third.events.map(\.fileName) == ["Second.pdf", "First.pdf"],
                "a readable log stopped persisting — the unreadable guard is firing too widely")
    }
}
