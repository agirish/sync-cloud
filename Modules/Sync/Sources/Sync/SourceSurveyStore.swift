import Events
import Foundation

/// Which survey a source's files are placed with, as the user left it.
///
/// `.primary` is "use iCloud's survey", the active profile; `.own` is the source's own survey,
/// learned from its folders. Nil (no entry, or no choice) is the measured default: see
/// ``FilingSurveyInUse/resolve(providerRoot:primaryRoot:entry:hasOwn:matched:total:)``.
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
    /// When Read Documents last finished for this survey, and how many documents it read; nil
    /// until it has (or in an older file).
    public var documentsReadAt: Date?
    public var documentsRead: Int?

    public init(root: String, profileId: String? = nil, learnedAt: Date? = nil,
                folderCount: Int? = nil, choice: SourceSurveyChoice? = nil,
                documentsReadAt: Date? = nil, documentsRead: Int? = nil) {
        self.root = root
        self.profileId = profileId
        self.learnedAt = learnedAt
        self.folderCount = folderCount
        self.choice = choice
        self.documentsReadAt = documentsReadAt
        self.documentsRead = documentsRead
    }
}

/// The surveys a source has besides the primary one, and the choices made per source.
///
/// Its own file beside `profiles.json`, not inside it. `profiles.json` names the one active
/// profile, and every path that writes it (Setup, Restructure, Undo) may re-point it. A source's
/// survey must never become the active profile, or iCloud's To File, Restructure and Ask Claude
/// would aim at Google Drive. So its profile is written with
/// ``FilingProfileStore/writeSourceProfile(_:in:builtBy:now:)``, which never touches the index, and
/// listed here. With no `profiles.json` row,
/// ``FilingProfileStore/retireSupersededProfiles(protecting:in:fileManager:)`` never sweeps it.
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

    /// Every entry, or none when the file is absent, unreadable or of another schema, which puts
    /// every source on its measured default.
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
    /// `profiles.json`**, unlike ``writeProfile(_:in:builtBy:now:)`` (see ``SourceSurveyStore``).
    /// Same refusals otherwise: an existing profile is never overwritten, and the file lands
    /// atomically.
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
