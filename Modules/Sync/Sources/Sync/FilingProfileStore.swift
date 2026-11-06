import CryptoKit
import Events
import Foundation

/// Reads the per-tree filing artifacts: a ``FolderProfile`` and its ``FilingMemory``.
///
/// One store because they are two halves of one description of one tree, keyed identically:
/// `profiles/<id>/folder-profile.json` and `profiles/<id>/filing-memory.json`, with `profiles.json`
/// naming the active id. Keying by id makes a second tree additive: one person's conventions can't
/// overwrite another's. Every read failure yields nil, which restores the no-profile behaviour.
///
/// Writes are narrow, because a partial rewrite would be worse than no profile. The memory's only
/// writer is ``FilingSurveyStore``: a complete rebuild, written atomically, only when it differs.
/// The profile's write paths (``writeProfile(_:in:builtBy:now:)`` and the re-derivation below)
/// **refuse over an existing `folder-profile.json`**, write atomically, and re-point
/// `profiles.json` only by the rules each states, so a name-only profile never silently replaces a
/// hand-built one.
public enum FilingProfileStore {

    /// Bumped when either artifact's shape changes. A foreign schema is discarded, not migrated, as
    /// in the other stores: the contents are a re-survey away.
    public static let currentSchema = 1

    /// `~/Library/Application Support/SyncCloud/profiles`. Injected by the app, never defaulted
    /// inside `Sync`, like the verdict cache, hash index and Storage Lens store: library code must
    /// not reach into the real home directory.
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

    /// The folder profile for `id`, or nil when absent or unreadable. What the decode salvaged is
    /// logged here, once: a `role` this build doesn't know costs that folder its role, not the
    /// whole profile, and since that folder now files differently the user's log should say so.
    /// Logged at the door so the decoder stays a pure function of its bytes.
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

    /// The filing memory for `id`, or nil when absent or unreadable. A missing memory is ordinary:
    /// the profile alone still routes, just less well.
    public static func memory(id: String, in directory: URL) -> FilingMemory? {
        decode(FilingMemory.self, at: directory.appendingPathComponent("\(id)/filing-memory.json"),
               what: "filing memory")
    }

    private struct PeopleFile: Decodable {
        let schemaVersion: Int?
        let people: [Person]
        /// Suggested name forms the user has rejected. Absent in older files, which reads as
        /// nothing rejected.
        let notNames: [String]?
    }

    /// The household for `id`: `people.json` when it exists, else a registry seeded from the
    /// profile's person axis. The seed carries the profile's alias map, so `Mom` and `Granny` still
    /// resolve to one person; the file adds the full names documents print, which make "Daughter
    /// Father" attributable to Daughter. `profile` is optional so the user's roster stays readable
    /// on a machine with no survey.
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

    /// All artifacts for the active profile, if any, **and the id they were loaded under**, which
    /// isn't always the one inside the profile.
    ///
    /// The directory is the identity: it is where the file was found, and every read and write goes
    /// there. `profile.profileId` is informational and decodes as `"default"` when absent; trusting
    /// it would read from one folder and write roster edits to another, and key the fingerprint
    /// against artifacts not in use. A disagreement is logged, not silently resolved.
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
        // A re-derive cut off before its replay may have left this folder without the survey its
        // parent holds. Not finished here: every caller is on the main actor, and the read-back
        // decodes and rewrites a whole corpus. The caller runs
        // `FileSyncManager.finishInterruptedSurveyReplay()` once the profile is attached.
        return (id, profile, memory(id: id, in: directory),
                personRegistry(id: id, profile: profile, in: directory))
    }

    private struct SchemaProbe: Decodable { let schemaVersion: Int? }

    /// A short digest of the artifact files on disk, or "" when none is present.
    ///
    /// **The artifacts are part of the question the backend is asked:** they decide the router's
    /// shortlist, which is the classifier's folder menu. ``FilingVerdictKey`` includes this, so a
    /// re-survey invalidates cached verdicts instead of replaying answers to the old question.
    /// Hashed from the bytes, so it also moves when a profile is regenerated without the memory.
    /// One SHA-256 of a few megabytes per load.
    ///
    /// **Nil when a file exists but can't be read: the fingerprint is unavailable, not different.**
    /// A digest that skipped it could never recur once the file is fixed, stranding every paid
    /// verdict recorded under it. A caller holding nil must neither record nor serve a verdict (the
    /// scan sites turn the cache off both ways). A genuinely absent file is ordinary; the others
    /// digest without it.
    public static func fingerprint(id: String, in directory: URL) -> String? {
        var hasher = SHA256()
        var any = false
        // `people.json` is part of the question too: the registry decides the person veto and the
        // person axis bonus, both of which move the classifier's shortlist.
        for name in ["folder-profile.json", "filing-memory.json", "people.json"] {
            let url = directory.appendingPathComponent("\(id)/\(name)")
            guard let data = try? Data(contentsOf: url) else {
                // Absent and there-but-unreadable are different answers, as everywhere in this
                // store. `attributesOfItem`, not `fileExists`, so a dangling symlink still counts
                // as present.
                guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                    // This digest is re-derived at launch, after a roster save
                    // (`FileSyncManager.refreshFilingArtifactFingerprint`) and after a re-survey
                    // writes, so a repaired `folder-profile.json` or `filing-memory.json` is picked
                    // up without a relaunch. `people.json` is the exception: an unreadable roster
                    // sets `PeopleStore.rosterIsUnreadable` for the session and `save()` refuses
                    // while it is set, so `savedRevision` never bumps and that repair waits for a
                    // relaunch (pinned by
                    // `PeopleStoreSaveOrderingTests.aRefusedSaveDoesNotBumpTheRevision`).
                    //
                    // While it stays broken the verdict cache is off for read as well as write, so
                    // every paid refine re-bills in full. The People banner doesn't say so, which
                    // is why the log line does. Logged per call, which is cheap because nothing
                    // calls this per file or per scan.
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

    /// The part of `people.json` that can change a classification: the roster, and the schema that
    /// says how to read it. The file also carries `notNames` (declined name suggestions) and
    /// whatever keys an editor left; hashing those would invalidate every cached verdict, and
    /// re-bill a paid re-classification, for things the engine can't see. Re-serialised
    /// canonically, so whitespace and key order don't count either. Falls back to the raw bytes
    /// when the JSON can't be read: the conservative direction, invalidating rather than serving
    /// answers for an unparsed household.
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

    /// Whether something is at `url` that this process couldn't open: mode 000, an ACL, an I/O
    /// error, a symlink whose target is gone. **`attributesOfItem`, never `fileExists`**:
    /// `fileExists` follows symlinks and answers false for one into an unmounted volume, while an
    /// atomic write would replace the link itself.
    static func isPresentButUnreadable(at url: URL, fileManager: FileManager = .default) -> Bool {
        (try? Data(contentsOf: url)) == nil
            && (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL, what: String) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            // **Absent and there-but-unreadable both answer nil, so a caller that writes must ask
            // separately.** Nil is right for readers (filing falls back to folder names) and wrong
            // for the re-survey, where `previousMemory == nil` would make it atomically replace a
            // file it never read; `resurveyFilingMemory` asks `isPresentButUnreadable` first. The
            // log line is the least a nil can do.
            if isPresentButUnreadable(at: url) {
                Logger.shared.warning("The \(what) at \(url.path) exists but could not be read — "
                                      + "treated as absent by everything that only READS it. "
                                      + "Nothing is inferred about the tree from it.")
            }
            return nil
        }
        // The artifacts carry their own version. A future shape decoded field by field would be a
        // half-empty value used as if whole, the silent wrong answer this store exists to avoid.
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
           let v = probe.schemaVersion, v != currentSchema {
            Logger.shared.warning("The \(what) at \(url.lastPathComponent) is schema \(v), not "
                                  + "\(currentSchema) — ignoring it rather than half-reading it")
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // Name the file: these are hand-generated artifacts, so "it silently did nothing" is a
            // real support question, usually answered by a malformed file.
            Logger.shared.warning("Couldn't read the \(what) at \(url.lastPathComponent) — "
                                  + "filing will fall back to folder names: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - The one write path

extension FilingProfileStore {

    /// Why a profile write was refused, as a typed error: the caller promised the user a survey and
    /// must be able to say "this tree already has a profile and I didn't touch it", which is a
    /// different sentence from "the write failed".
    ///
    /// **The store throws; the caller logs.** Each case's ``description`` is the whole sentence, so
    /// a log beside the `throw` would say it twice. The write path logs one thing only, the
    /// rollback in ``land(_:at:index:at:writeIndex:)``, the one fact no thrown error carries. **A
    /// caller wiring this up owes the log line**, and `description` is written to be it.
    public enum WriteRefusal: Error, Equatable, CustomStringConvertible {
        /// `folder-profile.json` already exists for this id. Never overwritten, never merged.
        case profileExists(id: String)
        /// `profiles.json` is present but not safely amendable (not a JSON object, or an unknown
        /// schema). Refused, not replaced: an unreadable index is still the user's, and names
        /// profiles a clobber would orphan.
        case indexUnreadable(String)
        /// A profile id that can't be a directory name. It is interpolated into a path, so an empty
        /// or separator-bearing id is refused at the door.
        case invalidProfileId(String)
        /// ``writeDerivedProfile(_:replacing:in:builtBy:now:)``'s refusal: the id the caller claims
        /// to replace isn't the one `profiles.json` names active. The unconditional re-point is
        /// licensed only by that claim being true, so an apply that raced a profile switch stops
        /// here.
        case notReplacingTheActiveProfile(claimed: String, active: String?)
        /// The derived profile's own file doesn't chain to the id it claims to replace.
        /// `derivedFrom` is what Undo reads, so a profile that forgot its parent could never be
        /// undone. Unlike the case above, here the profile disagrees with itself, not the index
        /// with the caller.
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

    /// Whether a freshly written profile may become the active one: **provenance, not existence.**
    /// Re-point when nothing is active, or when the active profile is the app's own derivation, so
    /// a re-survey replaces its predecessor instead of writing a profile nothing reads. Never when
    /// it is hand-built: that file records judgements a walk can't see (`naming`,
    /// `folderSemantics`, the `outbound-pack` refusals), and aiming away from it would quietly
    /// degrade To File and renames. **An unreadable active profile counts as hand-built**, as in
    /// ``FolderProfile/provenance``: a file this build can't parse is one it must not decide it
    /// owns.
    static func mayRepoint(activeId: String?, in directory: URL) -> Bool {
        guard let activeId else { return true }
        guard let active = profile(id: activeId, in: directory) else { return false }
        return active.provenance == .derived
    }

    /// Writes `profile` as `profiles/<id>/folder-profile.json`, creating the directory if needed,
    /// and points `profiles.json` at it **only when ``mayRepoint(activeId:in:)`` allows it**.
    ///
    /// Four guarantees, each tested:
    ///
    /// 1. **It refuses over an existing profile** (`WriteRefusal.profileExists`, bytes untouched):
    /// a
    ///    name-only profile must never land on a hand-built one. There is no `overwrite:` parameter;
    ///    a caller that wants to replace a profile must move the old file itself, in the open.
    /// 2. **It writes atomically**, so the file is only ever a whole profile, as ``FilingSurveyStore``
    ///    does for the memory. If the index write then fails, the profile is removed again: one
    ///    nothing points at would make every retry refuse with `profileExists`, a state a caller
    ///    can't escape. The empty directory stays, harmlessly.
    /// 3. **It touches `profiles.json` only when ``mayRepoint(activeId:in:)`` says so**, and amends
    ///    the document rather than rewriting it, so a hand-built index keeps its fields and other
    ///    profiles. Stricter than ``activeProfileId(in:)`` one way (an unparseable field refuses) and
    ///    looser the other (an id naming no profile on disk counts as nothing active, or a dangling
    ///    pointer would block the bootstrap for good). Caveats: `JSONSerialization` reformats numbers
    ///    (`0.1` comes back `0.10000000000000001`) and collapses duplicate keys, so "keeps" means
    ///    content, not bytes; and the read-modify-write is unlocked, so a concurrent edit to
    ///    `profiles.json` is lost.
    ///
    ///    With a **hand-built** profile active the index is left alone, so the profile written here
    ///    is readable by `profile(id:)` but isn't what `active(in:)` returns. That is intended, but
    ///    "written" and "in use" return the same URL, so a caller that promised a survey must check
    ///    ``FileSyncManager/FolderWalkReport/becameActive``.
    /// 4. **The JSON is the shape the offline generator writes**: same `schemaVersion` (checked on
    ///    read by ``decode(_:at:what:)``), `folders` array and `axes.person` box. Round-tripping
    ///    through ``profile(id:in:)`` pins that.
    ///
    /// The header fields (`generated`, `builtBy`, `note`) are for whoever opens the file because a
    /// suggestion looks wrong; `builtBy` tells a name-only survey from the full offline one.
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

        // The index is composed before the profile lands, so a `profiles.json` this can't amend
        // refuses the whole write rather than leaving a profile the next attempt would refuse to
        // replace. Whether to re-point at all is `mayRepoint`'s call: re-pointing away from a
        // hand-built profile would aim every read at a tree the user didn't choose.
        //
        // **Read once.** The decision and the amendment come from the same parse. Two readers of
        // different strictness (`JSONDecoder` and `JSONSerialization`) would disagree on a
        // hand-edit slip like `"schemaVersion": "1"`, and an index naming an active profile would
        // get re-pointed.
        let reading = try indexForAmending(in: directory)
        let index = mayRepoint(activeId: reading.activeProfileId, in: directory)
            ? try amendedIndex(from: reading, naming: profile, now: now) : nil

        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // **`.withoutEscapingSlashes` is not cosmetic.** Every key is a folder path, so default
        // escaping writes `Finance\/US` throughout: unreadable, and it doesn't diff against the
        // Python builder's output. Every walked profile on disk is in this shape now, so changing
        // it would be a migration.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let document = ProfileDocument(profile: profile, generated: stamp(now), builtBy: builtBy)
        let bytes = try encoder.encode(document)

        // **Re-checked immediately before the write.** The guard at the top runs before
        // milliseconds of real I/O, and a profile landing here in that window would be overwritten
        // by the atomic write below, the one thing this path exists to prevent. This narrows the
        // window to two adjacent statements; closing it would need an exclusive create, and
        // `.withoutOverwriting` can't help because Foundation traps when it is combined with
        // `.atomic`, which is load-bearing (`theProfileIsWrittenAtomically`). A residual race
        // remains.
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriteRefusal.profileExists(id: id)
        }
        try land(bytes, at: url, index: index, at: indexURL(in: directory))
        return url
    }

    /// Writes a profile re-derived after a Restructure apply and re-points `profiles.json` at it,
    /// **even away from a hand-built profile**, which `writeProfile` never does. The licence is
    /// provenance carried in the file: the caller proves it holds the active profile by naming it
    /// in `replacing`, the new profile records it as `derivedFrom`, and the old file is **never
    /// touched**. It is what Undo re-points back to, and may be the last hand-built copy. The guard
    /// moves from "never replace what exists" to "never lose what exists".
    @discardableResult
    public static func writeDerivedProfile(_ profile: FolderProfile, replacing oldId: String,
                                           in directory: URL,
                                           builtBy: String = "SyncCloud — restructure re-derivation",
                                           now: Date = Date()) throws -> URL {
        let id = profile.profileId
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WriteRefusal.invalidProfileId(id)
        }
        // The chain must be in the file, not only the caller's intent: `derivedFrom` is what Undo
        // reads, and a derived profile without it can't be undone.
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

    /// The files in a profile's folder that the user made, as opposed to what a walk derives: the
    /// household roster, the person verdicts, and everything Restructure remembers. They travel
    /// with the active profile, and a folder holding the only copy of one is never retired. The
    /// roster follows every walk; the verdicts and ledger, keyed by paths in the folder walked,
    /// follow their own Setup folder (``RestructureRootMap``).
    public static let curatedArtifactNames = ["people.json", "person-tags.json", "restructure.json"]

    /// What the document survey learned: ``FilingSurveyStore``'s corpus and memory. Not curated,
    /// and not carried by a walk, but hours of reading to rebuild, so a folder holding one the
    /// active folder lacks is never retired either (``retireSupersededProfiles``).
    public static let surveyArtifactNames = ["filing-corpus.json", "filing-memory.json"]

    /// The plans Restructure's Export Plan wrote into a profile's folder: the
    /// `restructure-<date>-<family>….json` files (``RestructureStore/exportPlan(_:)``), never the
    /// ledger `restructure.json`. Made by and named to the user, so like the curated files a folder
    /// holding one the active folder lacks is never retired; retiring it would delete them
    /// permanently. Nil when the folder couldn't be listed.
    public static func exportedPlanNames(inProfile id: String, in directory: URL,
                                         fileManager: FileManaging) -> [String]? {
        FileSyncManager.directoryNames(at: directory.appendingPathComponent(id).path,
                                       fm: fileManager)?
            .filter { $0.hasPrefix("restructure-") && $0.hasSuffix(".json") }
            .sorted()
    }

    /// **Retires derived profiles nothing can reach any more**: the directory and its index row.
    /// Every re-derivation writes a new profile directory and row, so without this the store grows
    /// by a whole profile per survey refresh.
    ///
    /// **Four things are never retired**; the first three are this function's own rules:
    ///
    /// - **The active profile**, read from the index here, not passed in, so a drifted caller can't
    ///   talk this into deleting the tree the app is reading.
    /// - **Anything not provably derived.** `provenance` answers `handBuilt` for the offline
    ///   builder's profiles and for any whose `builtBy` header is absent or unreadable. A file that
    ///   won't decode is kept too: unreadable is not disposable, and here the difference is
    ///   unrecoverable.
    /// - **What a Setup folder's Restructure history needs**: every folder ``RestructureRootMap``
    ///   names, and every id the ledgers in those folders record. An unreadable map or ledger retires
    ///   nothing.
    /// - **Whatever the caller protects.** The caller knows the ledger can re-point Undo at
    ///   `appliedUnderProfileId` and that `repointActiveProfile` needs the target on disk, so a
    ///   landing that can still be taken back pins its profile.
    ///
    /// Candidates come from the index. A row whose directory is already gone is pruned, or a sweep
    /// interrupted between its two halves would leave a row naming nothing that no later test could
    /// clear. Directories go first and the index is written once at the end, so an interruption
    /// leaves rows the next sweep finishes. A directory with no index row isn't swept: `land`
    /// removes what it wrote if the index write fails, so only a hand edit can make one, and
    /// deleting it would be acting on no recorded authority.
    ///
    /// - Returns: the ids retired, for the caller's log line.
    @discardableResult
    public static func retireSupersededProfiles(protecting protected: Set<String>,
                                                in directory: URL,
                                                fileManager: FileManaging = FileManager.default)
        throws -> [String] {
        let reading = try indexForAmending(in: directory)
        guard let active = reading.activeProfileId else {
            // No active profile named: this index isn't in a state to reason about supersession,
            // and retiring on a guess has no way back.
            return []
        }
        var listed: [[String: Any]] = []
        if let raw = reading.object?["profiles"], !(raw is NSNull) {
            guard let rows = raw as? [[String: Any]] else {
                throw WriteRefusal.indexUnreadable("profiles is not a list of objects")
            }
            listed = rows
        }
        // **A folder Setup walked away from keeps its history, and its Undo keeps what it needs:**
        // the folder the root map names for each Setup folder, and every id that folder's ledger
        // records, since a walk back takes that ledger up and re-points its Undo at them. Kept here
        // so every sweep keeps them; an unreadable map, or ledger it names, retires nothing.
        guard let mapped = RestructureRootMap.protectedProfileIds(in: directory) else { return [] }
        let candidates = listed.compactMap { $0["profileId"] as? String }
            .filter { $0 != active && !protected.contains($0) && !mapped.contains($0) }
        var retired: [String] = []
        for id in candidates.sorted() {
            let url = directory.appendingPathComponent(id)
            guard fileExistsAsDirectory(url, fileManager: fileManager) else {
                // Already gone: the row is all that is left of it.
                retired.append(id)
                continue
            }
            // Unreadable counts as hand-built (see `provenance`), so it is kept: unreadable is not
            // disposable, and this removal can't be undone. Reads the header only
            // (`ProvenanceProbe`), not the whole profile, since this runs per candidate on the main
            // actor during a landing.
            guard provenance(id: id, in: directory) == .derived else { continue }
            // **Never the only copy of what the user made.** A profile's folder also holds the
            // roster, the person verdicts and Restructure's ledger. If a re-point didn't carry
            // them, this removal (permanent, not the Trash) would take the only copy.
            //
            // **Nor the only copy of what the survey learned.** A re-derive re-points the index
            // before its corpus replay, and the folder it leaves is named by no ledger record, so a
            // quit during the replay would let this sweep take the corpus and memory. Kept until
            // the load reads them back (`finishInterruptedSurveyReplay`). An unfinished survey's
            // progress counts only while the active folder has neither progress nor a corpus; once
            // it has finished a survey, a stopped one elsewhere is stale.
            func holds(_ folder: URL, _ name: String) -> Bool {
                fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
            }
            let activeURL = directory.appendingPathComponent(active)
            var stranded = (curatedArtifactNames + surveyArtifactNames).filter { name in
                holds(url, name) && !holds(activeURL, name)
            }
            // An export the active folder lacks is stranded too; a folder whose exports can't be
            // listed is kept, since unreadable is not disposable.
            guard let exported = exportedPlanNames(inProfile: id, in: directory,
                                                   fileManager: fileManager) else {
                Logger.shared.warning("Filing profiles: kept \(id) — its folder could not be "
                    + "listed for exported plans")
                continue
            }
            // By contents, not name: two exports of one name can be two plans, and the active
            // folder holding the other doesn't make this one disposable.
            let activeExports = Set((exportedPlanNames(inProfile: active, in: directory,
                                                       fileManager: fileManager) ?? [])
                .compactMap { try? Data(contentsOf: activeURL.appendingPathComponent($0)) })
            stranded += exported.filter { name in
                guard let bytes = try? Data(contentsOf: url.appendingPathComponent(name)) else {
                    return true
                }
                return !activeExports.contains(bytes)
            }
            let progress = DocumentSurveyCheckpointStore.filename
            if holds(url, progress), !holds(activeURL, progress),
               !fileManager.fileExists(atPath: FilingSurveyStore.corpusURL(id: active, in: directory).path) {
                stranded.append(progress)
            }
            guard stranded.isEmpty else {
                Logger.shared.warning("Filing profiles: kept \(id) — it holds "
                    + stranded.joined(separator: ", ") + " and the active profile \(active) does not")
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                retired.append(id)
            } catch {
                // Reported, never silent: a directory that won't go keeps its row, so the next
                // sweep sees it again.
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

    /// Just enough of a profile file to answer ``FolderProfile/provenance``: the `builtBy` header.
    /// **It must succeed on exactly the files ``FolderProfile``'s own decoder succeeds on**, or the
    /// retire sweep would gain or lose candidates; a file the full decoder rejects is kept, and
    /// this must not call it derived. Both accept any JSON object and nothing else: every
    /// `FolderProfile` field is optional or defaulted, and a wrong-typed `builtBy` costs only
    /// provenance (read as hand-built, the cautious answer).
    /// `theProvenanceProbeAgreesWithTheFullDecode` pins this.
    private struct ProvenanceProbe: Decodable {
        let builtBy: String?
        private enum Key: String, CodingKey { case builtBy }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            builtBy = try? c.decodeIfPresent(String.self, forKey: .builtBy)
        }
    }

    /// Who wrote the profile at `id`, read from its header alone. Nil when the file is absent or
    /// unreadable, the same silence as `profile(id:in:)`, and it means the same: **not
    /// disposable**. Internal so `FilingProfileStoreTests` can hold it against the full decode.
    static func provenance(id: String, in directory: URL) -> FolderProfile.Provenance? {
        guard let data = try? Data(contentsOf: profileURL(id: id, in: directory)),
              let probe = try? JSONDecoder().decode(ProvenanceProbe.self, from: data)
        else { return nil }
        return probe.builtBy?.hasPrefix(FolderProfile.derivedBuiltByPrefix) == true
            ? .derived : .handBuilt
    }

    /// Just the `root` a profile file records, as ``FolderProfile/recordedRoot`` decodes it.
    private struct RootProbe: Decodable {
        let root: String?
        private enum Key: String, CodingKey { case root }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            root = try? c.decodeIfPresent(String.self, forKey: .root)
        }
    }

    /// ``FolderProfile/recordedRoot`` for the profile at `id`, as the file spells it, read from the
    /// header alone. Nil when the file records none or can't be read.
    static func recordedRoot(id: String, in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: profileURL(id: id, in: directory)) else { return nil }
        return (try? JSONDecoder().decode(RootProbe.self, from: data))?.root
    }

    /// Whether two recorded folders are one folder: compared standardised, case folded where the
    /// volume folds it, and through links, so `~/OneDrive` and the `~/Library/CloudStorage/…`
    /// folder it links to are one root. `~` is expanded. Nil is no folder, never the same as
    /// anything.
    static func namesSameRoot(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let ea = (a as NSString).expandingTildeInPath, eb = (b as NSString).expandingTildeInPath
        guard ea.hasPrefix("/"), eb.hasPrefix("/") else { return false }
        return PathBoundary.resolvesToSameDirectory(
            ea, eb, caseSensitive: FileSyncManager.volumeSupportsCaseSensitiveNames(
                for: URL(fileURLWithPath: ea)))
    }

    private static func fileExistsAsDirectory(_ url: URL, fileManager: FileManaging) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Re-points `profiles.json` at an id that already has a profile on disk: the Undo half of
    /// ``writeDerivedProfile(_:replacing:in:builtBy:now:)``, making the `derivedFrom` profile (kept
    /// for this) active again.
    public static func repointActiveProfile(to id: String, in directory: URL,
                                            now: Date = Date()) throws {
        guard let target = profile(id: id, in: directory) else {
            throw WriteRefusal.indexUnreadable("no profile on disk for '\(id)' to re-point to")
        }
        let reading = try indexForAmending(in: directory)
        let index = try amendedIndex(from: reading, naming: target, now: now)
        try index.write(to: indexURL(in: directory), options: .atomic)
    }

    /// Writes the profile, then the index, undoing the profile if the index write fails. Split out
    /// so a test can reach the rollback directly: failing an index write from outside now trips the
    /// read-side refusal instead, and the test would pass without reaching its subject.
    ///
    /// - Parameters:
    ///   - bytes: the encoded profile.
    ///   - url: where it goes. The caller has already refused if something is there.
    ///   - index: composed index bytes, or nil when the index must not be touched.
    /// - Parameter writeIndex: how the index is written. Injected so a test can fail it and act
    ///   between the two writes, the gap the rollback's byte comparison guards.
    static func land(_ bytes: Data, at url: URL, index: Data?, at indexURL: URL,
                     writeIndex: (Data, URL) throws -> Void = {
                         try $0.write(to: $1, options: .atomic)
                     }) throws {
        try bytes.write(to: url, options: .atomic)
        guard let index else { return }
        do {
            try writeIndex(index, indexURL)
        } catch {
            // The profile landed and the index didn't: the worst state, since nothing points at the
            // new profile and every retry would throw `profileExists`, falsely claiming "I didn't
            // touch it". So undo the half that succeeded.
            //
            // **Only if the bytes on disk are still the ones just written.** The caller's guard
            // proved the path free at check time, not now, so an unconditional delete could remove
            // a profile something else landed in between. Best-effort: if the compare or removal
            // fails, the write error is still the one to report.
            //
            // **This is the one thing the write path logs**, because the thrown error (about
            // `profiles.json`) doesn't say a profile was written and taken away again. The id is
            // the profile's directory name, as ``profileURL(id:in:)`` composed it.
            //
            // **Three outcomes, because not rolled back covers two cases.** If the index write
            // failed because the directory went away (an unmounted volume, a rename), the profile
            // went with it; saying it was "left in place" would send a reader looking for a file
            // that isn't there.
            let onDisk = try? Data(contentsOf: url)
            let rolledBack = onDisk == bytes && (try? FileManager.default.removeItem(at: url)) != nil
            // `attributesOfItem`, not `fileExists`, and after the removal attempt: the read above
            // can't tell absent from there-but-unreadable, and those need opposite sentences, since
            // a profile that is there and unreadable will still be refused by the retry.
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
                // write took the profile too. Its own sentence, because "left in place" and
                // "already gone" send a reader looking in opposite directions.
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

    /// Whether a value parsed from JSON is a boolean rather than a number. `true` and `false`
    /// bridge to `NSNumber`, so `as? Int` accepts them as 1 and 0; `CFGetTypeID` is the only
    /// reliable separation after `JSONSerialization`.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// What `profiles.json` holds right now, parsed once for both questions the write path asks:
    /// may it be amended at all, and does it already name an active profile.
    private struct IndexReading {
        /// The parsed document, or nil when there is no index file yet.
        let object: [String: Any]?
        /// The id the index names active, when it names a usable one.
        let activeProfileId: String?
    }

    /// Reads `profiles.json` for amendment, **refusing anything it can't fully account for**.
    /// Stricter than ``activeProfileId(in:)`` on purpose: a reader that can't understand the index
    /// degrades to "no active profile" and carries on, but a writer must stop, because the fields
    /// it would overwrite are the ones it failed to read. A malformed field is a refusal here, an
    /// absence there.
    private static func indexForAmending(in directory: URL) throws -> IndexReading {
        let url = indexURL(in: directory)
        guard let data = try? Data(contentsOf: url) else {
            // **Absent and there-but-unreadable are different answers.** A `profiles.json` that
            // exists but can't be read (mode 000, an ACL, an I/O error) would look like a fresh
            // machine, and since an atomic write needs permission on the directory, not the file, a
            // new index would succeed and orphan every profile the old one named.
            // `attributesOfItem`, not `fileExists`: `fileExists` follows links, so an index
            // symlinked onto an unmounted volume would read as absent and the atomic write would
            // replace the link.
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                throw WriteRefusal.indexUnreadable("it exists but could not be read")
            }
            return IndexReading(object: nil, activeProfileId: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WriteRefusal.indexUnreadable("it is not a JSON object")
        }
        // An unknown schema is refused, including one that isn't a number at all.
        if let version = object["schemaVersion"], !(version is NSNull) {
            // `as? Int` alone is not a number test: JSON `true` bridges to `NSNumber` as 1, so
            // `"schemaVersion": true` would pass as schema 1 here while `JSONDecoder` throws for
            // ``activeProfileId(in:)``, two readers disagreeing.
            guard !isJSONBoolean(version), let number = version as? Int else {
                throw WriteRefusal.indexUnreadable("schemaVersion is not a number")
            }
            guard number == currentSchema else {
                throw WriteRefusal.indexUnreadable("schema \(number), not \(currentSchema)")
            }
        }
        // The field that decides whether anything may be re-pointed gets the same treatment: a
        // present `activeProfileId` that isn't a string is an index this doesn't understand, not
        // one with nothing active.
        var active: String?
        if let raw = object["activeProfileId"], !(raw is NSNull) {
            guard let id = raw as? String else {
                throw WriteRefusal.indexUnreadable("activeProfileId is not a string")
            }
            active = id
        }
        // **"Active" means it names a profile that is really there.** An id naming no profile is a
        // dangling pointer, and treating it as an answer would block the bootstrap for good after a
        // hand-edit as small as a trailing space (`"father "`). Re-pointing away from a name that
        // resolves to no file can't lose anything; away from one that resolves must never happen.
        //
        // So the empty id isn't special-cased either: `appendingPathComponent` collapses it, so
        // `""` addresses `profiles/folder-profile.json`, which some layouts have. Asking the
        // filesystem answers both with one rule.
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
        // A `profiles` field that isn't a list of objects is refused rather than replaced; reading
        // it as empty would make the rewrite drop every profile the index names, the clobber
        // ``WriteRefusal/indexUnreadable`` exists to prevent.
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
            // guessed.** A folder walk doesn't know the person's name, and a guess would read as a
            // fact; but a re-derivation re-surveys a tree already identified, so it copies those
            // fields from the superseded row rather than leaving every later row nameless.
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

    /// The instant both filing artifacts date themselves with (``FilingArtifactStamp``). `now` is
    /// injected by the caller (`docs/flaky-tests.md`, "Tests racing a real-time window").
    static func stamp(_ date: Date) -> String { FilingArtifactStamp.string(from: date) }

    /// The on-disk shape, header and all. Mirrors ``FolderProfile``'s decoder field for field
    /// (`folders` as an array keyed by `path` on decode, the person axis as a `values` + `aliases`
    /// box), because decoding is the only contract between the Python builder and this module.
    struct ProfileDocument: Encodable {
        let profile: FolderProfile
        let generated: String
        let builtBy: String

        /// What the file says about itself, for whoever opens it because a suggestion looked wrong.
        /// It must describe what the writer actually produces: `anchors` and `axes` are derived and
        /// populated, and only `naming` is abstained from.
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
        /// alias pairs that let `Family/Mom` and `Granny` resolve to one person.
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
                // Omitted when nil, as the generator does: only an explicit `false` forbids filing,
                // and `null` and absent mean the same to the decoder.
                try c.encodeIfPresent(entry.acceptsNewFiles, forKey: .acceptsNewFiles)
                // The refusal's reason travels with it; the Restructure carry-over writes entries
                // that hold one.
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
            // The provenance chain: what this profile was re-derived from, which Undo re-points to.
            // Omitted for a plain walk, as the decoder tolerates.
            try c.encodeIfPresent(profile.derivedFrom, forKey: .derivedFrom)
            try c.encode(ProfileDocument.note, forKey: .note)
            try c.encode(profile.folders.count, forKey: .folderCount)
            // Written only when there is one: an empty person axis and none decode the same, and a
            // `{"person":{"values":[]}}` box would claim a survey looked and found nobody.
            if !profile.personTokens.isEmpty || !profile.personAliases.isEmpty {
                try c.encode(["person": PersonAxisBox(values: profile.personTokens.sorted(),
                                                      aliases: profile.personAliases)],
                             forKey: .axes)
            }
            // Sorted by path so the bytes depend on the profile alone: a file that reshuffles can't
            // be diffed, and its hash feeds `fingerprint(id:in:)`, which keys every cached
            // classification.
            try c.encode(profile.folders.values.sorted { $0.path < $1.path }.map(EntryBox.init),
                         forKey: .folders)
        }
    }
}
