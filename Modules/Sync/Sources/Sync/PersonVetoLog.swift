import Events
import Foundation

/// A refusal as the engine reports it, before anything decides to keep it.
///
/// Separate from ``PersonVetoEvent`` because the engine has no clock: `applyVerdicts` is pure, and
/// a `Date` stamped inside it would make its output depend on when it ran. The caller adds the time.
public struct PersonVetoRefusal: Sendable, Equatable {
    public let namedPerson: String
    public let proposedPerson: String
    public let fileName: String
    public let destination: String

    public init(namedPerson: String, proposedPerson: String, fileName: String, destination: String) {
        self.namedPerson = namedPerson
        self.proposedPerson = proposedPerson
        self.fileName = fileName
        self.destination = destination
    }
}

/// One time the cross-person rule refused a suggestion.
public struct PersonVetoEvent: Sendable, Equatable, Codable {
    /// The person the document names.
    public let namedPerson: String
    /// The person whose folder the refused home belongs to. Not necessarily the backend's: the rule
    /// sweeps every home on every card, and the keyword engine and router propose most of them (all
    /// of them without Apple Intelligence).
    public let proposedPerson: String
    public let fileName: String
    /// Where it would have gone, relative to the provider root.
    public let destination: String
    public let at: Date

    public init(namedPerson: String, proposedPerson: String, fileName: String,
                destination: String, at: Date) {
        self.namedPerson = namedPerson
        self.proposedPerson = proposedPerson
        self.fileName = fileName
        self.destination = destination
        self.at = at
    }
}

/// What the cross-person rule has stopped. A veto that works looks the same as no veto, so this
/// records each refusal and the People section can say, per person, what their record has bought.
///
/// Capped and lossy on purpose: an illustration, not an audit trail. Keeping every event would
/// store a filing history nobody asked for, so the oldest fall off the end.
@MainActor
public final class PersonVetoLog: ObservableObject {
    @Published public private(set) var events: [PersonVetoEvent] = []

    /// Enough to show a per-person count and a recent example without becoming a diary.
    static let capacity = 60
    nonisolated static let defaultsKey = "personVetoLog_v1"

    private let userDefaults: UserDefaults

    /// True when the defaults hold a value for this key that this build could not decode.
    ///
    /// Absent and unreadable must stay distinct. Treated as empty, an unreadable value would be
    /// overwritten by the next ``record(_:)``, losing the log. It happens whenever a newer build
    /// adds a non-optional field to `PersonVetoEvent` and an older build runs. The roster
    /// (`PeopleStore.rosterIsUnreadable`), filing corpus and verdict cache follow the same rule.
    private let storedValueIsUnreadable: Bool

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        guard let data = userDefaults.data(forKey: Self.defaultsKey) else {
            // Nothing stored: the ordinary state of a machine that has refused nothing.
            storedValueIsUnreadable = false
            return
        }
        guard let decoded = try? JSONDecoder().decode([PersonVetoEvent].self, from: data) else {
            storedValueIsUnreadable = true
            // Said once, at load: the log is built once per launch, so this holds for the session
            // and a later fix isn't re-read until relaunch.
            Logger.shared.warning("The person veto log is stored but could not be read — this "
                                  + "session shows no past refusals and will NOT overwrite them. "
                                  + "They are still in defaults under \(Self.defaultsKey); "
                                  + "relaunching on a build that understands them restores the view.")
            return
        }
        storedValueIsUnreadable = false
        events = decoded
    }

    /// Records a refusal, newest first.
    public func record(_ event: PersonVetoEvent) {
        events.insert(event, at: 0)
        if events.count > Self.capacity { events.removeLast(events.count - Self.capacity) }
        save()
        Logger.shared.info("Filing: refused “\(event.fileName)” for \(event.destination) — it names "
                           + "\(event.namedPerson), that folder is \(event.proposedPerson)'s")
    }

    /// How many refusals protected this person's documents: the document named them and was
    /// headed somewhere else.
    public func count(namedPerson id: String) -> Int {
        events.filter { $0.namedPerson == id }.count
    }

    /// The most recent refusal on this person's behalf.
    public func mostRecent(namedPerson id: String) -> PersonVetoEvent? {
        events.first { $0.namedPerson == id }
    }

    public func clear() {
        guard !events.isEmpty else { return }
        events = []
        userDefaults.removeObject(forKey: Self.defaultsKey)
    }

    private func save() {
        // **Never** write over a value this build could not read: each save replaces the whole
        // value, and after a failed load this array is only what this session saw, not the
        // history. See ``storedValueIsUnreadable``.
        guard !storedValueIsUnreadable else { return }
        guard let data = try? JSONEncoder().encode(events) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
