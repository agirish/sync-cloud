import Events
import Foundation

/// A refusal as the engine reports it, before anything decides to keep it.
///
/// Separate from ``PersonVetoEvent`` because the engine has no clock: `applyVerdicts` is a pure
/// function over suggestions, and stamping a `Date` inside it would make its output depend on when
/// it ran. The caller adds the time.
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
    /// The person whose folder the backend proposed.
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

/// What the cross-person rule has actually stopped.
///
/// **The one thing about this feature that was invisible by construction.** The veto's whole job is
/// to make a wrong suggestion not happen, so working perfectly looks identical to not existing —
/// and the measurement that justified it (36 documents the old rule would have let into the wrong
/// person's folder) lives in a test, not in front of the user. This records each refusal so the
/// People section can say, per person, what their record has bought.
///
/// **Capped and lossy on purpose.** It is an illustration, not an audit trail: the count that
/// matters is "3 this month", and keeping every event forever to show the last two of them would
/// be storing a filing history nobody asked for. Oldest events fall off the end.
@MainActor
public final class PersonVetoLog: ObservableObject {
    @Published public private(set) var events: [PersonVetoEvent] = []

    /// Enough to show a per-person count and a recent example without becoming a diary.
    static let capacity = 60
    static let defaultsKey = "personVetoLog_v1"

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        guard let data = userDefaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([PersonVetoEvent].self, from: data) else { return }
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

    /// How many refusals protected this person's documents — i.e. the document named them and was
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
        guard let data = try? JSONEncoder().encode(events) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
