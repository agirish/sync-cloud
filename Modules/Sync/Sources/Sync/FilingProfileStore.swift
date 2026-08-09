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
/// rebuild, written atomically, and only when it differs from what is there. The folder profile is
/// still never written from here or from there.
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
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("profiles.json")),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        guard index.schemaVersion ?? currentSchema == currentSchema else {
            Logger.shared.warning("Filing profile index has an unknown schema — ignoring it")
            return nil
        }
        return index.activeProfileId
    }

    /// The folder profile for `id`, or nil when absent or unreadable.
    public static func profile(id: String, in directory: URL) -> FolderProfile? {
        decode(FolderProfile.self, at: directory.appendingPathComponent("\(id)/folder-profile.json"),
               what: "folder profile")
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
            hasher.update(data: data)
        }
        guard any else { return "" }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
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
