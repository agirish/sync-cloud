import Foundation
import Testing
@testable import Sync

/// What the cross-person rule has stopped, and whether it survives a launch.
///
/// The veto's own decision is tested where the rule lives; this is the record of it — the part the
/// People section reads to say what a person's record has bought. It persists, so it is tested from
/// **stored bytes** rather than only from a live object: `PersonVetoEvent` is `Codable` and a
/// decode that silently fails would empty the log with nothing to show for it.
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

    /// Per-person, and it is the *named* person the count is for — the one whose document was
    /// headed into somebody else's folder. Counting by `proposedPerson` would report the refusals
    /// against the person whose folder was refused, which is the opposite claim.
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

    /// **Capped and lossy on purpose** — an illustration, not an audit trail. The oldest fall off,
    /// so what remains is the newest `capacity`, not the first ones recorded.
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

    /// The whole point of persisting: a count survives the process. Built by making a *second*
    /// store over the same suite, which is what the next launch does.
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

    /// **From stored bytes this test wrote itself**, not from anything the app encoded — the fixture
    /// a schema change has to keep satisfying. A field renamed on `PersonVetoEvent` fails here,
    /// where the failure names the type, instead of silently emptying the log at the next launch.
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

    /// A stored value this build cannot read empties the log rather than taking the launch with it.
    /// (`events` is the app's "nothing has been refused yet" state, which is also the honest thing
    /// to show when the record is unreadable.)
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

    /// **A stored value this build cannot decode must not be overwritten by the next refusal.**
    ///
    /// The load was `guard let data = …, let decoded = try? … else { return }`, so an undecodable
    /// value left `events` empty — indistinguishable from a machine that has refused nothing — and
    /// `record` then called `save`, writing that empty array over history it had never read. One
    /// refusal, and the log is gone. `PersonVetoEvent` is a stored `Codable`, so a newer build
    /// adding a non-optional field produces exactly this on the older one.
    ///
    /// Asserted on the STORED BYTES, because `events` is empty either way — reading the in-memory
    /// array is what cannot tell the two apart.
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

    /// And the session still works — the refusal is visible now, it is just not persisted over
    /// something unreadable. A guard that also stopped recording would trade a data loss for a
    /// dead feature.
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

    /// The other direction, so the guard cannot become "never persist": with NOTHING stored — the
    /// ordinary state — a refusal is written as it always was.
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

    /// A readable log keeps being appended to across launches — the control that proves the flag
    /// is set from the decode and not from "there were bytes".
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
