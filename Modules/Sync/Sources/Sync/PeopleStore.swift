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
        dismissedSuggestions = FilingProfileStore.dismissedNameSuggestions(id: profileId,
                                                                           in: directory)
        carriedKeys = Self.unmodelledKeys(at: fileURL)
        rosterIsUnreadable = Self.rosterIsUnreadable(at: fileURL, loaded: loaded,
                                                     fileManager: fileManager)
        if rosterIsUnreadable {
            // The store is built once per launch, so this state lasts the session: fixing the file
            // now does not re-read it. Say so, rather than implying an edit will start working.
            Logger.shared.warning("people.json exists but could not be read — showing the roster "
                                  + "seeded from folder names, and REFUSING to write over the file. "
                                  + "Fix \(fileURL.path) and relaunch to edit the household again.")
        }
    }

    /// True when `people.json` holds **structured data this build could not decode** — a hand-edit
    /// that broke one `Person` entry, or a schema a newer build wrote.
    ///
    /// **This is the difference between "no roster yet" and "a roster I cannot read", and until it
    /// existed the two were the same state.** A failed decode falls back to a registry seeded from
    /// folder names, which looks populated in Settings — six or seven people, no full names — so
    /// nothing tells the user their roster did not load. The first edit then calls `save()`, and a
    /// whole-file atomic write replaces the real household with the seed: every full name, alias,
    /// relationship, dismissed suggestion and the `_note` prose, gone, with no backup. The
    /// carried-keys mechanism cannot help, because `people` is a key this build *models*, so the
    /// real roster is exactly what a carry is defined not to preserve.
    ///
    /// **A file that is not JSON at all is deliberately NOT this case**, and that is not an
    /// oversight — see `anUnreadableFileDoesNotBlockTheSave`. Bytes that parse as nothing hold no
    /// roster to protect, and refusing every edit until the user hand-repairs a corrupt file would
    /// trade a rare loss for a permanent lockout. The line is whether there is structured content
    /// to lose: valid JSON that did not decode is a household this build merely failed to
    /// understand, and rewriting it is the loss this flag exists to prevent.
    @Published public private(set) var rosterIsUnreadable = false

    /// Bumped **after** each successful write of `people.json`, and never otherwise.
    ///
    /// Exists because `$people` is the wrong signal for anything that reads the *file*. Publishing
    /// happens when the array is assigned; the write happens after, at the end of `sortAndSave()`.
    /// A subscriber refreshing the filing artifact fingerprint from `$people` therefore hashed the
    /// bytes of the roster **before** this edit — so every edit left the fingerprint one save
    /// stale, and `FilingVerdictCache`, keyed on it, went on replaying classifications composed
    /// against the previous household until a relaunch or a re-survey. Silently serving answers
    /// from the old roster is the exact thing the fingerprint was introduced to prevent.
    ///
    /// A counter rather than a `Void` subject so it composes with `@Published` like everything
    /// else here, and so a test can assert "the write happened" rather than only observe it. Not
    /// bumped when the save is declined (no profile, or an unreadable roster): nothing changed on
    /// disk, so nothing downstream needs to re-read it.
    @Published public private(set) var savedRevision: Int = 0

    /// Decides the above from two independent facts: did the registry come from the file (`source`
    /// is `.file` only on a successful decode), and is there JSON in the file at all.
    private static func rosterIsUnreadable(at url: URL, loaded: PersonRegistry,
                                           fileManager: FileManager) -> Bool {
        guard loaded.source != .file else { return false }        // decoded, nothing to protect from
        guard let data = fileManager.contents(atPath: url.path) else { return false }   // no file
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Top-level keys in `people.json` that this build does not model, kept so writing the file
    /// back does not throw them away.
    ///
    /// **The file is hand-written as much as it is app-written, and the prose in it is the part
    /// worth keeping.** `_note` on the real roster explains why Anuraag is on it, why listing a
    /// full name is what makes a shared surname attributable, and why `Abhi` and `Shwe` are
    /// recorded — none of which the app can regenerate. Before this, the first edit made in
    /// Settings ▸ People silently deleted all of it, because ``PeopleFileOut`` writes exactly three
    /// keys and a whole-file atomic write replaces everything else with nothing.
    ///
    /// Carried generically rather than as a `note: String?` field, for the same reason
    /// ``PersonTagVerdict/unrecognized(_:)`` exists one file over: the failure is not "the note is
    /// missing", it is "this build rewrote a file it had only partly understood". A key added by a
    /// newer build, or by him in a text editor, survives a round trip through this one.
    private var carriedKeys: [String: Any] = [:]

    /// The keys of `people.json` that this build has no field for.
    ///
    /// Read from the bytes rather than through `Codable`, because a `Decodable` that ignores
    /// unknown keys is exactly what cannot report them. Failure is silent and total on purpose: an
    /// unreadable file means nothing is carried, which is the same outcome as before this existed.
    private static func unmodelledKeys(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.filter { !PeopleFileOut.modelledKeys.contains($0.key) }
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

    /// Name forms the user has said are NOT theirs, so a rejected suggestion never returns.
    ///
    /// Persisted with the roster rather than in defaults: it is a fact about these people, and a
    /// roster copied to another machine should carry its refusals with it — otherwise every
    /// suggestion the user has already dismissed comes back on the new machine.
    @Published public private(set) var dismissedSuggestions: Set<String> = []

    /// Records a name form as "not this person's". Keyed the same way the suggestion is, so the
    /// rule that produced it filters it out next time.
    public func dismissSuggestion(_ suggestion: PersonNameSuggestion) {
        guard !dismissedSuggestions.contains(suggestion.id) else { return }
        dismissedSuggestions.insert(suggestion.id)
        save()
        Logger.shared.info("People: “\(suggestion.form)” is not \(suggestion.personId)'s — "
                           + "it will not be suggested again")
    }

    /// Accepts a suggested form onto the person it was found for.
    public func acceptSuggestion(_ suggestion: PersonNameSuggestion) {
        guard var person = person(id: suggestion.personId) else { return }
        person.fullNames.append(suggestion.form)
        update(person)
    }

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
        save()
    }

    private struct PeopleFileOut: Encodable {
        let schemaVersion: Int
        let people: [Person]
        /// Omitted when empty, so an untouched file stays as short as it was.
        let notNames: [String]?

        /// Everything this type writes. Anything else in the file belongs to somebody else and is
        /// carried across a save — see ``PeopleStore/carriedKeys``.
        ///
        /// Spelled out rather than derived by encoding an empty value and reading its keys: that
        /// trick omits `notNames` whenever it is nil, so the set would depend on the value it was
        /// derived from and a nil-notNames save would "carry" the app's own key back in.
        static let modelledKeys: Set<String> = ["schemaVersion", "people", "notNames"]
    }

    private func save() {
        guard isPersistent else { return }
        // **A file this build could not read is a file it must not rewrite.** Everything below is a
        // whole-file atomic write of the roster now in memory, and when the load fell back to the
        // folder-name seed that roster is the app's guess, not the user's household. Writing it
        // would replace a real `people.json` with the seed. See `rosterIsUnreadable`.
        guard !rosterIsUnreadable else {
            Logger.shared.warning("Refusing to write people.json — it exists but could not be read, "
                                  + "so this session's roster is a seed and would overwrite the real "
                                  + "one. The change is in memory only.")
            return
        }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(
                PeopleFileOut(schemaVersion: FilingProfileStore.currentSchema, people: people,
                              notNames: dismissedSuggestions.isEmpty ? nil
                                                                     : dismissedSuggestions.sorted()))
            data = Self.merging(carriedKeys, into: data) ?? data
            // Atomic: the engine reads this file at launch and the fingerprint hashes it, so a
            // torn write would be a half-household that looks like a whole one.
            try data.write(to: fileURL, options: .atomic)
            // **Only now are the bytes on disk what this roster says**, which is what anything
            // hashing the file has to wait for. See `savedRevision`.
            savedRevision &+= 1
            // And only now is the file the household of record. Set here rather than by the
            // callers — `sortAndSave()` set it before `save()`, and `dismissSuggestion` was given
            // the same shape — so a save this build REFUSES (an unreadable roster, which is the
            // one case that matters) can no longer leave the list claiming "saved in people.json"
            // beside the banner saying edits will not be saved. Provenance follows the write, for
            // the same reason the fingerprint does.
            source = .file
        } catch {
            Logger.shared.warning("Couldn't save people.json — the change is in memory only "
                                  + "this session: \(error.localizedDescription)")
        }
    }

    /// Puts the carried keys back into freshly encoded JSON.
    ///
    /// **Returns nil rather than throwing, and the caller writes the unmerged bytes on nil.** The
    /// roster is what this file is *for*; losing an edit to it because a comment could not be
    /// re-attached would be the worse trade, and the note is already lost in that case either way.
    ///
    /// The modelled keys win by construction — `carriedKeys` never contains them — so a stale
    /// `people` array read at launch can never overwrite the roster being saved now.
    private static func merging(_ carried: [String: Any], into encoded: Data) -> Data? {
        guard !carried.isEmpty,
              var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return nil }
        object.merge(carried) { fresh, _ in fresh }
        // `.sortedKeys` so the file stays diffable, matching what the encoder above produces.
        return try? JSONSerialization.data(withJSONObject: object,
                                           options: [.prettyPrinted, .sortedKeys,
                                                     .withoutEscapingSlashes])
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
