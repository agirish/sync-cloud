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

    static func event(named: String, proposed: String = "aditi", file: String = "Passport.pdf",
                      destination: String = "School/Aditi",
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

        log.record(Self.event(named: "muktha", file: "First.pdf"))
        log.record(Self.event(named: "muktha", file: "Second.pdf"))

        #expect(log.events.map(\.fileName) == ["Second.pdf", "First.pdf"])
    }

    /// Per-person, and it is the *named* person the count is for — the one whose document was
    /// headed into somebody else's folder. Counting by `proposedPerson` would report the refusals
    /// against the person whose folder was refused, which is the opposite claim.
    @Test func theCountIsForThePersonTheDocumentNames() {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let log = Self.store(suite)

        log.record(Self.event(named: "muktha", proposed: "aditi"))
        log.record(Self.event(named: "muktha", proposed: "abhishek"))
        log.record(Self.event(named: "aditi", proposed: "muktha"))

        #expect(log.count(namedPerson: "muktha") == 2)
        #expect(log.count(namedPerson: "aditi") == 1)
        #expect(log.count(namedPerson: "nobody") == 0)
    }

    @Test func theMostRecentRefusalIsTheOneJustRecorded() throws {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let log = Self.store(suite)

        log.record(Self.event(named: "muktha", file: "Older.pdf"))
        log.record(Self.event(named: "aditi", file: "Someone else's.pdf"))
        log.record(Self.event(named: "muktha", file: "Newer.pdf"))

        #expect(try #require(log.mostRecent(namedPerson: "muktha")).fileName == "Newer.pdf")
        #expect(log.mostRecent(namedPerson: "nobody") == nil)
    }

    /// **Capped and lossy on purpose** — an illustration, not an audit trail. The oldest fall off,
    /// so what remains is the newest `capacity`, not the first ones recorded.
    @Test func theOldestEventsFallOffTheEnd() {
        let suite = "PersonVetoLogTests-\(UUID().uuidString)"
        defer { wipeDefaultsSuite(suite) }
        let log = Self.store(suite)

        for i in 0..<(PersonVetoLog.capacity + 10) {
            log.record(Self.event(named: "muktha", file: "\(i).pdf"))
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
        first.record(Self.event(named: "muktha", file: "Passport.pdf", destination: "School/Aditi"))

        let relaunched = Self.store(suite)
        #expect(relaunched.count(namedPerson: "muktha") == 1)
        let event = try #require(relaunched.mostRecent(namedPerson: "muktha"))
        #expect(event.fileName == "Passport.pdf")
        #expect(event.destination == "School/Aditi")
        #expect(event.proposedPerson == "aditi")
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
            [{"namedPerson":"muktha","proposedPerson":"aditi","fileName":"Muktha Girish Passport.pdf",\
            "destination":"School/Aditi","at":747248400}]
            """
        defaults.set(Data(stored.utf8), forKey: PersonVetoLog.defaultsKey)

        let log = PersonVetoLog(userDefaults: defaults)

        let event = try #require(log.events.first)
        #expect(log.events.count == 1)
        #expect(event.namedPerson == "muktha")
        #expect(event.proposedPerson == "aditi")
        #expect(event.fileName == "Muktha Girish Passport.pdf")
        #expect(event.destination == "School/Aditi")
        #expect(log.count(namedPerson: "muktha") == 1)
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
        log.record(Self.event(named: "muktha"))

        log.clear()

        #expect(log.events.isEmpty)
        #expect(Self.store(suite).events.isEmpty, "the cleared log came back at the next launch")
    }
}
