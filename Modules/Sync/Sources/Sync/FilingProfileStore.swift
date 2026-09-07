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
/// `ROADMAP_V5.md` §4.2). It **refuses over an existing `folder-profile.json`** rather than merging
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
    ///
    /// **What the decode salvaged is reported here, once.** A `role` this build has no case for
    /// costs that folder its role rather than taking the whole profile — and with it the filing
    /// layer — down; a folder demoted that way files differently, so the count and the offending
    /// strings belong in the log the user can read. Said at the door rather than from inside the
    /// decoder, which stays a pure function of its bytes.
    public static func profile(id: String, in directory: URL) -> FolderProfile? {
        guard let profile = decode(FolderProfile.self, at: profileURL(id: id, in: directory),
                                   what: "folder profile") else { return nil }
        if !profile.unknownRoles.isEmpty {
            let named = profile.unknownRoles.sorted { $0.key < $1.key }
                .map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
            Logger.shared.warning("Folder profile '\(id)': \(profile.unknownRoles.values.reduce(0, +)) "
                                  + "folder(s) carry a role this build does not know — \(named). They "
                                  + "are read with no role, which is how an unsurveyed folder reads. "
                                  + "A newer SyncCloud will use them.")
        }
        if profile.undecodableFolders > 0 {
            Logger.shared.warning("Folder profile '\(id)': \(profile.undecodableFolders) folder "
                                  + "entry/entries could not be read and were skipped. The rest of "
                                  + "the profile is in use.")
        }
        return profile
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
    /// even a tree with no `people.json` gets `Mom` and `Granny` resolved to one person. What the
    /// file adds is what a survey cannot know — the *full names* documents print, which is what
    /// makes "Daughter Father" attributable to Daughter rather than to two people.
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

    /// All artifacts for the active profile, when there is one — **and the id they were loaded
    /// under**, which is not always the one inside the profile.
    ///
    /// **Identity was read from one place and written from another.** Everything here is read from
    /// `profiles/<activeProfileId>/`, where `activeProfileId` comes from `profiles.json`; the app
    /// then built the roster and tag stores from `profile.profileId`, a field INSIDE the artifact
    /// that decodes to `"default"` when absent. Omit it — which nothing rejects — and reads come
    /// from `work/` while the first roster edit writes to `default/`, where nothing reads it. The
    /// fingerprint hashes the same empty directory, so every cached verdict is keyed against
    /// artifacts not in use. The same split appears on a directory rename, which the docs present
    /// as the way to add a second tree.
    ///
    /// The DIRECTORY is the identity: it is where the file was actually found. The field inside is
    /// informational, and a disagreement is reported rather than silently preferred either way —
    /// it means the generator wrote something inconsistent, and only the log can say so.
    public static func active(in directory: URL)
        -> (id: String, profile: FolderProfile, memory: FilingMemory?, registry: PersonRegistry)? {
        guard let id = activeProfileId(in: directory), let profile = profile(id: id, in: directory) else {
            return nil
        }
        if profile.profileId != id {
            Logger.shared.warning("Filing profile: profiles.json names '\(id)' and the profile in "
                                  + "that folder calls itself '\(profile.profileId)'. The folder "
                                  + "wins — everything is read from and written to '\(id)' — but "
                                  + "the two should agree; fix `profileId` in "
                                  + "\(id)/folder-profile.json.")
        }
        return (id, profile, memory(id: id, in: directory),
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
    ///
    /// **Nil when a component EXISTS but cannot be read — the fingerprint is unavailable, not
    /// silently different.** Skipping an unreadable file minted a digest that can never recur
    /// once the file is fixed, so every paid verdict recorded under it became permanently
    /// unreachable — the exact failure ``PeopleStore/savedRevision``'s doc says must be
    /// prevented. A caller holding nil must neither record a verdict under it nor serve one:
    /// the scan sites treat it like a nil verdict identity, cache off for read and write both.
    /// A genuinely absent component stays ordinary — the others digest without it.
    public static func fingerprint(id: String, in directory: URL) -> String? {
        var hasher = SHA256()
        var any = false
        // `people.json` is part of the question too: the registry decides the person veto and the
        // person axis bonus, both of which move the shortlist the classifier is handed.
        for name in ["folder-profile.json", "filing-memory.json", "people.json"] {
            let url = directory.appendingPathComponent("\(id)/\(name)")
            guard let data = try? Data(contentsOf: url) else {
                // Absent and there-but-unreadable are different answers, as everywhere in this
                // store. `attributesOfItem` rather than `fileExists` so a dangling symlink still
                // counts as present.
                guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                    // **"and relaunch" was not quite true and not quite false, which is worse than
                    // either.** This digest is re-derived on three occasions — at launch, after a
                    // roster save (`FileSyncManager.refreshFilingArtifactFingerprint`), and after a
                    // re-survey writes — so a repaired `folder-profile.json` or
                    // `filing-memory.json` is picked up by the next roster edit without a
                    // relaunch. `people.json` is the exception, and it is the one this line most
                    // often names: an unreadable roster sets `PeopleStore.rosterIsUnreadable` at
                    // construction, which lasts the session, and `save()` refuses while it is set
                    // — so `savedRevision` never bumps, the sink never fires, and that repair
                    // really does wait for a relaunch (pinned by
                    // `PeopleStoreSaveOrderingTests.aRefusedSaveDoesNotBumpTheRevision`).
                    //
                    // **The cost while it stays broken is not only the edits.** The People banner
                    // says edits will not be saved; it does not say that with the fingerprint
                    // unavailable the verdict cache is off for READ as well as write, so every
                    // paid refine re-bills in full and caches nothing. That is the expensive half,
                    // and it is stated here because nothing on screen states it.
                    //
                    // Logged once per CALL rather than once per episode, which is affordable
                    // precisely because of the three occasions above: nothing calls this per file
                    // or per scan.
                    Logger.shared.warning("Filing artifacts: \(name) exists but could not be read "
                                          + "— the artifact fingerprint is unavailable, so no "
                                          + "classification is cached or replayed this session and "
                                          + "every paid pass re-asks in full. Fix \(url.path); it "
                                          + "is re-read at the next launch, and for everything but "
                                          + "people.json as soon as the artifacts are next "
                                          + "written.")
                    return nil
                }
                continue
            }
            any = true
            hasher.update(data: name == "people.json" ? classifyingBytes(ofPeople: data) : data)
        }
        guard any else { return "" }
        return HexEncoding.string(hasher.finalize().prefix(8))
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

    /// Whether something is at `url` that this process could not open — mode 000, an ACL, an I/O
    /// error, a symlink whose target is gone.
    ///
    /// **`attributesOfItem`, never `fileExists`**, for the reason every store in this module now
    /// records and this branch re-measured: `fileExists` follows symlinks and answers false for one
    /// pointing at an unmounted volume, while an atomic write replaces the link itself.
    static func isPresentButUnreadable(at url: URL, fileManager: FileManager = .default) -> Bool {
        (try? Data(contentsOf: url)) == nil
            && (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL, what: String) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            // **Absent and there-but-unreadable both answer nil here, and the callers cannot tell
            // them apart — so the one that WRITES has to ask separately.** Nil is right for the
            // readers (a missing artifact means filing falls back to folder names), and wrong for
            // the re-survey, whose `previousMemory == nil` makes `memory != previousMemory`
            // trivially true and atomically replaces a file it never read. See
            // `resurveyFilingMemory`, which asks `isPresentButUnreadable` before it writes. Saying
            // so here is the least a nil can do.
            if isPresentButUnreadable(at: url) {
                Logger.shared.warning("The \(what) at \(url.path) exists but could not be read — "
                                      + "treated as absent by everything that only READS it. "
                                      + "Nothing is inferred about the tree from it.")
            }
            return nil
        }
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
    ///
    /// **The store throws; the caller logs.** Every refusal below carries its whole sentence in
    /// ``description``, so a `Logger` call beside the `throw` writes the same fact twice — once
    /// where nobody chose the wording and once where the caller does. `profileExists` used to be
    /// the odd one out, logging *and* throwing while its two siblings threw in silence, which is a
    /// worse state than either rule applied consistently: a reader of `~/sync-cloud.log` learned
    /// about one refusal and could reasonably infer the others do not happen. The write path
    /// therefore logs exactly one thing — the rollback in ``land(_:at:index:at:writeIndex:)``,
    /// which is the only fact no thrown error carries (see there). **A caller wiring this up owes
    /// the log line**, and `description` is written to be that line.
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
        /// ``writeDerivedProfile(_:replacing:in:builtBy:now:)``'s own refusal: the id the caller
        /// claims to be replacing is not what `profiles.json` names as active. The unconditional
        /// re-point is licensed by that claim being TRUE — an apply that raced a profile switch
        /// must stop, not re-point away from a profile it never read.
        case notReplacingTheActiveProfile(claimed: String, active: String?)
        /// The derived profile's own file does not chain to the id it claims to replace —
        /// `derivedFrom` is what Undo reads, so a profile that forgot its parent is one that
        /// could never be undone. Distinct from the case above: there the INDEX disagrees with
        /// the caller, here the profile disagrees with itself.
        case chainMissing(derivedFrom: String?, claimed: String)

        public var description: String {
            switch self {
            case .profileExists(let id):
                return "a folder profile already exists for \(id) — refusing to overwrite it"
            case .indexUnreadable(let why):
                return "profiles.json cannot be safely amended (\(why)) — refusing to replace it"
            case .invalidProfileId(let id):
                return "\(id.isEmpty ? "an empty profile id" : "profile id \"\(id)\"") cannot name a directory"
            case .notReplacingTheActiveProfile(let claimed, let active):
                return "the re-derivation claims to replace \(claimed) but the active profile is "
                    + "\(active ?? "none") — refusing to re-point away from a profile it never read"
            case .chainMissing(let derivedFrom, let claimed):
                return "the derived profile's own file names "
                    + (derivedFrom.map { "\($0)" } ?? "no profile") + " as its parent, not "
                    + "\(claimed) — the chain Undo reads must be in the file, so the write is "
                    + "refused"
            }
        }
    }

    /// Whether a freshly written profile may become the active one.
    ///
    /// **Provenance, not existence — this is the rule that changed, and it changed in one
    /// direction.** It used to be "only when nothing is active", which protected a hand-built
    /// profile perfectly and also refused to let the app replace *its own* previous derivation. The
    /// consequence was not theoretical: on a machine with any active profile, a survey ran to
    /// completion, wrote a correct `folder-profile.json` under a fresh id, and then nothing read it,
    /// because `profiles.json` still named the old one and no message said so.
    ///
    /// So: re-point when nothing is active, or when what is active is the app's own work. Never
    /// when it is hand-built — that file also records judgements a walk cannot see (`naming`,
    /// `folderSemantics`, the `outbound-pack` refusals), so aiming the app at a derived profile
    /// instead would quietly degrade To File and the rename pass with nothing failing.
    ///
    /// **An unreadable active profile counts as hand-built**, on the same principle as
    /// ``FolderProfile/provenance``: a file this build cannot parse is one it must not decide it
    /// owns. It refuses to re-point, which leaves the user where they were.
    static func mayRepoint(activeId: String?, in directory: URL) -> Bool {
        guard let activeId else { return true }
        guard let active = profile(id: activeId, in: directory) else { return false }
        return active.provenance == .derived
    }

    /// Writes `profile` as `profiles/<id>/folder-profile.json`, creating the directory if needed,
    /// and points `profiles.json` at it **only when ``mayRepoint(activeId:in:)`` allows it** — that
    /// is, when nothing is active, or when what is active is the app's own derivation.
    ///
    /// Four guarantees, each of which is a separate test:
    ///
    /// 1. **It refuses over an existing profile** — `WriteRefusal.profileExists`, with the bytes on
    ///    disk untouched. `ROADMAP_V5.md` §4.2: "A name-only profile must never land on top of a
    ///    hand-built one — it would degrade To File and Renames with nothing failing." There is
    ///    deliberately no `overwrite:` parameter; a caller that wants to replace a profile has to
    ///    move the old file itself, in the open.
    /// 2. **It writes atomically**, so the file is only ever a whole profile — the same rule
    ///    ``FilingSurveyStore`` takes for the memory. And if the index write that follows fails, the
    ///    profile is removed again: a profile nothing points at is also one every retry would refuse
    ///    with `profileExists`, which is the one state a caller cannot get out of. The empty
    ///    directory is left behind, harmlessly — `createDirectory` does not mind finding it.
    /// 3. **It touches `profiles.json` only when ``mayRepoint(activeId:in:)`` says so** — nothing
    ///    active, or an active profile this app derived — and amends the existing document rather
    ///    than rewriting it, so a hand-built index keeps every field and every other profile it
    ///    lists. "Active" is stricter than ``activeProfileId(in:)``'s answer
    ///    in one direction and looser in another, both deliberately: a field it cannot parse is a
    ///    refusal rather than an absence, while an id naming a profile that is *not on disk* counts
    ///    as nothing active, because a dangling pointer is not an answer and treating it as one left
    ///    the bootstrap permanently dead. Two caveats a reader should not have to discover:
    ///    re-serializing through `JSONSerialization` reformats numbers (`0.1` comes back
    ///    `0.10000000000000001`, `1.0` as `1`) and collapses duplicate keys, so "keeps every field"
    ///    is about content, not bytes; and the read-modify-write is unlocked, so a concurrent edit
    ///    to `profiles.json` between the read and the write is lost.
    ///
    ///    When a **hand-built** profile is active the index is left completely alone, which means
    ///    the profile written here is readable by `profile(id:)` but is not what `active(in:)`
    ///    returns. That is the additive behaviour the id keying intends, not an oversight — but a
    ///    caller that has promised the user a survey has to check, because "written" and "in use"
    ///    are different outcomes and this returns the same URL for both.
    ///    ``FileSyncManager/FolderWalkReport/becameActive`` is that check, and its report says so.
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
            throw WriteRefusal.profileExists(id: id)
        }

        // The index is composed BEFORE the profile lands, so a `profiles.json` this cannot amend
        // refuses the whole write rather than leaving a profile on disk that the next attempt
        // would then refuse to replace. Whether to re-point at all is `mayRepoint`'s: re-pointing
        // an index that names a HAND-BUILT profile would aim every read at a tree the user did not
        // choose — the same class of harm as the overwrite above, one file over — while replacing
        // this app's own previous derivation costs nothing.
        //
        // **Read once.** The decision and the amendment are taken from the SAME parse, because
        // taking them from two different ones is a hole rather than a redundancy: the decision used
        // to come from ``activeProfileId(in:)``, whose `JSONDecoder` returns nil for anything it
        // cannot decode, while the amendment re-read the file with the far more permissive
        // `JSONSerialization`. A `"schemaVersion": "1"` — a routine hand-edit slip — read as "no
        // index here" to the first and as a perfectly good index to the second, so an index that
        // named an active profile got silently re-pointed at this survey.
        let reading = try indexForAmending(in: directory)
        let index = mayRepoint(activeId: reading.activeProfileId, in: directory)
            ? try amendedIndex(from: reading, naming: profile, now: now) : nil

        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // **`.withoutEscapingSlashes` is not cosmetic here — it is what makes the file the docs
        // sell.** Every key in a profile is a folder path, so the default escaping writes
        // `Finance\/US` for every one of them: unreadable at a glance, and it does not diff against
        // the Python builder's output, which is the comparison this format exists to support.
        //
        // Changed while the cost was still nothing: it alters the bytes of any profile written by
        // this path, and at the time that set was empty because `writeProfile` had no production
        // caller. It has one as of v4.2 — `FileSyncManager.deriveFolderProfile` — so this is now
        // the shape every walked profile on disk is in, and changing it again would be a migration.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let document = ProfileDocument(profile: profile, generated: stamp(now), builtBy: builtBy)
        let bytes = try encoder.encode(document)

        // **Re-checked here, immediately before the write.** The guard at the top of this function
        // runs before an index read, a JSON parse, a serialization and a `createDirectory` — that
        // is milliseconds of real I/O, and anything landing a profile at this path inside that
        // window would be overwritten by the atomic write below, which is the one thing this whole
        // path exists to prevent. Narrowing the window to the two adjacent statements is as far as
        // this goes without an exclusive create; `Data.WritingOptions.withoutOverwriting` cannot
        // help, since Foundation traps outright when it is combined with `.atomic`, and `.atomic` is
        // load-bearing (`theProfileIsWrittenAtomically`). A residual race remains and is documented
        // on the guarantee list rather than papered over.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriteRefusal.profileExists(id: id)
        }
        try land(bytes, at: url, index: index, at: indexURL(in: directory))
        return url
    }

    /// Writes a profile re-derived after a Restructure apply, and re-points `profiles.json` at it
    /// — **even away from a hand-built profile**, which `writeProfile` never does (§5.5 step 6).
    ///
    /// The licence for that is provenance, carried in the file: the caller proves it holds the
    /// active profile by naming it in `replacing`, the new profile records it as `derivedFrom`,
    /// and the old file is **never touched** — it is what *Undo this reorganisation* re-points
    /// back to, and it is the last hand-built copy when the chain started from one. The create-only
    /// guard's protection did not weaken; it moved from "never replace what exists" to "never lose
    /// what exists", which is what it was protecting all along.
    @discardableResult
    public static func writeDerivedProfile(_ profile: FolderProfile, replacing oldId: String,
                                           in directory: URL,
                                           builtBy: String = "SyncCloud — restructure re-derivation",
                                           now: Date = Date()) throws -> URL {
        let id = profile.profileId
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WriteRefusal.invalidProfileId(id)
        }
        // The chain must be in the FILE, not only in the caller's intent: derivedFrom is what
        // Undo reads, and a derived profile that forgot its parent is one that cannot be undone.
        guard profile.derivedFrom == oldId else {
            throw WriteRefusal.chainMissing(derivedFrom: profile.derivedFrom, claimed: oldId)
        }
        let url = profileURL(id: id, in: directory)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriteRefusal.profileExists(id: id)
        }
        let reading = try indexForAmending(in: directory)
        // The claim that licenses the unconditional re-point, checked against the same parse the
        // amendment uses: an apply that raced a profile switch stops here.
        guard reading.activeProfileId == oldId else {
            throw WriteRefusal.notReplacingTheActiveProfile(claimed: oldId,
                                                            active: reading.activeProfileId)
        }
        let index = try amendedIndex(from: reading, naming: profile, now: now)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(ProfileDocument(profile: profile, generated: stamp(now),
                                                       builtBy: builtBy))
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriteRefusal.profileExists(id: id)
        }
        try land(bytes, at: url, index: index, at: indexURL(in: directory))
        return url
    }

    /// **Retires derived profiles nothing can reach any more** — the directory and its index row.
    ///
    /// Every re-derivation writes a NEW profile directory and appends a row; `replacing:` above
    /// only asserts which id was active, and never retired anything. So the store grew by one
    /// full profile per survey refresh, forever. On 2026-08-29 that was eight profiles and 90 MB
    /// after a single evening — because the refresh button gave no feedback, so it was pressed
    /// repeatedly, but the leak was there at one-per-press regardless.
    ///
    /// **Three things are never retired, and the first two are this function's own rules rather
    /// than the caller's:**
    ///
    /// - **The active profile.** Read from the index here, not passed in, so a caller that has
    ///   drifted cannot talk this into deleting the tree the app is currently reading.
    /// - **Anything not provably derived.** `provenance` answers `handBuilt` for a profile the
    ///   out-of-repo builder wrote AND for one whose `builtBy` header is absent or unreadable —
    ///   the safe default by construction. A profile whose file will not decode at all is kept
    ///   too: unreadable is not the same as disposable, and this is the one operation where that
    ///   distinction is unrecoverable.
    /// - **Whatever the caller protects.** That is where domain knowledge lives: the ledger can
    ///   re-point Undo at `appliedUnderProfileId`, and `repointActiveProfile` requires the target
    ///   to still be on disk, so a landing that can still be taken back pins the profile it was
    ///   applied under. The store has no business knowing that, which is why it is a parameter.
    ///
    /// Candidates come from the index, and a row whose directory is already gone is pruned rather
    /// than skipped — otherwise a sweep interrupted between the two halves would leave that row
    /// naming nothing, forever, since `profile(id:)` returns nil for it and the "is it derived?"
    /// test could never pass again. Directories are removed first and the index written once at
    /// the end, so an interruption leaves rows that the NEXT sweep finishes off.
    ///
    /// A directory with no index row at all is not swept here. `writeDerivedProfile` cannot leave
    /// one — `land` removes the profile it just wrote if the index write fails — so the state is
    /// unreachable short of a hand edit, and inventing a rule for it would mean deleting a
    /// directory on no recorded authority, which is precisely the wrong side to err on.
    ///
    /// - Returns: the ids retired, for the caller's log line.
    @discardableResult
    public static func retireSupersededProfiles(protecting protected: Set<String>,
                                                in directory: URL,
                                                fileManager: FileManaging = FileManager.default)
        throws -> [String] {
        let reading = try indexForAmending(in: directory)
        guard let active = reading.activeProfileId else {
            // No active profile named: this index is not in a state to reason about supersession,
            // and retiring on a guess is the one mistake with no way back.
            return []
        }
        var listed: [[String: Any]] = []
        if let raw = reading.object?["profiles"], !(raw is NSNull) {
            guard let rows = raw as? [[String: Any]] else {
                throw WriteRefusal.indexUnreadable("profiles is not a list of objects")
            }
            listed = rows
        }
        let candidates = listed.compactMap { $0["profileId"] as? String }
            .filter { $0 != active && !protected.contains($0) }
        var retired: [String] = []
        for id in candidates.sorted() {
            let url = directory.appendingPathComponent(id)
            guard fileExistsAsDirectory(url, fileManager: fileManager) else {
                // Already gone — the row is the only thing left of it.
                retired.append(id)
                continue
            }
            // Unreadable counts as hand-built (see `provenance`), so it is kept: unreadable is
            // not disposable, and this is the one operation where the difference cannot be undone.
            //
            // **The header, not the whole profile.** This used to call `profile(id:in:)`, which
            // fully decodes the file — 3,013 folder entries, each with its axes and anchors, and
            // the lenient per-entry retry — to read ONE string, for every candidate, on the main
            // actor, in the middle of a landing. `ProvenanceProbe` reads the same string and
            // decides by the same rule.
            guard provenance(id: id, in: directory) == .derived else { continue }
            do {
                try fileManager.removeItem(at: url)
                retired.append(id)
            } catch {
                // Reported, never silent: a directory that would not go keeps its row, so the
                // next sweep sees it again rather than losing track of it.
                Logger.shared.warning("Filing profiles: could not retire \(id): \(error)")
            }
        }
        guard !retired.isEmpty else { return [] }

        var object = reading.object ?? [:]
        object["schemaVersion"] = currentSchema
        object["profiles"] = listed.filter {
            guard let id = $0["profileId"] as? String else { return true }
            return !retired.contains(id)
        }
        object["activeProfileId"] = active
        let bytes = try JSONSerialization.data(withJSONObject: object,
                                               options: [.sortedKeys, .prettyPrinted])
        try bytes.write(to: indexURL(in: directory), options: .atomic)
        return retired
    }

    /// Just enough of a profile file to answer ``FolderProfile/provenance`` — the `builtBy`
    /// header and nothing else.
    ///
    /// **It has to succeed on exactly the files ``FolderProfile``'s own decoder succeeds on**, or
    /// the retire sweep would gain or lose candidates: a file the full decoder rejects reads as
    /// nil there and is therefore KEPT, and this must not quietly decide such a file is derived.
    /// Both are satisfied by any JSON object and by nothing else — every field of `FolderProfile`
    /// is optional or defaulted, and `builtBy` is read through the same `try?` tolerance, so a
    /// header of the wrong type costs the file its provenance (which reads as hand-built, the
    /// cautious answer) rather than its readability. That equivalence is what
    /// `theProvenanceProbeAgreesWithTheFullDecode` pins.
    private struct ProvenanceProbe: Decodable {
        let builtBy: String?
        private enum Key: String, CodingKey { case builtBy }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            builtBy = try? c.decodeIfPresent(String.self, forKey: .builtBy)
        }
    }

    /// Who wrote the profile at `id`, read from its header alone — nil when the file is absent or
    /// is not something this build can read at all, which is the same silence `profile(id:in:)`
    /// answers with and means the same thing: **not disposable**.
    ///
    /// Internal rather than private so `FilingProfileStoreTests` can hold it against the full
    /// decode; there is no reason for a caller outside this module to prefer it.
    static func provenance(id: String, in directory: URL) -> FolderProfile.Provenance? {
        guard let data = try? Data(contentsOf: profileURL(id: id, in: directory)),
              let probe = try? JSONDecoder().decode(ProvenanceProbe.self, from: data)
        else { return nil }
        return probe.builtBy?.hasPrefix(FolderProfile.derivedBuiltByPrefix) == true
            ? .derived : .handBuilt
    }

    private static func fileExistsAsDirectory(_ url: URL, fileManager: FileManaging) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Re-points `profiles.json` at an id that already has a profile on disk — the Undo half of
    /// ``writeDerivedProfile(_:replacing:in:builtBy:now:)``: the inverse ran, and the profile
    /// recorded as `derivedFrom` (kept for exactly this) becomes active again.
    public static func repointActiveProfile(to id: String, in directory: URL,
                                            now: Date = Date()) throws {
        guard let target = profile(id: id, in: directory) else {
            throw WriteRefusal.indexUnreadable("no profile on disk for '\(id)' to re-point to")
        }
        let reading = try indexForAmending(in: directory)
        let index = try amendedIndex(from: reading, naming: target, now: now)
        try index.write(to: indexURL(in: directory), options: .atomic)
    }

    /// Writes the profile, then the index, undoing the profile if the index write fails.
    ///
    /// **Split out because it is the only part of the write that a test cannot otherwise reach.**
    /// The obvious way to fail an index write from outside — leaving a directory where
    /// `profiles.json` should be — stopped working the moment this store learned to tell "there but
    /// unreadable" from "absent": the directory is now caught while *reading*, and the rollback test
    /// went on passing while exercising a refusal instead. A test that no longer reaches its subject
    /// and does not say so is worse than no test, so the subject is now callable on its own with an
    /// index URL that cannot be written.
    ///
    /// - Parameters:
    ///   - bytes: the encoded profile.
    ///   - url: where it goes. The caller has already refused if something is there.
    ///   - index: composed index bytes, or nil when the index must not be touched.
    /// - Parameter writeIndex: how the index is written. Injected so a test can fail it *and* act
    ///   between the two writes — the rollback's byte comparison guards against exactly what another
    ///   writer does in that gap, and there is no other way to be in it deterministically.
    static func land(_ bytes: Data, at url: URL, index: Data?, at indexURL: URL,
                     writeIndex: (Data, URL) throws -> Void = {
                         try $0.write(to: $1, options: .atomic)
                     }) throws {
        try bytes.write(to: url, options: .atomic)
        guard let index else { return }
        do {
            try writeIndex(index, indexURL)
        } catch {
            // The profile landed and the index did not. Left alone that is the worst of the three
            // possible states: nothing points at the new profile, AND every retry now throws
            // `profileExists` — whose contract tells the caller "this tree already has a profile and
            // I did not touch it", which would be false. So undo the half that succeeded and let the
            // next attempt simply run.
            //
            // **Only if the bytes on disk are still the ones just written.** The caller's guard
            // proved the path was free at check time, not at removal time, so an unconditional
            // delete could take out a profile that something else landed in between — inverting the
            // refusal contract from "I did not touch it" into "I deleted it". Comparing first costs
            // one read and makes the rollback provably about this call's own work. Best-effort
            // throughout: if the comparison or the removal fails, the write error is still the one
            // worth reporting.
            //
            // **And this is the one thing in the write path that gets logged**, because it is the
            // one fact the thrown error does not carry. What propagates is the index write's own
            // error — a permissions or I/O failure about `profiles.json` — which says nothing about
            // a folder profile having been written and then taken away again. Without the line, a
            // reader who goes looking finds no profile, no index entry, and no account of either.
            // The id is the directory the profile sits in, which is how ``profileURL(id:in:)``
            // composed this path.
            //
            // **Three outcomes, not two, because `isOurs == false` covers two different worlds.**
            // The `else` used to say "left in place, so a retry will refuse it" for both of them,
            // and one of the two is a correlated failure rather than an exotic race: when the index
            // write fails *because the containing directory went away* — an unmounted volume, a
            // directory removed or renamed between the two writes — the profile went with it. The
            // read then fails, `isOurs` is false, nothing is removed, and the line told a reader
            // that a profile sits at a path holding nothing and predicted a refusal that will never
            // happen. A log line that is wrong in the case a reader is most likely to be reading it
            // in is worse than no line.
            let onDisk = try? Data(contentsOf: url)
            let rolledBack = onDisk == bytes && (try? FileManager.default.removeItem(at: url)) != nil
            // `attributesOfItem` rather than `fileExists`, and after the removal attempt: the read
            // above cannot tell "absent" from "there but unreadable" (mode 000, an ACL, an I/O
            // error), and those two want opposite sentences — a profile that is there and cannot be
            // read WILL still be refused by the retry.
            let stillThere = !rolledBack
                && (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
            let outcome: String
            if rolledBack {
                outcome = " — the profile just written was removed again, so nothing points at a "
                    + "half-landed survey and a retry can simply run"
            } else if stillThere {
                outcome = " — the profile at \(url.path) was left in place, so a retry will refuse "
                    + "it as an existing profile"
            } else {
                // Not removed by this rollback and not there either: whatever failed the index
                // write took the profile too. Said as its own sentence, because "was left in place"
                // and "is already gone" send a reader looking in opposite directions.
                outcome = " — nothing is at \(url.path) either, so the profile went with whatever "
                    + "failed the index write and a retry can simply run"
            }
            Logger.shared.warning(
                "Couldn't write profiles.json for the folder profile "
                + "\(url.deletingLastPathComponent().lastPathComponent): \(error.localizedDescription)"
                + outcome)
            throw error
        }
    }

    /// Whether a value parsed out of JSON is a boolean rather than a number.
    ///
    /// `true` and `false` bridge to `NSNumber`, so `as? Int` accepts them as 1 and 0 — which makes
    /// every "is this field a number" test silently true for booleans. `CFGetTypeID` is the only
    /// reliable separation once the value has been through `JSONSerialization`.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
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
        let url = indexURL(in: directory)
        guard let data = try? Data(contentsOf: url) else {
            // **"Absent" and "there but unreadable" are different answers**, and a `try?` alone
            // conflates them. A `profiles.json` that exists and cannot be read — mode 000, an ACL,
            // an I/O error — would otherwise look like a fresh machine, and an atomic write needs
            // permission on the *directory* rather than the file, so composing a new index over it
            // would succeed and orphan every profile the old one named.
            //
            // `attributesOfItem` rather than `fileExists`, because only the former sees a symlink
            // that does not resolve: `fileExists` follows links and answers false for one whose
            // target is missing — an index symlinked onto a volume that is currently unmounted
            // reads as "no index here", and the atomic write then replaces the link itself.
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                throw WriteRefusal.indexUnreadable("it exists but could not be read")
            }
            return IndexReading(object: nil, activeProfileId: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WriteRefusal.indexUnreadable("it is not a JSON object")
        }
        // A schema this build does not know is refused — including one that is not a number at all,
        // which the old check skipped entirely by asking `as? Int` and moving on when it was nil.
        if let version = object["schemaVersion"], !(version is NSNull) {
            // `as? Int` alone is not a number test: JSON `true` bridges to `NSNumber` and satisfies
            // it as 1, so a `"schemaVersion": true` would have passed as schema 1 here while
            // `JSONDecoder` threw for ``activeProfileId(in:)`` — the same two-readers-disagree hole
            // this function exists to close, one type over. `false` was worse: it read as schema 0
            // and the refusal named a version the file never contained.
            guard !isJSONBoolean(version), let number = version as? Int else {
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
            active = id
        }
        // **"Active" means it names a profile that is really there.** An id pointing at a profile
        // that does not exist is a dangling pointer, not an answer, and treating it as one left the
        // bootstrap permanently dead while reporting success: a hand-edit as small as a trailing
        // space (`"father "`) makes every read load nothing, and this refused to re-point for
        // ever after. Re-pointing away from a name that resolves to no file cannot lose anything,
        // and re-pointing away from one that resolves is exactly what must never happen.
        //
        // This is also why the empty id is not special-cased. It is not "no profile": an empty
        // component collapses in `appendingPathComponent`, so `""` addresses
        // `profiles/folder-profile.json`, which some layouts really do have. Asking the filesystem
        // answers both cases with one rule instead of a guess about which ids are meaningful.
        if let id = active, !FileManager.default.fileExists(atPath: profileURL(id: id, in: directory).path) {
            active = nil
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
            var row: [String: Any] = ["profileId": profile.profileId, "root": profile.root,
                                      "portable": false, "generatedAt": stamp(now),
                                      "surveyedFolders": profile.folders.count,
                                      "surveyedFiles": profile.folders.values
                                          .reduce(0) { $0 + $1.fileCount }]
            // **`displayName` and `provider` are inherited from the profile being replaced, not
            // guessed.** The rule this replaces — "a folder walk does not know the person's
            // name, and an absent field reads as unknown while a guessed one reads as a fact" —
            // is right about a FIRST profile and wrong about a re-derivation, which is a new
            // survey of a tree that has already been identified. Written as it was, one press of
            // "Update the survey" turned a row reading `Father / iCloud Drive (Desktop &
            // Documents sync) / 12280 files` into a nameless one, and every press after that
            // inherited the nothing. Copying from the row being superseded keeps a fact a fact:
            // the source is the previous active profile's own entry, never a construction.
            if let parent = profiles.first(where: {
                $0["profileId"] as? String == reading.activeProfileId
            }) {
                for field in ["displayName", "provider"] where row[field] == nil {
                    if let carried = parent[field] { row[field] = carried }
                }
            }
            profiles.append(row)
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
            no documents — so role, anchors, axes and counts are DERIVED here rather than left \
            empty; where a folder's entry carries none, that is the survey finding none, not the \
            survey declining to look. `naming` is the exception and is always empty: a wrong \
            convention would have the rename pass propose renames toward one nobody has. What a \
            walk cannot see at all, and what this file therefore never carries, is folderSemantics \
            and the jurisdiction vocabulary.
            """

        enum Key: String, CodingKey {
            case schemaVersion, profileId, portable, generated, root, note, builtBy
            case derivedFrom, folderCount, axes, folders
        }

        /// The `axes.person` shape ``FolderProfile``'s decoder reads: a `values` list plus the
        /// alias pairs, which are what let `Family/Mom` and `Granny` resolve to one person.
        struct PersonAxisBox: Encodable {
            let values: [String]
            let aliases: [String: String]
        }

        struct EntryBox: Encodable {
            let entry: FolderProfileEntry
            enum Key: String, CodingKey {
                case path, role, naming, anchors, acceptsNewFiles, noIntakeReason
                case fileCount, subfolderCount, axes
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
                // The refusal's WHY travels with the refusal — §5.5's carry-over is the writer
                // whose entries hold one.
                try c.encodeIfPresent(entry.noIntakeReason, forKey: .noIntakeReason)
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
            // The provenance chain (§5.5 step 6): what this profile was re-derived from, which is
            // what Undo re-points to. Omitted for a plain walk, exactly as the decoder tolerates.
            try c.encodeIfPresent(profile.derivedFrom, forKey: .derivedFrom)
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
