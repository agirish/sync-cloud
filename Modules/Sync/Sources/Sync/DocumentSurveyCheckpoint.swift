import Events
import Foundation

/// Where a long document survey has got to: **the one file that must never be mistaken for a
/// corpus.**
///
/// A first survey reads page 1 of every document (hours for a large tree), so it must pause and
/// survive a quit. Its progress must not go into `filing-corpus.json`: the surveyed region
/// (``FilingSurvey/surveyedRegion(corpus:memory:)``) is derived from the corpus, and
/// ``FilingSurvey/documentsToRead(tree:corpus:memory:)`` skips everything outside it. A partial
/// corpus would make the next survey skip the rest of the tree for good while reporting success.
/// So progress goes here, in a file ``FilingSurveyStore`` never opens, and the corpus is written
/// once, whole, at the end.
///
/// The `kind` field guards the other way: `FilingCorpus`'s decoder is lenient, so this file at the
/// corpus path would decode as an empty corpus and the next write would erase learned content.
/// `FilingCorpus` refuses any other `kind`; `SurveyProgressIsNotACorpusTests` pins it.
///
/// The plan is stored, not re-derived, so the "2,871 of 7,558" the user watches keeps its meaning.
/// Files that change meanwhile are left to the incremental pass
/// (``FileSyncManager/resurveyFilingMemory(root:taxonomy:now:)``).
public struct DocumentSurveyCheckpoint: Sendable, Equatable {

    /// Bumped when the shape changes. Independent of ``FilingCorpus/currentSchema``.
    public static let currentSchema = 1

    /// What this document is. Written into every checkpoint, and the string `FilingCorpus` refuses.
    public static let kind = "survey-progress"

    /// The profile directory id the artifacts were read under, as `resurveyFilingMemory` keys, so
    /// one profile's survey can't land in another's corpus.
    public let profileId: String
    /// The root that was walked, as a path. A resume against a different root is not a resume.
    public let rootPath: String
    /// The salt every ``read`` id hash was produced under, so a resume can't mix hash spaces:
    /// resumed under another salt, its hashes would match nothing.
    public let salt: String
    /// The work list this run is walking, fixed when it started (see the type's note).
    public let plan: [String]
    /// How far into ``plan`` the run has got. Everything before it is decided (read, stamped blank,
    /// or skipped as unavailable); nothing from it on has been looked at.
    public let nextIndex: Int
    /// What has been read so far, keyed as a corpus's documents are (path relative to the root).
    /// **Named `read`, not `documents`**, the corpus's field, so this can never decode as a partial
    /// corpus.
    public let read: [String: FilingCorpusDocument]
    /// Documents skipped so far because their content was not on this disk. Carried so a resumed
    /// survey's summary still counts the first sitting's. Defaults to 0 when absent, so an older
    /// checkpoint still decodes, at the cost of a low count.
    public let documentsUnavailable: Int
    public let startedAt: Date
    public let updatedAt: Date

    public init(profileId: String, rootPath: String, salt: String, plan: [String],
                nextIndex: Int, read: [String: FilingCorpusDocument],
                documentsUnavailable: Int = 0,
                startedAt: Date, updatedAt: Date) {
        self.profileId = profileId
        self.rootPath = rootPath
        self.salt = salt
        self.plan = plan
        self.nextIndex = nextIndex
        self.read = read
        self.documentsUnavailable = documentsUnavailable
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// The documents this run has still to look at.
    ///
    /// Clamped, because the file can be hand-edited and an index past the end would trap on the
    /// slice. Past the end means nothing left.
    public var remaining: ArraySlice<String> {
        guard nextIndex >= 0 else { return plan[...] }
        guard nextIndex < plan.count else { return [] }
        return plan[nextIndex...]
    }

    /// Documents decided so far, against the plan's total — what the running card counts.
    public var progress: (done: Int, total: Int) {
        (min(max(nextIndex, 0), plan.count), plan.count)
    }

    /// Whether this checkpoint describes the run the caller is about to continue.
    ///
    /// **A disagreement is discarded, never merged.** Starting over costs hours; merging would
    /// corrupt the corpus every filing suggestion is scored against.
    public func resumes(profileId: String, rootPath: String, salt: String) -> Bool {
        self.profileId == profileId && self.rootPath == rootPath && self.salt == salt
    }
}

// MARK: - On-disk shape

extension DocumentSurveyCheckpoint: Codable {
    private enum Key: String, CodingKey {
        case schemaVersion, kind, note, profileId, rootPath, salt, plan, nextIndex, read
        case documentsUnavailable, startedAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        // A foreign schema is discarded rather than half-read, as for every filing artifact.
        if let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion),
           v != DocumentSurveyCheckpoint.currentSchema {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "survey progress schema \(v) is not \(DocumentSurveyCheckpoint.currentSchema)")
        }
        // **Required, unlike the corpus's**, so a corpus can never read as progress, nor progress
        // as a corpus. No file predates the field.
        let kind = try c.decode(String.self, forKey: .kind)
        guard kind == DocumentSurveyCheckpoint.kind else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "\(kind) is not survey progress")
        }
        profileId = try c.decode(String.self, forKey: .profileId)
        rootPath = try c.decode(String.self, forKey: .rootPath)
        salt = try c.decode(String.self, forKey: .salt)
        plan = try c.decodeIfPresent([String].self, forKey: .plan) ?? []
        nextIndex = try c.decodeIfPresent(Int.self, forKey: .nextIndex) ?? 0
        read = try c.decodeIfPresent([String: FilingCorpusDocument].self, forKey: .read) ?? [:]
        documentsUnavailable = try c.decodeIfPresent(Int.self, forKey: .documentsUnavailable) ?? 0
        startedAt = (try? c.decodeIfPresent(String.self, forKey: .startedAt))
            .flatMap { $0 }.flatMap(FilingArtifactStamp.date(from:)) ?? Date()
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt))
            .flatMap { $0 }.flatMap(FilingArtifactStamp.date(from:)) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(DocumentSurveyCheckpoint.currentSchema, forKey: .schemaVersion)
        try c.encode(DocumentSurveyCheckpoint.kind, forKey: .kind)
        try c.encode(profileId, forKey: .profileId)
        try c.encode(rootPath, forKey: .rootPath)
        try c.encode(salt, forKey: .salt)
        try c.encode(plan, forKey: .plan)
        try c.encode(nextIndex, forKey: .nextIndex)
        try c.encode(read, forKey: .read)
        try c.encode(documentsUnavailable, forKey: .documentsUnavailable)
        try c.encode(FilingArtifactStamp.string(from: startedAt), forKey: .startedAt)
        try c.encode(FilingArtifactStamp.string(from: updatedAt), forKey: .updatedAt)
        try c.encode("""
            Where an unfinished document survey got to. NOT a corpus — filing-corpus.json is \
            written once, whole, when the survey finishes, because the surveyed region is derived \
            from it and a partial one would make the next survey skip the rest of the tree \
            forever. Safe to delete: doing so costs the unfinished survey and nothing else.
            """, forKey: .note)
    }
}

// MARK: - Reading and writing it

/// The checkpoint's own store, apart from ``FilingSurveyStore``: a checkpoint is not a filing
/// artifact. Nothing scores against it, and deleting it costs an unfinished survey, not learned
/// content. ``FilingSurveyStore/corpusRead(id:in:)`` has no reason to know this file exists.
public enum DocumentSurveyCheckpointStore {

    /// **Deliberately not `filing-corpus…`**: a `corpus*` glob, or an instruction to "delete the
    /// corpus files", must never reach this file or mistake it for a corpus.
    public static let filename = "survey-progress.json"

    public static func url(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id)/\(filename)")
    }

    /// How a checkpoint read went, in the three states of ``FilingSurveyStore/CorpusRead``. Absent
    /// means no survey was interrupted, so start fresh. Unreadable must not be treated as absent:
    /// that restarts an hours-long read a fixed permission bit would have recovered.
    public enum Read: Sendable {
        case absent
        case unreadable
        case loaded(DocumentSurveyCheckpoint)

        public var checkpoint: DocumentSurveyCheckpoint? {
            if case .loaded(let c) = self { return c }
            return nil
        }
    }

    /// The checkpoint for `id`, saying which of the three states it found.
    ///
    /// `attributesOfItem`, not `fileExists`, which follows symlinks: a link to an unmounted volume
    /// would read as absent and the next write would replace the link itself.
    public static func read(id: String, in directory: URL) -> Read {
        let url = self.url(id: id, in: directory)
        guard let data = try? Data(contentsOf: url) else {
            guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
                Logger.shared.warning("Survey progress at \(url.path) exists but could not be "
                                      + "opened — permission, an ACL, an I/O error or a broken "
                                      + "link. An unfinished survey cannot be resumed from it.")
                return .unreadable
            }
            return .absent
        }
        do {
            return .loaded(try JSONDecoder().decode(DocumentSurveyCheckpoint.self, from: data))
        } catch {
            Logger.shared.warning("Couldn't read the survey progress: \(error.localizedDescription)")
            return .unreadable
        }
    }

    /// Writes the checkpoint atomically. Throws rather than logs: a survey that can't record where it
    /// is is no longer resumable, and only its caller can decide what to do.
    public static func write(_ checkpoint: DocumentSurveyCheckpoint, id: String,
                             in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(checkpoint).write(to: url(id: id, in: directory), options: .atomic)
    }

    /// Removes the checkpoint: the survey finished or was abandoned. Absent counts as success.
    ///
    /// **Call it after the corpus lands, never before.** A crash between the two leaves a complete
    /// corpus beside a checkpoint, which is harmless; the other order could leave neither.
    public static func discard(id: String, in directory: URL) throws {
        let url = self.url(id: id, in: directory)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as NSError
                    where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
        }
    }
}
