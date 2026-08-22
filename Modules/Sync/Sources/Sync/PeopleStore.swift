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

    /// Where the roster was read from and is written to — the profiles directory and the FOLDER
    /// inside it, both as handed over at construction.
    ///
    /// **Internal, and the pair is the point.** `FilingArtifacts.attach` builds this store from
    /// `loaded.id` — the folder the artifacts were actually read from — rather than from
    /// `profile.profileId`, the field inside `folder-profile.json`, because the two can disagree
    /// and when they do "the writes went where nothing reads". Anything re-deriving state from the
    /// bytes this store just wrote has to ask the same pair rather than re-deriving the id from
    /// the profile, which is how `FileSyncManager.refreshFilingArtifactFingerprint` came to digest
    /// a folder holding no artifacts at all.
    let directory: URL
    let profileId: String
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
        carriedPersonKeys = Self.unmodelledPersonKeys(at: fileURL)
        rosterIsUnreadable = Self.rosterIsUnreadable(at: fileURL, loaded: loaded,
                                                     fileManager: fileManager)
        if rosterIsUnreadable {
            // The store is built once per launch, so this state lasts the session: fixing the file
            // now does not re-read it. Say so, rather than implying an edit will start working.
            Logger.shared.warning("people.json exists but could not be read — showing the roster "
                                  + "seeded from folder names, and REFUSING to write over the file. "
                                  + "Fix \(fileURL.path) and relaunch to edit the household again.")
        }
        repeatedRosterIds = source == .file ? loaded.repeatedIds : []
        Self.warnAboutRepeatedIds(loaded.repeatedIds, source: source, fileURL: fileURL)
    }

    /// Says once, at load, that the roster on disk repeats a person id.
    ///
    /// **The id is the roster's primary key everywhere except in the file itself**, and a hand-edit
    /// that repeats one used to be tolerated by every consumer in a *different* way rather than
    /// rejected by any of them. ``PersonRegistry`` now settles it in one place — one record per id,
    /// the last one listed — so the readings no longer disagree; what does not change is that the
    /// user's file still says something they did not mean, and the record they typed second is the
    /// only one in effect. Copying a person to add a spelling and forgetting to change the `id` is
    /// exactly how that happens.
    ///
    /// **Taken from the registry rather than counted here.** The obvious version scanned the
    /// roster this store had just been handed — which is the roster *after* the collapse, so it
    /// found no repeats and said nothing, turning a warning into silence at the same moment the
    /// app started discarding a record. Its own test caught that. `repeatedIds` is read off the
    /// raw list before the collapse, which is the only place the answer still exists.
    ///
    /// One line, at load, rather than one per consumer: the fact is about the file, and the
    /// consumers are only where it shows up. Said only for a roster that really came from
    /// `people.json` — a seeded registry is the app's own reading of folder names, so pointing the
    /// user at a file they never wrote would be wrong.
    private static func warnAboutRepeatedIds(_ repeated: [String], source: PersonRegistry.Source,
                                             fileURL: URL) {
        guard source == .file, !repeated.isEmpty else { return }
        Logger.shared.warning("people.json repeats the person id(s) "
                              + "\(repeated.joined(separator: ", ")) — only the LAST entry for a "
                              + "repeated id is kept, and the earlier ones are dropped: the names "
                              + "they listed will not resolve to that person. Give each person a "
                              + "unique id in \(fileURL.path).")
    }

    /// True when `people.json` holds **structured data this build could not decode** — a hand-edit
    /// that broke one `Person` entry, or a schema a newer build wrote — or when the file **exists
    /// but could not be read at all**: mode 000, an ACL, an I/O error, a symlink whose target is
    /// on a volume that is not mounted.
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
    /// understand, and rewriting it is the loss this flag exists to prevent. A file whose bytes
    /// could not be fetched at all sits on the protected side of that line, because the question
    /// "is there content to lose?" cannot be answered without them — and the failure that blocked
    /// the read rarely blocks the write, since an atomic save needs only directory permission.
    @Published public private(set) var rosterIsUnreadable = false

    /// Ids `people.json` listed more than once, sorted and unique — empty for every ordinary roster.
    ///
    /// **This is a second reason not to rewrite the file, and it needed one of its own.**
    /// ``rosterIsUnreadable`` asks "did this decode", which is the right question for a typo and the
    /// wrong one here: a person block copy-pasted without changing its `id` decodes perfectly. The
    /// registry then collapses it to one record — it has to, or an id names four different people
    /// depending on which reader you ask — and `people` above becomes a roster with one of the
    /// user's records missing. Writing that back is a deletion they never asked for, triggered by
    /// an edit to anybody, and invisible: unmodelled keys are carried faithfully, so the rewritten
    /// file looks intact.
    ///
    /// Only for a roster that came from the file. A seeded registry is the app's own reading of
    /// folder names and there is nothing of the user's to protect.
    @Published public private(set) var repeatedRosterIds: [String] = []

    /// Whether this session may write `people.json` at all, and why not when it may not.
    ///
    /// Two independent reasons, deliberately kept apart in the UI: one says the roster on screen is
    /// a guess, the other says it is real but incomplete. Both mean the same thing for `save()`.
    public var rosterIsReadOnly: Bool { rosterIsUnreadable || !repeatedRosterIds.isEmpty }

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
    ///
    /// **Every successful write, including ones that cannot move a classification.** An earlier
    /// version of this split the counter in two so that `dismissSuggestion` would not re-derive the
    /// filing artifact fingerprint (which keys `FilingVerdictCache`, so refreshing it re-bills a
    /// paid pass). That was the wrong layer and it was worse than the problem: the fingerprint is
    /// recomputed from disk at every launch and re-survey anyway, so the re-bill was only deferred
    /// — and in the meantime verdicts were recorded against a digest that no longer described the
    /// file and could never be reproduced, which makes them permanently unreachable.
    ///
    /// The fingerprint now hashes only the part of `people.json` that can change an answer (see
    /// ``FilingProfileStore/classifyingBytes(ofPeople:)``), so a dismissal produces the same digest
    /// and this counter can go back to meaning exactly what it says.
    @Published public private(set) var savedRevision: Int = 0

    /// Decides the above from three independent facts: did the registry come from the file
    /// (`source` is `.file` only on a successful decode), could the file be read at all, and is
    /// there JSON in it.
    private static func rosterIsUnreadable(at url: URL, loaded: PersonRegistry,
                                           fileManager: FileManager) -> Bool {
        guard loaded.source != .file else { return false }        // decoded, nothing to protect from
        guard let data = fileManager.contents(atPath: url.path) else {
            // **"Absent" and "there but unreadable" are different answers**, and a nil here alone
            // conflates them. A `people.json` that exists and cannot be opened — mode 000, an ACL,
            // an I/O error — would otherwise look like a fresh profile, and `save()`'s atomic
            // rename needs permission on the *directory* rather than the file, so the first edit
            // would succeed exactly where this read failed and replace the household with the seed.
            // `attributesOfItem` rather than `fileExists`, because only the former sees a symlink
            // that does not resolve: `fileExists` follows links and answers false for one whose
            // target is on an unmounted volume — and the atomic write then replaces the link
            // itself. The is-it-JSON line below cannot run without the bytes, so whatever is here
            // is protected without it: unreadable contents cannot be shown to hold no roster.
            return (try? fileManager.attributesOfItem(atPath: url.path)) != nil
        }
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
    /// missing", it is "this build rewrote a file it had only partly understood".
    ///
    /// **Top-level only — see ``carriedPersonKeys`` for the keys INSIDE a person record.** This
    /// used to close by saying "a key added by a newer build, or by him in a text editor, survives
    /// a round trip through this one", unqualified, which was true of `_note` beside `people` and
    /// false of anything written on a person. The two need separate machinery because they are
    /// merged back at different depths.
    private var carriedKeys: [String: Any] = [:]

    /// Unmodelled keys found INSIDE each person record, by person id.
    ///
    /// **The same failure as ``carriedKeys``, one level down, and the top-level carry cannot see
    /// it.** `Person` models exactly five keys (``Person/modelledKeys``) and its `init(from:)`
    /// ignores everything else, so a `"nickname"` — added by a newer build, or typed into the file
    /// by hand next to the person it describes — decodes to nothing, is absent from the re-encoded
    /// record, and is gone from disk the first time anybody edits anybody. Silently: the file it
    /// leaves behind is well-formed and looks complete.
    ///
    /// Keyed by id because id is the roster's primary key everywhere. Three consequences, all
    /// deliberate: a person deleted from the roster takes their carried keys with them rather than
    /// being resurrected by the merge; a person whose id is changed loses them, which is the same
    /// thing that happens to every other per-person fact keyed on id; and a repeated id never
    /// reaches here, because ``save()`` refuses to write at all in that state.
    private var carriedPersonKeys: [String: [String: Any]] = [:]

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

    /// The keys inside each person record that this build has no field for, by person id.
    ///
    /// Read from the bytes for the same reason ``unmodelledKeys(at:)`` is: a `Decodable` that
    /// ignores unknown keys is exactly what cannot report them. A record with no id is skipped
    /// rather than carried under a placeholder — it cannot be matched back to anything on write,
    /// and `PersonRegistry` drops it on load too, so carrying it would mean re-attaching keys to a
    /// record that is not in the file any more.
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

    /// A store with no file behind it, for tests and previews — edits stay in memory.
    public init(people: [Person]) {
        self.directory = URL(fileURLWithPath: "/dev/null")
        self.profileId = ""
        self.fileManager = .default
        self.people = people
        self.source = .file
    }

    /// False for the in-memory store — there is no file behind it, so nothing it does can
    /// change anything on disk.
    var isPersistent: Bool { !profileId.isEmpty }

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
        let before = savedRevision
        save()
        // "again" is a claim about the next launch, and `save()` refuses outright when the roster
        // on disk is one this build could not read. Said only when the write actually landed —
        // the in-memory dismissal still holds for this session, and the sentence now says which.
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
        // **A file this build REINTERPRETED is also a file it must not rewrite**, and this one gets
        // past the guard above because it decodes perfectly. A person block copy-pasted without
        // changing its `id` is collapsed to one record on load — it has to be, or the id names a
        // different person depending on which reader is asked — so `people` here is the household
        // minus a record the user typed. The write below is whole-file: it would delete that record
        // from disk, triggered by an edit to ANYBODY, and leave no trace, since the unmodelled keys
        // are carried faithfully and the result looks intact.
        //
        // Worse, the load-time warning tells them to go and give each person a unique id. If the
        // first edit has already run, the record they need in order to decide is gone, and nothing
        // warns again, because the file is now clean.
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
                                                                     : dismissedSuggestions.sorted()))
            if let merged = Self.merging(carriedKeys, perPerson: carriedPersonKeys, into: data) {
                data = merged
            } else if !carriedKeys.isEmpty {
                // **The loss is said, even though the write proceeds.** Writing the unmerged bytes
                // is the deliberate trade (see `merging`) — the roster is what this file is for —
                // but the whole carried-keys mechanism exists *because* silently dropping a
                // hand-written `_note` from people.json was a defect once. Nil is also the
                // ordinary "nothing to carry" case, which is lossless and must stay quiet; only
                // the case that actually drops something speaks.
                Logger.shared.warning("Saving people.json dropped \(carriedKeys.count) hand-added "
                                      + "key(s) it could not re-attach "
                                      + "(\(carriedKeys.keys.sorted().joined(separator: ", "))) — "
                                      + "the roster was saved")
            }
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
            //
            // Guarded because `source` is `@Published` and this runs on every save: assigning the
            // value it already holds would announce a change on each edit, waking every observer
            // of the store for nothing.
            if source != .file { source = .file }
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
    private static func merging(_ carried: [String: Any], perPerson: [String: [String: Any]],
                                into encoded: Data) -> Data? {
        guard !carried.isEmpty || !perPerson.isEmpty,
              var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { return nil }
        object.merge(carried) { fresh, _ in fresh }
        // The per-record half, merged at the depth it was read from. Driven by the ENCODED array
        // rather than by the carried map, so a person removed from the roster this session is
        // simply not here to merge into — their keys go with them, instead of the merge putting a
        // record back that the user just deleted.
        if !perPerson.isEmpty, let records = object["people"] as? [[String: Any]] {
            object["people"] = records.map { record -> [String: Any] in
                guard let id = record["id"] as? String, let extras = perPerson[id] else { return record }
                // `fresh` wins on a collision, exactly as at the top level: a key this build now
                // models is this build's to write, and preferring the carried copy would pin a
                // value the user can no longer change from the UI.
                return record.merging(extras) { fresh, _ in fresh }
            }
        }
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
