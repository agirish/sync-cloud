import Events
import Foundation

/// The people a tree files for, owned and edited by the app: the one writable filing artifact.
/// (Comments here say "household" for the file's contents; the user-facing word is "people", see
/// ``PeopleList``.)
///
/// The exception to ``FilingProfileStore``'s read-only rule because the roster is not survey
/// output. A survey can see a folder called `Mother`, but not that documents print "Mother Inlaw
/// Maiden" or who is whose sibling; only the user knows that, so only the user writes it.
///
/// Writes are whole-file and atomic: the roster is small, and a partial write would leave the
/// engine attributing documents through half a household.
@MainActor
public final class PeopleStore: ObservableObject {
    /// The roster as it is on disk. Published so the Settings list and other registry readers
    /// re-render as soon as a person is added, edited or removed.
    @Published public private(set) var people: [Person] = []
    /// Where the roster came from: a file the user owns, or a seed from the survey's person axis.
    /// Shown in Settings, since the two claim different amounts of knowledge.
    @Published public private(set) var source: PersonRegistry.Source = .profileAxis
    /// Whether the user has arranged the list by hand. Until then the roster is shown and saved in
    /// ``PeopleOrder``'s relationship order; after, the file's order is the order and nothing
    /// re-sorts it. Persisted as `"order": "custom"`; absent means default.
    @Published public private(set) var orderIsCustom = false

    /// The compiled matcher, rebuilt on every read rather than cached: it is cheap, and a stale
    /// matcher would attribute documents through a roster the user has already corrected.
    public var registry: PersonRegistry { PersonRegistry(people: people, source: source) }

    /// Where the roster is read from and written to: the profiles directory and the folder inside
    /// it, as handed over at construction.
    ///
    /// `FilingArtifacts.attach` passes `loaded.id`, the folder the artifacts were read from, not
    /// `profile.profileId` inside `folder-profile.json`, which can disagree. Anything reading back
    /// the bytes this store wrote (such as `FileSyncManager.refreshFilingArtifactFingerprint`) must
    /// use this same pair, or it reads a folder that holds no artifacts.
    let directory: URL
    let profileId: String
    private let fileManager: FileManager

    /// `people.json` for the active profile.
    public var fileURL: URL {
        directory.appendingPathComponent("\(profileId)/people.json")
    }

    /// Loads the roster, seeding from `profile` when no file exists yet.
    ///
    /// The seed is not written to disk: it is the app's guess from the survey, and writing it would
    /// make a record the user never made. The file appears at the user's first change.
    public init(directory: URL, profileId: String, profile: FolderProfile?,
                fileManager: FileManager = .default) {
        self.directory = directory
        self.profileId = profileId
        self.fileManager = fileManager
        let loaded = FilingProfileStore.personRegistry(id: profileId, profile: profile,
                                                       in: directory)
        orderIsCustom = Self.orderIsCustom(at: fileURL)
        people = orderIsCustom ? loaded.people : PeopleOrder.arranged(loaded.people)
        source = loaded.source
        dismissedSuggestions = FilingProfileStore.dismissedNameSuggestions(id: profileId,
                                                                           in: directory)
        carriedKeys = Self.unmodelledKeys(at: fileURL)
        carriedPersonKeys = Self.unmodelledPersonKeys(at: fileURL)
        rosterIsUnreadable = Self.rosterIsUnreadable(at: fileURL, loaded: loaded,
                                                     fileManager: fileManager)
        if rosterIsUnreadable {
            // The store is built once per launch, so this lasts the session: a fixed file isn't
            // re-read until relaunch. Say so, rather than implying an edit will start working.
            Logger.shared.warning("people.json exists but could not be read — showing the roster "
                                  + "seeded from folder names, and REFUSING to write over the file. "
                                  + "Fix \(fileURL.path) and relaunch to edit the list again.")
        }
        repeatedRosterIds = source == .file ? loaded.repeatedIds : []
        Self.warnAboutRepeatedIds(loaded.repeatedIds, source: source, fileURL: fileURL)
    }

    /// Says once, at load, that the roster on disk repeats a person id.
    ///
    /// The id is the roster's primary key, but a hand-edit can repeat one (say, copying a person to
    /// add a spelling and keeping the `id`). ``PersonRegistry`` keeps the last record listed, so
    /// the user's file says something they didn't mean and must be told.
    ///
    /// Taken from the registry's `repeatedIds`, read off the raw list: the roster this store holds
    /// is already collapsed, so counting it would find nothing. One line at load, and only for a
    /// roster read from `people.json`, never a seed.
    private static func warnAboutRepeatedIds(_ repeated: [String], source: PersonRegistry.Source,
                                             fileURL: URL) {
        guard source == .file, !repeated.isEmpty else { return }
        Logger.shared.warning("people.json repeats the person id(s) "
                              + "\(repeated.joined(separator: ", ")) — only the LAST entry for a "
                              + "repeated id is kept, and the earlier ones are dropped: the names "
                              + "they listed will not resolve to that person. Give each person a "
                              + "unique id in \(fileURL.path).")
    }

    /// True when `people.json` holds structured data this build could not decode (a broken
    /// hand-edit, or a newer build's schema), or exists but could not be read at all (mode 000, an
    /// ACL, an I/O error, a symlink to an unmounted volume).
    ///
    /// "No roster yet" and "a roster I can't read" must stay distinct. A failed load falls back to
    /// a seed from folder names that looks populated, and the first edit's whole-file write would
    /// replace the real household with it: every full name, alias, relationship, dismissed
    /// suggestion and `_note`, with no backup. Carried keys can't help, since `people` is modelled.
    ///
    /// A file that isn't JSON at all is deliberately not this case
    /// (`anUnreadableFileDoesNotBlockTheSave`): it holds no roster to protect, and refusing every
    /// edit would be a permanent lockout. Unfetchable bytes are protected, because whether they
    /// hold content can't be known, and an atomic save needs only directory permission, so the
    /// write would likely succeed where the read failed.
    @Published public private(set) var rosterIsUnreadable = false

    /// Ids `people.json` listed more than once, sorted and unique; empty for an ordinary roster.
    ///
    /// A second reason not to rewrite the file: a repeated id decodes fine, but the registry
    /// collapses it to one record, so `people` is missing one of the user's records. Writing it back,
    /// on an edit to anybody, would delete that record invisibly. Only for a roster read from the
    /// file; a seed has nothing of the user's to protect.
    @Published public private(set) var repeatedRosterIds: [String] = []

    /// Whether this session may write `people.json` at all, and why not when it may not.
    ///
    /// Two reasons, kept apart in the UI: the roster on screen is a guess, or it is real but
    /// incomplete. Both mean the same for `save()`.
    public var rosterIsReadOnly: Bool { rosterIsUnreadable || !repeatedRosterIds.isEmpty }

    /// Bumped after each successful write of `people.json`, and never otherwise.
    ///
    /// Anything that reads the file must follow this, not `$people`: `$people` publishes on
    /// assignment, before the write, so a fingerprint hashed then would be one save stale and
    /// `FilingVerdictCache`, keyed on it, would replay answers for the previous roster.
    ///
    /// A counter so it composes with `@Published` and a test can assert the write happened. Not
    /// bumped when the save is declined: nothing changed on disk.
    ///
    /// Bumped on every successful write, even one that can't change a classification (a dismissal):
    /// the fingerprint hashes only the parts of `people.json` that can
    /// (``FilingProfileStore/classifyingBytes(ofPeople:)``), so such a write keeps the same digest.
    @Published public private(set) var savedRevision: Int = 0

    /// Decides ``rosterIsUnreadable`` from three facts: did the registry come from the file
    /// (`source` is `.file` only on a successful decode), could the file be read, and is it JSON.
    private static func rosterIsUnreadable(at url: URL, loaded: PersonRegistry,
                                           fileManager: FileManager) -> Bool {
        guard loaded.source != .file else { return false }        // decoded, nothing to protect from
        guard let data = fileManager.contents(atPath: url.path) else {
            // Absent and there-but-unreadable are different answers, and nil alone conflates them.
            // An unopenable file would look like a fresh profile, and `save()`'s atomic rename
            // needs only directory permission, so the first edit would replace the household with
            // the seed. `attributesOfItem`, not `fileExists`, which follows links and answers false
            // for a dangling one, whose link the atomic write would then replace. Without the bytes
            // the JSON test can't run, so whatever is here is protected.
            return (try? fileManager.attributesOfItem(atPath: url.path)) != nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Top-level keys in `people.json` that this build does not model, kept so writing the file
    /// back does not throw them away.
    ///
    /// The file is hand-written as much as app-written, and prose such as `_note` can't be
    /// regenerated. ``PeopleFileOut`` writes only its own keys, and a whole-file write would drop
    /// everything else, so these are merged back on save.
    ///
    /// Carried generically rather than as a `note` field, as with
    /// ``PersonTagVerdict/unrecognized(_:)``: the rule is never to rewrite a file only partly
    /// understood. Top-level only; ``carriedPersonKeys`` holds the keys inside a person record,
    /// which merge back at a different depth.
    private var carriedKeys: [String: Any] = [:]

    /// Unmodelled keys found INSIDE each person record, by person id.
    ///
    /// ``carriedKeys`` one level down. `Person` decodes only ``Person/modelledKeys``, so a
    /// `"nickname"` from a newer build or a hand-edit would vanish from disk at the first edit to
    /// anybody, leaving a file that looks complete.
    ///
    /// Keyed by id, deliberately: a person deleted from the roster takes their keys with them
    /// rather than being resurrected by the merge; a changed id loses them, like every other
    /// per-person fact; and a repeated id never gets here, since ``save()`` refuses to write.
    private var carriedPersonKeys: [String: [String: Any]] = [:]

    /// The keys of `people.json` that this build has no field for.
    ///
    /// Read from the bytes, since a `Decodable` that ignores unknown keys can't report them. An
    /// unreadable file means nothing is carried, silently.
    private static func unmodelledKeys(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.filter { !PeopleFileOut.modelledKeys.contains($0.key) }
    }

    /// The keys inside each person record that this build has no field for, by person id.
    ///
    /// Read from the bytes, as in ``unmodelledKeys(at:)``. A record with no id is skipped: it
    /// can't be matched back on write, and `PersonRegistry` drops it on load too.
    private static func unmodelledPersonKeys(at url: URL) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["people"] as? [[String: Any]]
        else { return [:] }
        var out: [String: [String: Any]] = [:]
        for record in records {
            guard let id = record["id"] as? String else { continue }
            let extras = record.filter { !Person.modelledKeys.contains($0.key) }
            if !extras.isEmpty { out[id] = extras }
        }
        return out
    }

    /// A store with no file behind it, for tests and previews: edits stay in memory.
    public init(people: [Person]) {
        self.directory = URL(fileURLWithPath: "/dev/null")
        self.profileId = ""
        self.fileManager = .default
        // Arranged like a loaded roster, so previews and tests see the order users do. With no
        // file to record a custom order, it starts in the default order.
        self.people = PeopleOrder.arranged(people)
        self.source = .file
    }

    /// False for the in-memory store: nothing it does touches disk.
    var isPersistent: Bool { !profileId.isEmpty }

    // MARK: - Editing

    /// Name forms the user has said are NOT theirs, so a rejected suggestion never returns.
    ///
    /// Persisted with the roster, not in defaults: it is a fact about these people, and a roster
    /// copied to another Mac should bring its refusals along.
    @Published public private(set) var dismissedSuggestions: Set<String> = []

    /// Records a name form as "not this person's". Keyed the same way the suggestion is, so the
    /// rule that produced it filters it out next time.
    public func dismissSuggestion(_ suggestion: PersonNameSuggestion) {
        guard !dismissedSuggestions.contains(suggestion.id) else { return }
        dismissedSuggestions.insert(suggestion.id)
        let before = savedRevision
        save()
        // "again" is a claim about the next launch, and `save()` can refuse. Said only when the
        // write landed; otherwise the dismissal holds for this session, and the log says so.
        let persisted = savedRevision != before
        Logger.shared.info("People: “\(suggestion.form)” is not \(suggestion.personId)'s — "
                           + (persisted ? "it will not be suggested again"
                                        : "not suggested again this session; the roster could not be written"))
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

    /// Replaces a person, matched on id, so a rename keeps every folder and rule pointing at them.
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
    /// Touches no file or folder. Documents naming them stop being attributed, so the cross-person
    /// veto no longer protects or refuses anything on their behalf.
    public func remove(id: String) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        let removed = people.remove(at: i)
        sortAndSave()
        Logger.shared.info("People: removed '\(removed.displayName)' — documents naming them are "
                           + "no longer attributed to anyone")
    }

    public func person(id: String) -> Person? { people.first { $0.id == id } }

    // MARK: - Order

    /// Whether `move(id:up:)` would do anything: the ends of the list refuse.
    public func canMove(id: String, up: Bool) -> Bool {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return false }
        return up ? i > 0 : i < people.count - 1
    }

    /// Swaps a person with their neighbour, and from then on keeps the list in the user's order.
    ///
    /// Returns whether anything moved. A refused move (either end, or an unknown id) leaves the
    /// order flag alone, so a click that did nothing can't turn the default order into a custom one.
    @discardableResult
    public func move(id: String, up: Bool) -> Bool {
        guard canMove(id: id, up: up), let i = people.firstIndex(where: { $0.id == id }) else { return false }
        people.swapAt(i, up ? i - 1 : i + 1)
        orderIsCustom = true
        save()
        Logger.shared.info("People: moved '\(people[up ? i - 1 : i + 1].displayName)' \(up ? "up" : "down") — "
                           + "the list is now in the user's own order")
        return true
    }

    /// Back to relationship order, and the file stops recording a custom one.
    public func useDefaultOrder() {
        orderIsCustom = false
        sortAndSave()
        Logger.shared.info("People: list returned to the default order")
    }

    /// Reads the order flag straight off the file: `PeopleFile` in `FilingProfileStore` doesn't
    /// model it, since the registry has no use for the order.
    private static func orderIsCustom(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["order"] as? String == "custom"
    }

    // MARK: - Persistence

    private func sortAndSave() {
        // The default arrangement, so the file and list agree, unless the user arranged the list
        // themselves; then their order stands and an add goes on the end.
        if !orderIsCustom { people = PeopleOrder.arranged(people) }
        save()
    }

    private struct PeopleFileOut: Encodable {
        let schemaVersion: Int
        let people: [Person]
        /// Omitted when empty, so an untouched file stays as short as it was.
        let notNames: [String]?
        /// `"custom"` once the user has arranged the list; omitted for the default order, so an
        /// untouched file gains no key.
        let order: String?

        /// Everything this type writes. Anything else in the file is carried across a save
        /// (``PeopleStore/carriedKeys``). Spelled out, not derived by encoding a value: nil
        /// optionals are omitted, so the app's own `notNames` would get carried back in.
        static let modelledKeys: Set<String> = ["schemaVersion", "people", "notNames", "order"]
    }

    private func save() {
        guard isPersistent else { return }
        // **Never** rewrite a file this build could not read: the roster in memory is then the
        // folder-name seed, and this whole-file write would replace the real `people.json` with
        // it. See `rosterIsUnreadable`.
        guard !rosterIsUnreadable else {
            Logger.shared.warning("Refusing to write people.json — it exists but could not be read, "
                                  + "so this session's roster is a seed and would overwrite the real "
                                  + "one. The change is in memory only.")
            return
        }
        // **Never** rewrite a file this build reinterpreted either. A repeated id decodes fine but
        // is collapsed to one record, so `people` is missing a record the user typed, and this
        // whole-file write would delete it from disk on an edit to anybody, with no trace. The
        // load-time warning asks the user to fix the ids, and they need that record to do so.
        guard repeatedRosterIds.isEmpty else {
            Logger.shared.warning("Refusing to write people.json — it lists "
                                  + "\(repeatedRosterIds.joined(separator: ", ")) more than once and "
                                  + "this session collapsed each to a single record, so writing "
                                  + "would delete the entries it dropped. The change is in memory "
                                  + "only; give each person a unique id in \(fileURL.path).")
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
                                                                     : dismissedSuggestions.sorted(),
                              order: orderIsCustom ? "custom" : nil))
            if let merged = Self.merging(carriedKeys, perPerson: carriedPersonKeys, into: data) {
                data = merged
            } else if !carriedKeys.isEmpty || !carriedPersonKeys.isEmpty {
                // The write proceeds with the unmerged bytes (see `merging`), but the loss is
                // logged, both kinds named apart: keys dropped silently is what carrying exists to
                // prevent. Nil with nothing to carry is lossless and stays quiet.
                //
                // No test reaches here: `merging` returns nil with something to carry only if
                // `JSONSerialization` can't re-read bytes `JSONEncoder` just produced. Kept so a
                // future change to `merging` can't drop keys silently.
                var lost: [String] = []
                if !carriedKeys.isEmpty {
                    lost.append("\(carriedKeys.count) top-level "
                                + "(\(carriedKeys.keys.sorted().joined(separator: ", ")))")
                }
                if !carriedPersonKeys.isEmpty {
                    let people = carriedPersonKeys.keys.sorted().joined(separator: ", ")
                    let n = carriedPersonKeys.values.reduce(0) { $0 + $1.count }
                    lost.append("\(n) inside person record(s) (\(people))")
                }
                Logger.shared.warning("Saving people.json dropped hand-added key(s) it could not "
                                      + "re-attach: \(lost.joined(separator: "; ")) — the roster "
                                      + "was saved")
            }
            // Atomic: the engine reads this file at launch and the fingerprint hashes it, so a
            // torn write would be half a household that looks whole.
            try data.write(to: fileURL, options: .atomic)
            // Only now do the bytes on disk match this roster, which anything hashing the file
            // must wait for (`savedRevision`).
            savedRevision &+= 1
            // And only now is the file the roster of record. Set here, not by callers, so a
            // refused save can't leave the list claiming "saved in people.json" beside a banner
            // saying edits won't be saved. Guarded because `source` is `@Published`: reassigning
            // the same value would wake every observer on each save.
            if source != .file { source = .file }
        } catch {
            Logger.shared.warning("Couldn't save people.json — the change is in memory only "
                                  + "this session: \(error.localizedDescription)")
        }
    }

    /// Puts the carried keys back into freshly encoded JSON.
    ///
    /// Returns nil rather than throwing, and the caller then writes the unmerged bytes: the roster
    /// is what the file is for, and losing an edit because a comment couldn't be re-attached would
    /// be the worse trade.
    ///
    /// The modelled keys win by construction (`carriedKeys` never holds them), so a stale `people`
    /// array read at launch can't overwrite the roster being saved.
    private static func merging(_ carried: [String: Any], perPerson: [String: [String: Any]],
                                into encoded: Data) -> Data? {
        guard !carried.isEmpty || !perPerson.isEmpty,
              var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return nil }
        object.merge(carried) { fresh, _ in fresh }
        // The per-record half, at the depth it was read from. Driven by the encoded array, not the
        // carried map, so a person removed this session isn't put back by the merge.
        if !perPerson.isEmpty, let records = object["people"] as? [[String: Any]] {
            object["people"] = records.map { record -> [String: Any] in
                guard let id = record["id"] as? String, let extras = perPerson[id] else { return record }
                // `fresh` wins on a collision, as at the top level: a key this build models is its
                // to write, and the carried copy would pin a value the UI can no longer change.
                return record.merging(extras) { fresh, _ in fresh }
            }
        }
        // `.sortedKeys` so the file stays diffable, matching what the encoder above produces.
        return try? JSONSerialization.data(withJSONObject: object,
                                           options: [.prettyPrinted, .sortedKeys,
                                                     .withoutEscapingSlashes])
    }

    // MARK: - Helpers

    /// An id no one else in the roster holds. Two people can share a first name, so a numeric
    /// suffix is appended rather than letting the second take over the first's folders.
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

    /// Trimmed, de-duplicated case-insensitively, blanks dropped, order kept: the user's typing
    /// order is the order they'll look for it in.
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
