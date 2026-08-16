import CryptoKit
import Events
import Foundation

/// Reads the per-tree filing artifacts: a ``FolderProfile`` and its ``FilingMemory``.
///
/// One store rather than two, because they are two halves of one description of one tree and are
/// keyed identically — `profiles/<id>/folder-profile.json` and `profiles/<id>/filing-memory.json`,
/// with `profiles.json` naming the active id. Keying by id is what makes a second tree *additive*:
/// nothing about one person's conventions can overwrite another's.
///
/// **Read-only, deliberately.** These artifacts are produced by a survey of the tree, not by the
/// app's normal operation, and a partial rewrite from a half-finished scan would be worse than no
/// profile at all. Every failure yields nil, which restores exactly the behaviour the app had before
/// any of this existed.
///
/// The memory is now also *re-derivable* in the app — see ``FilingSurveyStore``, which owns the only
/// write path and takes the rule above as its constraint rather than an exception to it: a complete
/// rebuild, written atomically, and only when it differs from what is there.
///
/// **The profile now has exactly one write path — ``writeProfile(_:in:builtBy:now:)`` — and it is
/// built to take the paragraph above as a constraint rather than to soften it.** It exists for one
/// state only: a machine with no profile at all, where the app can otherwise offer nothing (see
/// `ROADMAP_V4.md` §4.2). It **refuses over an existing `folder-profile.json`** rather than merging
/// or replacing — a name-only profile landing on top of a hand-built one would degrade To File and
/// Renames with nothing failing — it writes atomically so the file on disk is only ever a whole
/// profile, and it points `profiles.json` at the new id **only when nothing is active**, so it can
/// never re-aim a tree that already has an answer.
public enum FilingProfileStore {

    /// Bumped when either artifact's shape changes; a foreign schema is discarded rather than
    /// migrated, for the same reason as the other stores — the contents are a re-survey away.
    public static let currentSchema = 1

    /// `~/Library/Application Support/SyncCloud/profiles`. Injected by the app, never defaulted
    /// inside `Sync` — same rule as the verdict cache, the hash index and the Storage Lens store:
    /// library code must not reach into the real home directory just because nobody said otherwise.
    public static func defaultDirectory(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/profiles")
    }

    private struct Index: Decodable {
        let schemaVersion: Int?
        let activeProfileId: String?
    }

    /// The profile id `profiles.json` names as active, or nil when there is no index.
    public static func activeProfileId(in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: indexURL(in: directory)),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        guard index.schemaVersion ?? currentSchema == currentSchema else {
            Logger.shared.warning("Filing profile index has an unknown schema — ignoring it")
            return nil
        }
        return index.activeProfileId
    }

    public static func profileURL(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id)/folder-profile.json")
    }

    public static func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("profiles.json")
    }

    /// The folder profile for `id`, or nil when absent or unreadable.
    public static func profile(id: String, in directory: URL) -> FolderProfile? {
        decode(FolderProfile.self, at: profileURL(id: id, in: directory), what: "folder profile")
    }

    /// The filing memory for `id`, or nil when absent or unreadable.
    ///
    /// A missing memory is an ordinary state, not a fault: the profile alone still routes, just less
    /// well, and a tree that has never been surveyed for content has nothing to remember.
    public static func memory(id: String, in directory: URL) -> FilingMemory? {
        decode(FilingMemory.self, at: directory.appendingPathComponent("\(id)/filing-memory.json"),
               what: "filing memory")
    }

    private struct PeopleFile: Decodable {
        let schemaVersion: Int?
        let people: [Person]
        /// Suggested name forms the user has rejected. Absent in a file written before the
        /// learning loop existed, which reads as "nothing rejected yet".
        let notNames: [String]?
    }

    /// The household for `id` — `people.json` when it exists, else a registry seeded from the
    /// profile's own person axis.
    ///
    /// The seed is not a degraded mode: it carries the alias map the profile already records, so
    /// even a tree with no `people.json` gets `Mom` and `Muktha` resolved to one person. What the
    /// file adds is what a survey cannot know — the *full names* documents print, which is what
    /// makes "Aditi Abhishek" attributable to Aditi rather than to two people.
    /// `profile` is optional so a roster can be read on a machine with no survey at all — the file
    /// is the user's, and it does not stop being readable because nothing has scanned their tree.
    public static func personRegistry(id: String, profile: FolderProfile?, in directory: URL) -> PersonRegistry {
        if let file = decode(PeopleFile.self, at: directory.appendingPathComponent("\(id)/people.json"),
                             what: "people registry") {
            return PersonRegistry(people: file.people)
        }
        guard let profile else { return PersonRegistry(people: [], source: .profileAxis) }
        return PersonRegistry.seeded(from: profile)
    }

    /// The name suggestions this profile has already rejected.
    public static func dismissedNameSuggestions(id: String, in directory: URL) -> Set<String> {
        let file = decode(PeopleFile.self, at: directory.appendingPathComponent("\(id)/people.json"),
                          what: "people registry")
        return Set(file?.notNames ?? [])
    }

    /// All artifacts for the active profile, when there is one.
    public static func active(in directory: URL)
        -> (profile: FolderProfile, memory: FilingMemory?, registry: PersonRegistry)? {
        guard let id = activeProfileId(in: directory), let profile = profile(id: id, in: directory) else {
            return nil
        }
        return (profile, memory(id: id, in: directory),
                personRegistry(id: id, profile: profile, in: directory))
    }

    private struct SchemaProbe: Decodable { let schemaVersion: Int? }

    /// A short digest of the artifact FILES on disk, or "" when neither is present.
    ///
    /// **The artifacts are part of the question the backend is asked**, and nothing in
    /// ``FilingVerdictKey`` used to say so. They decide the router's shortlist, the shortlist is the
    /// classifier's folder menu, and a re-survey therefore changes what every file is asked about —
    /// while the cache, keyed on the file and the prompt version, replays the answer to the old
    /// question. Installing a freshly generated profile logged `reused 14 of 14 classification(s)
    /// from cache, 0 sent to the backend`: the re-survey had no effect at all until the cache file
    /// was deleted by hand.
    ///
    /// Hashed from the bytes rather than derived from a field like the memory's salt, so it also
    /// moves when a profile is regenerated without the memory being rebuilt. One SHA-256 of a few
    /// megabytes, once per load, at launch.
    public static func fingerprint(id: String, in directory: URL) -> String {
        var hasher = SHA256()
        var any = false
        // `people.json` is part of the question too: the registry decides the person veto and the
        // person axis bonus, both of which move the shortlist the classifier is handed.
        for name in ["folder-profile.json", "filing-memory.json", "people.json"] {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id)/\(name)"))
            else { continue }
            any = true
            hasher.update(data: name == "people.json" ? classifyingBytes(ofPeople: data) : data)
        }
        guard any else { return "" }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The part of `people.json` that can actually change a classification: the roster, and the
    /// schema that says how to read it.
    ///
    /// **Hashing the whole file made things that cannot move an answer cost money.** The file also
    /// carries `notNames` — the name suggestions the user has declined, which feed nothing but the
    /// suggestion list — and any keys a future build or the user's own editor left in it (a
    /// `_note`, a comment). Every one of those changed the digest, and the digest keys
    /// `FilingVerdictCache`: declining a suggested spelling, or adding a note to the file, invalidated
    /// every cached verdict and re-billed a full paid re-classification for something the engine
    /// cannot even see.
    ///
    /// Re-serialised canonically rather than hashed as written, so whitespace and key order in a
    /// hand-edited file do not move it either. Falls back to the raw bytes when the file is not
    /// JSON this can read — the conservative direction: an unreadable roster invalidates, rather
    /// than silently serving answers composed against a household this could not parse.
    static func classifyingBytes(ofPeople data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return data }
        var classifying: [String: Any] = [:]
        for key in ["schemaVersion", "people"] where object[key] != nil {
            classifying[key] = object[key]
        }
        guard let canonical = try? JSONSerialization.data(withJSONObject: classifying,
                                                          options: [.sortedKeys])
        else { return data }
        return canonical
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL, what: String) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // The artifacts carry their own version, and until now only `profiles.json`'s was read —
        // so a future shape would have been decoded field-by-field into a half-empty value and
        // used, which is the silent-wrong-answer failure this store exists to avoid.
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
           let v = probe.schemaVersion, v != currentSchema {
            Logger.shared.warning("The \(what) at \(url.lastPathComponent) is schema \(v), not "
                                  + "\(currentSchema) — ignoring it rather than half-reading it")
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Naming the file matters here: these are hand-generated artifacts, so "it silently did
            // nothing" is a real support question and the answer is almost always a malformed one.
            Logger.shared.warning("Couldn't read the \(what) at \(url.lastPathComponent) — "
                                  + "filing will fall back to folder names: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - The one write path

extension FilingProfileStore {

    /// Why a profile write was refused. **Refusal is the interesting outcome**, so it is a typed
    /// error rather than a `Bool` or a swallowed log: the caller has promised the user a survey and
    /// has to be able to say *this tree already has a profile and I did not touch it* — which is a
    /// different sentence from *the write failed*.
    public enum WriteRefusal: Error, Equatable, CustomStringConvertible {
        /// `folder-profile.json` already exists for this id. Never overwritten, never merged.
        case profileExists(id: String)
        /// `profiles.json` is present but not something this can safely amend (not a JSON object,
        /// or a schema this build does not know). Refused rather than replaced: an index this
        /// cannot read is still the user's, and it names profiles a clobber would orphan.
        case indexUnreadable(String)
        /// A profile id that cannot be a directory name. It is interpolated into a path, so an
        /// empty or separator-bearing id is refused at the door rather than writing somewhere
        /// surprising.
        case invalidProfileId(String)

        public var description: String {
            switch self {
            case .profileExists(let id):
                return "a folder profile already exists for \(id) — refusing to overwrite it"
            case .indexUnreadable(let why):
                return "profiles.json cannot be safely amended (\(why)) — refusing to replace it"
            case .invalidProfileId(let id):
                return "\(id.isEmpty ? "an empty profile id" : "profile id \"\(id)\"") cannot name a directory"
            }
        }
    }

    /// Writes `profile` as `profiles/<id>/folder-profile.json`, creating the directory if needed,
    /// and points `profiles.json` at it **only when no profile is active**.
    ///
    /// Four guarantees, each of which is a separate test:
    ///
    /// 1. **It refuses over an existing profile** — `WriteRefusal.profileExists`, with the bytes on
    ///    disk untouched. `ROADMAP_V4.md` §4.2: "A name-only profile must never land on top of a
    ///    hand-built one — it would degrade To File and Renames with nothing failing." There is
    ///    deliberately no `overwrite:` parameter; a caller that wants to replace a profile has to
    ///    move the old file itself, in the open.
    /// 2. **It writes atomically**, so the file is only ever a whole profile — the same rule
    ///    ``FilingSurveyStore`` takes for the memory.
    /// 3. **It touches `profiles.json` only when ``activeProfileId(in:)`` is nil**, and amends the
    ///    existing document rather than rewriting it, so a hand-built index keeps every field and
    ///    every other profile it lists.
    /// 4. **The JSON is the shape the offline generator writes**, so a profile made here and one
    ///    made there are interchangeable — same `schemaVersion` (checked on the way back in by
    ///    ``decode(_:at:what:)``), same `folders` array, same `axes.person` box. Round-tripping
    ///    through ``profile(id:in:)`` is what pins that.
    ///
    /// The header fields (`generated`, `builtBy`, `note`) exist for the same reason
    /// ``FilingSurveyStore``'s do: these artifacts get opened by hand when a suggestion looks
    /// wrong, and one that does not say what made it is one nobody can audit. `builtBy` is how a
    /// reader tells a name-only survey from the full offline one.
    ///
    /// - Returns: the URL written.
    @discardableResult
    public static func writeProfile(_ profile: FolderProfile, in directory: URL,
                                    builtBy: String = "SyncCloud — in-app folder survey",
                                    now: Date = Date()) throws -> URL {
        let id = profile.profileId
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WriteRefusal.invalidProfileId(id)
        }
        let url = profileURL(id: id, in: directory)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            Logger.shared.warning("A folder profile already exists for \(id) — the survey was not "
                                  + "written. A generated profile never replaces one on disk.")
            throw WriteRefusal.profileExists(id: id)
        }

        // The index is composed BEFORE the profile lands, so a `profiles.json` this cannot amend
        // refuses the whole write rather than leaving a profile on disk that the next attempt
        // would then refuse to replace. Only when nothing is active: re-pointing an index that
        // already names a profile would aim every read at a tree the user did not choose — the
        // same class of harm as the overwrite above, one file over.
        //
        // **Read once.** The decision and the amendment are taken from the SAME parse, because
        // taking them from two different ones is a hole rather than a redundancy: the decision used
        // to come from ``activeProfileId(in:)``, whose `JSONDecoder` returns nil for anything it
        // cannot decode, while the amendment re-read the file with the far more permissive
        // `JSONSerialization`. A `"schemaVersion": "1"` — a routine hand-edit slip — read as "no
        // index here" to the first and as a perfectly good index to the second, so an index that
        // named an active profile got silently re-pointed at this survey.
        let reading = try indexForAmending(in: directory)
        let index = reading.activeProfileId == nil
            ? try amendedIndex(from: reading, naming: profile, now: now) : nil

        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let document = ProfileDocument(profile: profile, generated: stamp(now), builtBy: builtBy)
        try encoder.encode(document).write(to: url, options: .atomic)

        if let index {
            do {
                try index.write(to: indexURL(in: directory), options: .atomic)
            } catch {
                // The profile landed and the index did not. Left alone that is the worst of the
                // three possible states: nothing points at the new profile, AND every retry now
                // throws `profileExists` — whose contract tells the caller "this tree already has a
                // profile and I did not touch it", which would be false. So undo the half that
                // succeeded and let the next attempt simply run. Only ever the file this call
                // created, which the guard above proved was not there. Best-effort by design: if
                // the removal fails too, the write error is still the one worth reporting.
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
        return url
    }

    /// What `profiles.json` holds right now, parsed once for both of the questions the write path
    /// asks of it: *may this be amended at all*, and *does it already name an active profile*.
    private struct IndexReading {
        /// The parsed document, or nil when there is no index file yet.
        let object: [String: Any]?
        /// The id the index names active, when it names a usable one.
        let activeProfileId: String?
    }

    /// Reads `profiles.json` for amendment, **refusing anything it cannot fully account for**.
    ///
    /// Deliberately stricter than ``activeProfileId(in:)``, and the asymmetry is the point. A
    /// *reader* that cannot understand the index degrades to "no active profile" and the app carries
    /// on; a *writer* that cannot understand it has to stop, because the fields it would be
    /// overwriting are the ones it just failed to read. A malformed field is therefore a refusal
    /// here and an absence there.
    private static func indexForAmending(in directory: URL) throws -> IndexReading {
        guard let data = try? Data(contentsOf: indexURL(in: directory)) else {
            return IndexReading(object: nil, activeProfileId: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WriteRefusal.indexUnreadable("it is not a JSON object")
        }
        // A schema this build does not know is refused — including one that is not a number at all,
        // which the old check skipped entirely by asking `as? Int` and moving on when it was nil.
        if let version = object["schemaVersion"], !(version is NSNull) {
            guard let number = version as? Int else {
                throw WriteRefusal.indexUnreadable("schemaVersion is not a number")
            }
            guard number == currentSchema else {
                throw WriteRefusal.indexUnreadable("schema \(number), not \(currentSchema)")
            }
        }
        // The field that decides whether anything may be re-pointed gets the same treatment: an
        // `activeProfileId` that is present but not a string is an index this does not understand,
        // not an index with nothing active.
        var active: String?
        if let raw = object["activeProfileId"], !(raw is NSNull) {
            guard let id = raw as? String else {
                throw WriteRefusal.indexUnreadable("activeProfileId is not a string")
            }
            active = id.isEmpty ? nil : id
        }
        return IndexReading(object: object, activeProfileId: active)
    }

    /// `profiles.json`'s bytes with `profile` named active, preserving everything already in it.
    private static func amendedIndex(from reading: IndexReading, naming profile: FolderProfile,
                                     now: Date) throws -> Data {
        var object = reading.object ?? [:]
        object["schemaVersion"] = currentSchema
        // A `profiles` field that is not a list of objects is refused rather than replaced. It used
        // to be read as `as? [[String: Any]] ?? []`, so an object-keyed or otherwise unexpected
        // list quietly became an empty one and the rewrite dropped every profile the index named —
        // the exact clobber ``WriteRefusal/indexUnreadable`` says it exists to prevent.
        var profiles: [[String: Any]] = []
        if let raw = object["profiles"], !(raw is NSNull) {
            guard let listed = raw as? [[String: Any]] else {
                throw WriteRefusal.indexUnreadable("profiles is not a list of objects")
            }
            profiles = listed
        }
        if !profiles.contains(where: { $0["profileId"] as? String == profile.profileId }) {
            // No `displayName`: the offline generator writes the person's name, and a folder walk
            // does not know it. An absent field reads as "unknown"; a guessed one reads as a fact.
            profiles.append(["profileId": profile.profileId, "root": profile.root,
                             "portable": false, "generatedAt": stamp(now),
                             "surveyedFolders": profile.folders.count])
        }
        object["profiles"] = profiles
        object["activeProfileId"] = profile.profileId
        return try JSONSerialization.data(withJSONObject: object,
                                          options: [.sortedKeys, .prettyPrinted])
    }

    /// The instant both filing artifacts date themselves with — see ``FilingArtifactStamp``.
    /// `now` is injected by the caller — `docs/flaky-tests.md` mechanism 5.
    static func stamp(_ date: Date) -> String { FilingArtifactStamp.string(from: date) }

    /// The on-disk shape, header and all. Mirrors ``FolderProfile``'s decoder field for field —
    /// `folders` as an array (the decoder keys it by `path`), the person axis as a
    /// `values` + `aliases` box — because decoding is the only contract between the Python builder
    /// and this module, and a profile written here has to satisfy the same one.
    struct ProfileDocument: Encodable {
        let profile: FolderProfile
        let generated: String
        let builtBy: String

        /// What the file says about itself, for the person who opens it because a suggestion looked
        /// wrong. **It has to describe what the builder actually produced**, which is why it no
        /// longer claims `anchors` and `axes` are empty: they are derived and populated, and a
        /// reader who believed otherwise would go looking for the cause of a bad suggestion in the
        /// wrong file. Only `naming` is genuinely abstained from.
        static let note = """
            What each folder IS — role, axes, naming convention, and whether it may receive files. \
            Companion to filing-memory.json, which records what a folder has RECEIVED. A profile \
            written by the app's own survey is derived from folder and file NAMES alone — it opens \
            no documents — so role, anchors, axes and counts are present and measured, while \
            `naming` is left empty rather than guessed: a wrong convention would have the rename \
            pass propose renames toward one nobody has. What a walk cannot see at all, and what \
            this file therefore never carries, is folderSemantics and the jurisdiction vocabulary.
            """

        enum Key: String, CodingKey {
            case schemaVersion, profileId, portable, generated, root, note, builtBy
            case folderCount, axes, folders
        }

        /// The `axes.person` shape ``FolderProfile``'s decoder reads: a `values` list plus the
        /// alias pairs, which are what let `Family/Mom` and `Muktha` resolve to one person.
        struct PersonAxisBox: Encodable {
            let values: [String]
            let aliases: [String: String]
        }

        struct EntryBox: Encodable {
            let entry: FolderProfileEntry
            enum Key: String, CodingKey {
                case path, role, naming, anchors, acceptsNewFiles, fileCount, subfolderCount, axes
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(entry.path, forKey: .path)
                try c.encodeIfPresent(entry.role?.rawValue, forKey: .role)
                try c.encodeIfPresent(entry.naming, forKey: .naming)
                try c.encode(entry.anchors, forKey: .anchors)
                // Omitted when nil, as the generator omits it: only an explicit `false` forbids
                // filing, and `null` and absent mean the same thing to the decoder.
                try c.encodeIfPresent(entry.acceptsNewFiles, forKey: .acceptsNewFiles)
                try c.encode(entry.fileCount, forKey: .fileCount)
                try c.encode(entry.subfolderCount, forKey: .subfolderCount)
                try c.encode(entry.axes, forKey: .axes)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(FilingProfileStore.currentSchema, forKey: .schemaVersion)
            try c.encode(profile.profileId, forKey: .profileId)
            try c.encode(false, forKey: .portable)
            try c.encode(generated, forKey: .generated)
            try c.encode(profile.root, forKey: .root)
            try c.encode(builtBy, forKey: .builtBy)
            try c.encode(ProfileDocument.note, forKey: .note)
            try c.encode(profile.folders.count, forKey: .folderCount)
            // Written only when there is one: an empty person axis and no axis at all decode
            // identically, and a `{"person":{"values":[]}}` box claims a survey looked and found
            // nobody, which a name-only survey did not do.
            if !profile.personTokens.isEmpty || !profile.personAliases.isEmpty {
                try c.encode(["person": PersonAxisBox(values: profile.personTokens.sorted(),
                                                      aliases: profile.personAliases)],
                             forKey: .axes)
            }
            // Sorted by path so the bytes are a function of the profile alone — a file that
            // reshuffles on every write is one nobody can diff, and its hash feeds
            // `fingerprint(id:in:)`, which keys every cached classification.
            try c.encode(profile.folders.values.sorted { $0.path < $1.path }.map(EntryBox.init),
                         forKey: .folders)
        }
    }
}
