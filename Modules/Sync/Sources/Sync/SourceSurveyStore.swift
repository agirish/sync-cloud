import Events
import Foundation

/// Which survey a source's files are placed with, as the user left it (GK–GN, 2026-10-31).
///
/// `.primary` is "use iCloud's survey" — the active profile, whatever tree it records; `.own` is
/// the source's own survey, learned from its folders. Nil (no entry, or an entry with no choice) is
/// the measured default: see ``FilingSurveyInUse/resolve(providerRoot:primaryRoot:entry:hasOwn:matched:total:)``.
public enum SourceSurveyChoice: String, Codable, Sendable, Equatable {
    case primary
    case own
}

/// One source's record in `profiles/source-surveys.json`.
public struct SourceSurveyEntry: Codable, Sendable, Equatable {
    /// The tree To File files into for that source — its anchor, absolute.
    public var root: String
    /// The source's own survey, under `profiles/<id>/folder-profile.json`, once learned.
    public var profileId: String?
    public var learnedAt: Date?
    public var folderCount: Int?
    public var choice: SourceSurveyChoice?

    public init(root: String, profileId: String? = nil, learnedAt: Date? = nil,
                folderCount: Int? = nil, choice: SourceSurveyChoice? = nil) {
        self.root = root
        self.profileId = profileId
        self.learnedAt = learnedAt
        self.folderCount = folderCount
        self.choice = choice
    }
}

/// The surveys a source has besides the primary one, and the choices made per source.
///
/// **Its own file, beside `profiles.json` rather than inside it.** `profiles.json` names the ONE
/// active profile, and every path that writes it — Setup's walk, a Restructure re-derive, Undo — may
/// re-point it at what it just wrote. A source's survey must never become the active profile: it
/// would aim iCloud's To File, Restructure and Ask Claude at Google Drive. So its profile is
/// written with ``FilingProfileStore/writeSourceProfile(_:in:now:)``, which never touches the index,
/// and it is listed here instead. A profile with no `profiles.json` row is also one
/// ``FilingProfileStore/retireSupersededProfiles(protecting:in:fileManager:)`` never sweeps.
public enum SourceSurveyStore {

    public static let currentSchema = 1
    public static let fileName = "source-surveys.json"

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var note: String?
        var sources: [SourceSurveyEntry]
    }

    static let note = "Per-source folder surveys and choices (SyncCloud). profiles.json still names "
        + "the primary survey; a source listed here with a profileId has its own."

    private static func coders() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    /// Every entry, or none when the file is absent, unreadable or of another schema — which is
    /// every source on its measured default, the behaviour before this file existed.
    public static func entries(in directory: URL) -> [SourceSurveyEntry] {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return [] }
        guard let document = try? coders().1.decode(Document.self, from: data),
              document.schemaVersion == currentSchema else {
            Logger.shared.warning("Source surveys: \(fileName) could not be read — every source "
                                  + "uses its measured default")
            return []
        }
        return document.sources
    }

    /// The entry for `root`, matched as one folder however it is spelled (a link, a trailing slash,
    /// case on a case-insensitive volume).
    public static func entry(forRoot root: String, in directory: URL) -> SourceSurveyEntry? {
        entries(in: directory).first { sameFolder($0.root, root) }
    }

    /// Changes the entry for `root` — creating it when absent — and writes the file atomically.
    /// An entry left with nothing in it is dropped, so the file only lists sources with a record.
    public static func update(root: String, in directory: URL,
                              _ change: (inout SourceSurveyEntry) -> Void) throws {
        var all = entries(in: directory)
        let index = all.firstIndex { sameFolder($0.root, root) }
        var entry = index.map { all[$0] } ?? SourceSurveyEntry(root: root)
        change(&entry)
        let empty = entry.profileId == nil && entry.choice == nil
        switch (index, empty) {
        case (let i?, true): all.remove(at: i)
        case (let i?, false): all[i] = entry
        case (nil, false): all.append(entry)
        case (nil, true): return
        }
        try write(all, in: directory)
    }

    static func write(_ entries: [SourceSurveyEntry], in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = Document(schemaVersion: currentSchema, note: note,
                                sources: entries.sorted { $0.root < $1.root })
        try coders().0.encode(document).write(to: url(in: directory), options: .atomic)
    }

    /// Whether two recorded roots are one folder.
    public static func sameFolder(_ a: String, _ b: String) -> Bool {
        PathBoundary.resolvesToSameDirectory(a, b, caseSensitive: false)
    }
}

extension FilingProfileStore {

    /// Writes a source's own survey as `profiles/<id>/folder-profile.json` and **never touches
    /// `profiles.json`** — the one difference from ``writeProfile(_:in:builtBy:now:)``, and the
    /// reason this exists (see ``SourceSurveyStore``). Same refusals otherwise: an existing profile
    /// is never overwritten, and the file lands atomically in the shape the generator writes.
    @discardableResult
    public static func writeSourceProfile(_ profile: FolderProfile, in directory: URL,
                                          builtBy: String = "SyncCloud — source folder survey",
                                          now: Date = Date()) throws -> URL {
        let id = profile.profileId
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw WriteRefusal.invalidProfileId(id)
        }
        let url = profileURL(id: id, in: directory)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriteRefusal.profileExists(id: id)
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(ProfileDocument(profile: profile, generated: stamp(now),
                                                       builtBy: builtBy))
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw WriteRefusal.profileExists(id: id)
        }
        try land(bytes, at: url, index: nil, at: indexURL(in: directory))
        return url
    }
}
