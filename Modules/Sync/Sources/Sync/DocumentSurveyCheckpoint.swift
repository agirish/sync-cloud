import Events
import Foundation

/// Where a long document survey has got to — **the one file that must never be mistaken for a
/// corpus.**
///
/// ## Why this exists at all
///
/// The first survey of a tree reads page 1 of every document in it: ~11,000 files, roughly three
/// hours. It has to be pausable, and it has to survive a quit, so progress has to reach disk long
/// before the survey is finished. The obvious place to put that progress is `filing-corpus.json`,
/// and that is the trap.
///
/// ``FilingSurvey/surveyedRegion(corpus:memory:)`` is derived from the corpus — every ancestor of
/// every surveyed document, closed upwards — and ``FilingSurvey/documentsToRead(tree:corpus:memory:)``
/// **skips anything outside that region**, with an empty region meaning "unscoped", which is the
/// only sensible reading for a tree nothing has ever looked at. So a half-finished corpus on disk
/// makes the region cover only the part of the tree that has been read. The next survey then skips
/// the entire remainder — permanently, because the region never grows back — and reports *0
/// documents read*, which is exactly what a settled tree reports. Hours of work silently thrown
/// away, and the report says success.
///
/// So progress goes here, in a file ``FilingSurveyStore`` never opens, and `filing-corpus.json` is
/// written **once, whole, at the end**. `surveyedRegion` stays a pure function of a complete corpus.
///
/// ## Two doors, and both are shut
///
/// The paragraph above shuts the first door: nothing writes a partial corpus. The second is
/// narrower and was found by asking what happens if this file ever *arrives* at the corpus path —
/// a recovery script, a hand copy, a future refactor that reuses `corpusURL`. `FilingCorpus`'s
/// decoder is deliberately lenient (every field is `decodeIfPresent ?? default`), so before the
/// `kind` guard landed alongside this type, such a file decoded **successfully, as an empty
/// corpus** — `.loaded`, not `.unreadable`, so the survey's byte-preserving refusal never ran and
/// the next write replaced months of learned content with nothing.
///
/// That is why this file says what it is in a `kind` field, and why `FilingCorpus` now refuses any
/// document whose `kind` names something else. `SurveyProgressIsNotACorpusTests` is the pin.
///
/// ## What a resume may and may not assume
///
/// The plan is **stored, not re-derived**. Re-deriving on resume would be defensible — the tree may
/// have moved — but it makes the denominator the user is watching change underneath them, so "2,871
/// of 7,558" would stop meaning anything. Files that changed while the survey ran are the
/// *incremental* pass's job (``FileSyncManager/resurveyFilingMemory(root:taxonomy:now:)``), which is
/// what runs from then on. A survey answers the question it was started with.
public struct DocumentSurveyCheckpoint: Sendable, Equatable {

    /// Bumped when the shape changes. Independent of ``FilingCorpus/currentSchema`` — the two files
    /// have nothing to do with each other, which is the whole point of this type.
    public static let currentSchema = 1

    /// What this document is. Written into every checkpoint, and the string `FilingCorpus` refuses.
    public static let kind = "survey-progress"

    /// The profile directory id this run belongs to — the id the artifacts were read *under*, which
    /// is what `resurveyFilingMemory` learned to key on after a run wrote `work/`'s survey into
    /// `default/`'s corpus.
    public let profileId: String
    /// The root that was walked, as a path. A resume against a different root is not a resume.
    public let rootPath: String
    /// The salt every ``read`` id hash was produced under.
    ///
    /// **Carried here so a resume cannot mix hash spaces.** The corpus and the memory already
    /// refuse each other over a salt disagreement; a checkpoint written under one salt and resumed
    /// under another would contribute hashes nothing can ever match — the same failure, arriving
    /// hours later and with no file to compare against.
    public let salt: String
    /// The work list this run is walking, fixed when it started. See the type's note on why it is
    /// not re-derived.
    public let plan: [String]
    /// How far into ``plan`` the run has got. Everything before it has been decided — read,
    /// stamped blank, or skipped as unavailable — and everything from it on has not been looked at.
    public let nextIndex: Int
    /// What has been read so far, keyed exactly as a corpus's documents are: path relative to the
    /// root.
    ///
    /// **Named `read` rather than `documents`, and that is not a style choice.** It is the field a
    /// corpus would look for, and a checkpoint that spelled it the corpus's way would be a
    /// partial corpus wearing a different filename — one `mv` from the failure this whole type
    /// exists to prevent.
    public let read: [String: FilingCorpusDocument]
    /// Documents skipped so far because their content was not on this disk.
    ///
    /// **Carried because the completion summary is explicit about this number.** `read` survived a
    /// resume and this did not, so a survey stopped and carried on reported every not-downloaded
    /// document from the first sitting as though it had never been looked at — understating, in the
    /// one figure the summary exists to state plainly. Defaulted so a checkpoint written before
    /// this field still decodes; the cost of the default is a resumed count that is low rather than
    /// a decode failure that costs the whole survey.
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
    /// Clamped rather than trusting `nextIndex`: the file is on disk, it can be hand-edited, and an
    /// index past the end would trap on the slice. An out-of-range index means "nothing left",
    /// which is the safe reading — the alternative is a crash on resume.
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
    /// **A disagreement is discarded, never merged.** Starting over costs hours; merging costs
    /// correctness, and the corpus that comes out the far end is the artifact every filing
    /// suggestion is scored against. There is no repair worth attempting here.
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
        // A foreign schema is discarded rather than half-read, the same rule every other filing
        // artifact follows. Discarding costs a re-run of a survey that had not finished anyway.
        if let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion),
           v != DocumentSurveyCheckpoint.currentSchema {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "survey progress schema \(v) is not \(DocumentSurveyCheckpoint.currentSchema)")
        }
        // **Required, unlike the corpus's.** This type is young and nothing in the wild predates
        // it, so there is no compatibility to buy by being lenient — and the strictness is the
        // point in both directions: a corpus must not read as progress any more than progress may
        // read as a corpus.
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

/// The checkpoint's own store, kept apart from ``FilingSurveyStore`` on purpose.
///
/// That type's doc comment opens by calling itself "the one place in the app that writes a filing
/// artifact", and this does not make it two: a checkpoint is not a filing artifact. Nothing scores
/// against it, nothing is fingerprinted from it, and deleting it costs an unfinished survey rather
/// than learned content. Keeping the two stores separate is what keeps that distinction legible —
/// and keeps ``FilingSurveyStore/corpusRead(id:in:)`` with no reason to know this file exists.
public enum DocumentSurveyCheckpointStore {

    /// **Deliberately not `filing-corpus…`.** The name is part of the guard: a `corpus*` glob in a
    /// backup script, a support instruction to "delete the corpus files", or a future reader
    /// pattern-matching on the prefix must not reach this, and must not mistake this for that.
    public static let filename = "survey-progress.json"

    public static func url(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id)/\(filename)")
    }

    /// How a checkpoint read went — the same three states, for the same reason,
    /// as ``FilingSurveyStore/CorpusRead``.
    ///
    /// **The consequences are milder here and the distinction still earns its place.** Absent means
    /// "no survey was interrupted", and starting fresh is right. Unreadable says nothing about what
    /// was surveyed — and a caller that treats it as absent restarts a three-hour read that may
    /// have been minutes from done, on a file a fixed permission bit would have recovered.
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
    /// `attributesOfItem` rather than `fileExists` for the reason the sibling stores give:
    /// `fileExists` follows symlinks and answers false for one whose target sits on an unmounted
    /// volume, so a link would read as absent and the next write would replace the link itself.
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

    /// Writes the checkpoint atomically. Throws rather than logging: a survey that cannot record
    /// where it is has stopped being resumable, and its caller is the only thing that can decide
    /// what to do about that.
    public static func write(_ checkpoint: DocumentSurveyCheckpoint, id: String,
                             in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(id),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(checkpoint).write(to: url(id: id, in: directory), options: .atomic)
    }

    /// Removes the checkpoint — the survey either finished or was abandoned.
    ///
    /// **Called after the corpus lands, never before.** Between the two writes there is a window
    /// where both files exist, and that is the correct order: a crash there leaves a resumable
    /// checkpoint beside a complete corpus, and the next run finds the corpus already covers the
    /// tree. The other order leaves a crash with neither.
    ///
    /// Absent is success. This is cleanup, and a caller that has just finished a three-hour survey
    /// must not be handed an error because the thing it wanted gone was already gone.
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
