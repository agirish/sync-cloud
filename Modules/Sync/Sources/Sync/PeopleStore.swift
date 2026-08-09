import Events
import Foundation

/// The household, owned and edited by the app — the one writable filing artifact.
///
/// **Deliberately the exception to ``FilingProfileStore``'s read-only rule, and the reason is that
/// the roster is not survey output.** The folder profile and the filing memory describe a tree, and
/// a half-finished scan writing either back would be worse than not having it. Who the people *are*
/// is not derived from anything — a survey can see that a folder is called `Shweta`, but not that
/// documents print "Shweta Ravindra Dani", and certainly not that Anuraag is a brother. Only the
/// user knows that, so only the user can write it, and there has to be somewhere for them to.
///
/// Writes are whole-file and atomic: the roster is seven records, a rewrite costs nothing, and a
/// partial write would leave the engine attributing documents through half a household.
@MainActor
public final class PeopleStore: ObservableObject {
    /// The roster as it is on disk. Published so the Settings list and anything else reading the
    /// registry re-render the instant a person is added, edited or removed.
    @Published public private(set) var people: [Person] = []
    /// Where the roster came from — a file the user owns, or a seed from the survey's person axis.
    /// Shown in Settings, because "seeded from your folder names" and "you wrote this" are
    /// different claims about how much the app knows.
    @Published public private(set) var source: PersonRegistry.Source = .profileAxis

    /// The compiled matcher. Recompiled on every change rather than cached: building it is a pass
    /// over a handful of names, and a stale matcher would attribute documents through a roster the
    /// user has already corrected.
    public var registry: PersonRegistry { PersonRegistry(people: people, source: source) }

    private let directory: URL
    private let profileId: String
    private let fileManager: FileManager

    /// `people.json` for the active profile.
    public var fileURL: URL {
        directory.appendingPathComponent("\(profileId)/people.json")
    }

    /// Loads the roster, seeding from `profile` when no file exists yet.
    ///
    /// **The seed is not written to disk.** A seeded roster is the app's reading of the survey, and
    /// writing it would turn a guess into a record the user never made — the file appears the first
    /// time they actually change something.
    public init(directory: URL, profileId: String, profile: FolderProfile?,
                fileManager: FileManager = .default) {
        self.directory = directory
        self.profileId = profileId
        self.fileManager = fileManager
        let loaded = FilingProfileStore.personRegistry(id: profileId, profile: profile,
                                                       in: directory)
        people = loaded.people
        source = loaded.source
    }

    /// A store with no file behind it, for tests and previews — edits stay in memory.
    public init(people: [Person]) {
        self.directory = URL(fileURLWithPath: "/dev/null")
        self.profileId = ""
        self.fileManager = .default
        self.people = people
        self.source = .file
    }

    private var isPersistent: Bool { !profileId.isEmpty }

    // MARK: - Editing

    /// Adds a person, giving them an id derived from their display name and unique within the
    /// roster. Returns the person as stored, or nil when the name is blank.
    @discardableResult
    public func add(displayName: String, relationship: String? = nil,
                    fullNames: [String] = [], aliases: [String] = []) -> Person? {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let person = Person(id: uniqueId(from: name), displayName: name,
                            relationship: Self.cleaned(relationship),
                            fullNames: Self.cleanedList(fullNames),
                            aliases: Self.cleanedList(aliases))
        people.append(person)
        sortAndSave()
        Logger.shared.info("People: added '\(person.displayName)' (\(person.id))")
        return person
    }

    /// Replaces a person, matched on id — so a rename keeps every folder and rule pointing at them.
    public func update(_ person: Person) {
        guard let i = people.firstIndex(where: { $0.id == person.id }) else { return }
        var cleanedPerson = person
        cleanedPerson.displayName = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanedPerson.relationship = Self.cleaned(person.relationship)
        cleanedPerson.fullNames = Self.cleanedList(person.fullNames)
        cleanedPerson.aliases = Self.cleanedList(person.aliases)
        guard !cleanedPerson.displayName.isEmpty, cleanedPerson != people[i] else { return }
        people[i] = cleanedPerson
        sortAndSave()
        Logger.shared.info("People: updated '\(cleanedPerson.displayName)' (\(cleanedPerson.id))")
    }

    /// Removes a person from the roster.
    ///
    /// **Touches no file and no folder.** Their folders keep their names and their contents; what
    /// changes is that documents naming them stop being attributed, so the cross-person veto no
    /// longer protects — or refuses — anything on their behalf.
    public func remove(id: String) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        let removed = people.remove(at: i)
        sortAndSave()
        Logger.shared.info("People: removed '\(removed.displayName)' — documents naming them are "
                           + "no longer attributed to anyone")
    }

    public func person(id: String) -> Person? { people.first { $0.id == id } }

    // MARK: - Persistence

    private func sortAndSave() {
        // Sorted by display name so the file and the list agree, and a diff of `people.json` shows
        // what changed rather than where a record moved to.
        people.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        source = .file            // the moment a person is edited, the roster is the user's
        save()
    }

    private struct PeopleFileOut: Encodable {
        let schemaVersion: Int
        let people: [Person]
    }

    private func save() {
        guard isPersistent else { return }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(PeopleFileOut(schemaVersion: FilingProfileStore.currentSchema,
                                                        people: people))
            // Atomic: the engine reads this file at launch and the fingerprint hashes it, so a
            // torn write would be a half-household that looks like a whole one.
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.shared.warning("Couldn't save people.json — the change is in memory only "
                                  + "this session: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// An id that no one else in the roster holds. Collisions are real — two people can share a
    /// first name — so a numeric suffix is appended rather than letting the second overwrite the
    /// first's folders.
    private func uniqueId(from displayName: String) -> String {
        let base = Person.idCandidate(from: displayName)
        guard people.contains(where: { $0.id == base }) else { return base }
        var n = 2
        while people.contains(where: { $0.id == "\(base)-\(n)" }) { n += 1 }
        return "\(base)-\(n)"
    }

    private static func cleaned(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// Trimmed, de-duplicated case-insensitively, blanks dropped, order preserved — the user's
    /// typing order is the order they will look for it in.
    private static func cleanedList(_ list: [String]) -> [String] {
        var out: [String] = []
        for raw in list {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !out.contains(where: { $0.lowercased() == t.lowercased() }) else { continue }
            out.append(t)
        }
        return out
    }
}
