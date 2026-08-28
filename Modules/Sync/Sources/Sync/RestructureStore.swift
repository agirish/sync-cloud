import Events
import Foundation

/// One thing Restructure remembers, named by what noticed it and where.
///
/// `kind × path` is the identity everything in ``RestructureStore`` shares — a suppression, an
/// answer, and (from §5.4/§5.5) a draft and a ledger entry all key on it, which is what lets one
/// decision serve four sections (ROADMAP_V5 §5.0). The path is the finding's **subject** — the most
/// specific folder it is about — for the same reason ``StructureFinding/id`` is: the family alone
/// is not unique for every kind.
public struct RestructureKey: Hashable, Codable, Sendable {
    /// Which detector's observation this remembers.
    public let kind: FindingKind
    /// The subject folder, relative to the profile root.
    public let path: String

    public init(kind: FindingKind, path: String) {
        self.kind = kind
        self.path = path
    }

    /// A key for a finding is the finding's own identity, spelled once.
    public init(_ finding: StructureFinding) {
        self.init(kind: finding.kind, path: finding.subject)
    }

    /// The ``StructureFinding/id`` this key corresponds to — the one spelling of the composite
    /// identity, so a caller joining store sections to rendered findings never re-derives the
    /// format by hand (two spellings of `kind|path` is how they drift apart).
    public var findingId: String { "\(kind.rawValue)|\(path)" }
}

/// Everything Restructure remembers, in one app-owned file — `restructure.json`, beside
/// `people.json`.
///
/// **One store, not four** (ROADMAP_V5 §5.0, decisions block): suppressions, Ask answers, drafted
/// plans and the applied ledger share the `kind × path` identity, so they share a file — all four
/// sections are modelled now. The decoder still carries any section it does not model across a
/// save rather than deleting it, the same discipline ``PeopleStore`` has for hand-added keys.
///
/// Writes are whole-file and atomic, like every store beside it (`PeopleStore`, `PersonTagStore`,
/// `StorageLensStore`, `FilingVerdictCache`): the file is small, a rewrite costs nothing, and a
/// partial write would be worse than none.
///
/// **What survives what** is the design (ROADMAP_V5 §5.0): every section survives a re-survey,
/// because the keys are paths and the profile can be replaced underneath them. What a section does
/// *not* survive is its path moving — an Apply replays its manifest onto these keys through
/// ``rekey(renames:)``, exactly as §5.5 replays it onto the corpus and the memory.
@MainActor
public final class RestructureStore: ObservableObject {

    /// Findings the user said never to suggest again. Read by the lens before rendering and by
    /// the rail badge; written by *Never suggest this again* on any card.
    @Published public private(set) var suppressed: Set<RestructureKey> = []

    /// Chosen options for Ask findings, so the detector that asked never asks twice (§5.3).
    @Published public private(set) var answers: [RestructureKey: String] = [:]

    /// Drafted plans, keyed on `kind × family` — §5.7's *Planned, not applied*: a draft survives
    /// the sheet closing, the app quitting, and a re-survey, because the key is a path and the
    /// profile can be replaced underneath it. What it does not survive is its family ceasing to
    /// exist, which the card says.
    @Published public private(set) var drafts: [RestructureKey: DraftRecord] = [:]

    public struct DraftRecord: Codable, Equatable, Sendable {
        /// The plan as derived when the sheet last saved — mapping rows in its header, actions
        /// ordered as they would run.
        public var manifest: RestructureManifest
        /// When the draft was saved, injected by the writer.
        public var savedAt: String
        /// The file `Export plan…` wrote, relative to the profile folder — nil for a draft that
        /// was saved without exporting.
        public var exportedTo: String?
        /// The sheet's full picker vocabulary when the draft was saved — the chosen scheme's
        /// names plus any typed ones, INCLUDING names no row currently uses. Without it a
        /// reopened draft could only rebuild the vocabulary from the rows' targets, so every
        /// unused choice vanished and "reopens the plan as it was left" was false. Optional:
        /// a draft saved by an earlier build reopens with the rows' targets alone, as before.
        public var vocabulary: [String]?

        public init(manifest: RestructureManifest, savedAt: String, exportedTo: String? = nil,
                    vocabulary: [String]? = nil) {
            self.manifest = manifest
            self.savedAt = savedAt
            self.exportedTo = exportedTo
            self.vocabulary = vocabulary
        }
    }

    /// The applied ledger — one record per landing, in the order they landed (§5.0's `applied`
    /// section, §5.5's step 2 home). The inverse is ON DISK from the moment a landing starts,
    /// which is what makes a reorganisation undoable after a quit, from here, not only with ⌘Z.
    ///
    /// **Keyed by manifest id and never re-keyed**: unlike the sections above, a ledger entry is
    /// a record of what happened at the time it happened — replaying a later manifest onto its
    /// paths would rewrite history to say the earlier landing touched folders it never saw.
    @Published public private(set) var applied: [AppliedRecord] = []

    public struct AppliedRecord: Codable, Equatable, Sendable {
        /// `var`, not `let`, since §5.5: a landing finalises the manifest with what actually
        /// happened — collision names, bytes, digests — and the inverse is recomputed from that,
        /// because the inverse of the PLAN would move files back from names they never landed at.
        public var manifest: RestructureManifest
        public var inverse: RestructureManifest
        /// The landing's stamp, injected by the writer.
        public let at: String
        /// Outcome counts — what actually happened, against what the manifest predicted.
        public var created: Int
        public var skipped: Int
        /// §5.5 step 6's ids — nil until a landing re-derives the profile (the scaffold records
        /// without one; a plan apply always fills both, or says why in `summary`).
        public var appliedUnderProfileId: String?
        public var producedProfileId: String?
        /// The landing's one-line ledger sentence — what the Applied card renders.
        public var summary: String?
        /// Stamped when *Undo this reorganisation* ran this record's inverse — the Undone state's
        /// evidence, and the guard against running it twice.
        public var undoneAt: String?
        /// What the undo run did — the Undone card's sentence, which never pretends the tree was
        /// untouched: a file that had moved on and was skipped is in this line's skip count and
        /// named in the log (§5.7).
        public var undoSummary: String?

        public init(manifest: RestructureManifest, inverse: RestructureManifest, at: String,
                    created: Int, skipped: Int, appliedUnderProfileId: String? = nil,
                    producedProfileId: String? = nil, summary: String? = nil,
                    undoneAt: String? = nil, undoSummary: String? = nil) {
            self.manifest = manifest
            self.inverse = inverse
            self.at = at
            self.created = created
            self.skipped = skipped
            self.appliedUnderProfileId = appliedUnderProfileId
            self.producedProfileId = producedProfileId
            self.summary = summary
            self.undoneAt = undoneAt
            self.undoSummary = undoSummary
        }
    }

    /// Whether something sits at `restructure.json`'s path that this build could not read — a
    /// syntax error, an I/O failure, or a schema newer than this build writes.
    ///
    /// **A file this build could not read is a file it must not rewrite.** Every save below is a
    /// whole-file atomic write of the state now in memory, and when the load failed that state is
    /// empty — writing it would replace the real file with nothing. The store stays usable in
    /// memory for the session; the refusal is only about the disk.
    @Published public private(set) var isUnreadable = false

    /// Where the file was read from and is written to — the profiles directory and the folder
    /// inside it, both as handed over at construction, for the reason ``PeopleStore/directory``
    /// documents: the id inside a profile file and the folder it was read from can disagree.
    let directory: URL
    let profileId: String
    private let fileManager: FileManager

    /// Top-level keys in the file this build does not model — a future build's sections, and
    /// anything hand-added — carried across every save untouched. (All four planned sections
    /// are modelled now; this is what let `drafts` and `applied` arrive without a migration,
    /// and what lets the next section do the same.)
    private var carriedKeys: [String: Any] = [:]

    /// `restructure.json` for the active profile.
    public var fileURL: URL {
        directory.appendingPathComponent("\(profileId)/restructure.json")
    }

    public init(directory: URL, profileId: String, fileManager: FileManager = .default) {
        self.directory = directory
        self.profileId = profileId
        self.fileManager = fileManager
        load()
    }

    // MARK: - Suppressions

    public func isSuppressed(_ key: RestructureKey) -> Bool { suppressed.contains(key) }

    public func suppress(_ key: RestructureKey) {
        guard !suppressed.contains(key) else { return }
        suppressed.insert(key)
        // Each of these mutators logs: "never suggest this again" and its kin are consequential,
        // persistent decisions, and the log is the only place they can be dated later.
        Logger.shared.info("Restructure: suppressed \(key.findingId)")
        save()
    }

    public func unsuppress(_ key: RestructureKey) {
        guard suppressed.contains(key) else { return }
        suppressed.remove(key)
        Logger.shared.info("Restructure: unsuppressed \(key.findingId)")
        save()
    }

    // MARK: - Answers

    public func answer(for key: RestructureKey) -> String? { answers[key] }

    public func recordAnswer(_ choice: String, for key: RestructureKey) {
        guard answers[key] != choice else { return }
        answers[key] = choice
        Logger.shared.info("Restructure: answered \(key.findingId) — \(choice)")
        save()
    }

    public func removeAnswer(for key: RestructureKey) {
        guard answers[key] != nil else { return }
        answers[key] = nil
        Logger.shared.info("Restructure: answer removed for \(key.findingId)")
        save()
    }

    // MARK: - Drafts

    public func draft(for key: RestructureKey) -> DraftRecord? { drafts[key] }

    public func saveDraft(_ record: DraftRecord, for key: RestructureKey) {
        guard drafts[key] != record else { return }
        drafts[key] = record
        Logger.shared.info("Restructure: draft saved for \(key.findingId) — "
                           + "\(record.manifest.actions.count) action(s)")
        save()
    }

    public func removeDraft(for key: RestructureKey) {
        guard drafts[key] != nil else { return }
        drafts[key] = nil
        Logger.shared.info("Restructure: draft removed for \(key.findingId)")
        save()
    }

    /// Writes `manifest` beside the profile as `restructure-<date>-<family>.json` — reviewable
    /// in a text editor with nothing at risk (§5.4 step 5). Returns the file name it chose.
    ///
    /// This is a NEW file, not `restructure.json`, so it is written even when the store itself is
    /// refusing writes — the refusal protects the one file this build could not read. The name
    /// is date + family, so a SAME-DAY re-export for the family replaces the earlier file even
    /// when the plan was edited in between — deliberate: the newest reviewed plan is the one
    /// worth keeping, and two same-day files differing only in a suffix would leave a reader
    /// guessing which one was reviewed last. (An older draft's `exportedTo` can therefore name
    /// a file whose content is the newer plan.)
    @discardableResult
    public func exportPlan(_ manifest: RestructureManifest) throws -> String {
        let date = manifest.createdAt.prefix(while: { $0 != "T" })
        let family = manifest.family.replacingOccurrences(of: "/", with: "-")
        let name = "restructure-\(date)-\(family).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = directory.appendingPathComponent("\(profileId)/\(name)")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        // One greppable line, the scaffold's discipline: the export is an act a later reader
        // may need to date and locate without the app open.
        Logger.shared.info("Restructure plan exported — \(name): "
                           + "\(manifest.actions.count) action(s) for \(manifest.family), "
                           + "beside profile \(profileId)")
        return name
    }

    // MARK: - The ledger

    /// Appends one landing's record. The write is immediate and whole-file, like every mutation
    /// here — §5.5 step 2 calls this with outcome *in progress* semantics folded into the counts
    /// the caller passes, and a crash after this call leaves a reversible record on disk.
    ///
    /// Returns whether the record REACHED the disk — the one mutation where the caller must
    /// know: §5.5's invariant is "inverse on disk before the first operation", and a swallowed
    /// write failure here would let a full reorganisation run with no record anywhere once the
    /// app quits. Every other mutator can shrug a failed save off as in-memory-only; this one
    /// is the licence to move files.
    @discardableResult
    public func recordApplied(_ record: AppliedRecord) -> Bool {
        applied.append(record)
        guard save() else {
            // The record never reached the disk, so it must not survive in memory either: the
            // caller refuses the landing on `false`, and a phantom in-memory entry would make
            // the RETRY refuse too — through the lands-once guard, with a sentence claiming a
            // landing that never happened.
            applied.removeLast()
            return false
        }
        return true
    }

    /// §5.5's undo chain, in one spelling — the ONE landing *Undo this reorganisation* may run,
    /// or nil. A reorganisation is a record `applyPlan` wrote (`appliedUnderProfileId` is set at
    /// its step 2; scaffold records never carry one). Only the newest not-undone reorganisation
    /// is offered, because an older record's inverse describes a tree a later landing reshaped.
    /// It must have finished recording (`summary` is set when a landing finalises; a record
    /// without one is a landing the app quit in the middle of, whose stored inverse may not
    /// match what actually moved), and the survey must still be where the landing left it — the
    /// produced directory when the re-derive landed, or the applied-under directory when step 6
    /// failed before it could re-point.
    public func undoableReorganisation(currentProfileId: String?) -> AppliedRecord? {
        guard let record = applied.last(where: {
            $0.appliedUnderProfileId != nil && $0.undoneAt == nil
        }), record.summary != nil,
        let current = currentProfileId,
        (record.producedProfileId ?? record.appliedUnderProfileId) == current
        else { return nil }
        return record
    }

    /// Replaces the record with `manifestId`'s manifest — how a landing finalises its counts.
    public func updateApplied(manifestId: String,
                              _ change: (inout AppliedRecord) -> Void) {
        guard let index = applied.firstIndex(where: { $0.manifest.manifestId == manifestId })
        else {
            Logger.shared.warning("restructure.json holds no record \(manifestId) to update — "
                                  + "the change was dropped")
            return
        }
        var record = applied[index]
        change(&record)
        guard record != applied[index] else { return }
        applied[index] = record
        save()
    }

    // MARK: - Replay

    /// Re-keys every section for a landed manifest's renames, in manifest order.
    ///
    /// A rename maps its own path and everything beneath it — `A/B → A/C` moves the key `A/B` and
    /// re-prefixes `A/B/…` — and **must not touch a sibling that merely shares a name prefix**:
    /// `A/BB` names a different folder. Applied sequentially because a manifest's operations are
    /// ordered (a folder is vacated before its name is filled, §5.4), so a later rename may
    /// legitimately act on the product of an earlier one.
    public func rekey(renames: [(from: String, to: String)], context: String? = nil) {
        guard !renames.isEmpty else { return }
        var newSuppressed = suppressed
        var newAnswers = answers
        var newDrafts = drafts
        for rename in renames {
            newSuppressed = Set(newSuppressed.map { $0.rekeyed(rename) })
            newAnswers = Self.rekeyedMap(newAnswers, through: rename)
            // The draft's KEY moves with the family; the manifest inside it keeps the paths it
            // was derived against — §5.5's Apply re-validates a draft against the tree as it
            // stands, and a stale path there is a card sentence, not a silent rewrite of a plan
            // the user reviewed.
            newDrafts = Self.rekeyedMap(newDrafts, through: rename)
        }
        guard newSuppressed != suppressed || newAnswers != answers || newDrafts != drafts else {
            return
        }
        suppressed = newSuppressed
        answers = newAnswers
        drafts = newDrafts
        Logger.shared.info("Restructure: store rekeyed through \(renames.count) rename(s)"
            + (context.map { " after \($0)" } ?? ""))
        save()
    }

    // MARK: - Disk

    private struct AnswerRecord: Codable {
        let kind: FindingKind
        let path: String
        let choice: String
    }

    private struct DraftEntry: Codable {
        let kind: FindingKind
        let path: String
        let draft: DraftRecord
    }

    private struct FileIn: Decodable {
        let schemaVersion: Int?
        let suppressed: [RestructureKey]?
        let answers: [AnswerRecord]?
        let drafts: [DraftEntry]?
        let applied: [AppliedRecord]?
    }

    private struct FileOut: Encodable {
        let schemaVersion: Int
        let suppressed: [RestructureKey]
        let answers: [AnswerRecord]
        let drafts: [DraftEntry]
        let applied: [AppliedRecord]

        /// Everything this type writes. Anything else in the file belongs to a section this build
        /// does not model yet and is carried across a save — see `carriedKeys`. Spelled out rather
        /// than derived, for ``PeopleStore``'s stated reason.
        static let modelledKeys: Set<String> = ["schemaVersion", "suppressed", "answers",
                                                "drafts", "applied"]
    }

    /// The schema this build writes. A file carrying a **newer** number is treated as unreadable
    /// for writing: it may hold sections in shapes this build would flatten, and "absent",
    /// "unreadable" and "newer than me" are three different claims — only the first is writable.
    static let currentSchema = 1

    private func load() {
        // lstat semantics on purpose: a broken symlink or an unreadable file is *something at the
        // path*, and must land in "unreadable, refuse writes" rather than "fresh, feel free".
        let somethingAtPath = (try? fileManager.attributesOfItem(atPath: fileURL.path)) != nil
        guard somethingAtPath else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let decoded = try? JSONDecoder().decode(FileIn.self, from: data)
        else {
            isUnreadable = true
            Logger.shared.warning("restructure.json exists but could not be read — suppressions "
                                  + "and answers start empty this session, and the store is "
                                  + "REFUSING to write over the file. Fix \(fileURL.path) to make "
                                  + "it writable again.")
            return
        }
        if let version = decoded.schemaVersion, version > Self.currentSchema {
            isUnreadable = true
            Logger.shared.warning("restructure.json is schema \(version) and this build writes "
                                  + "\(Self.currentSchema) — reading what it understands and "
                                  + "refusing to write, because a rewrite would flatten sections "
                                  + "the newer schema carries. File: \(fileURL.path)")
        }
        suppressed = Set(decoded.suppressed ?? [])
        // `uniquingKeysWith`: a hand-edited file with a duplicated row is imperfect input, not a
        // reason to crash at store construction — the whole philosophy here is that unreadable
        // input gets a refusal, never a trap. Last row wins, matching JSON's own object rule.
        answers = Dictionary((decoded.answers ?? []).map {
            (RestructureKey(kind: $0.kind, path: $0.path), $0.choice)
        }, uniquingKeysWith: { _, new in new })
        drafts = Dictionary((decoded.drafts ?? []).map {
            (RestructureKey(kind: $0.kind, path: $0.path), $0.draft)
        }, uniquingKeysWith: { _, new in new })
        applied = decoded.applied ?? []
        carriedKeys = object.filter { !FileOut.modelledKeys.contains($0.key) }
    }

    @discardableResult
    private func save() -> Bool {
        guard !isUnreadable else {
            Logger.shared.warning("Refusing to write restructure.json — it exists but could not "
                                  + "be read, so writing this session's state would overwrite the "
                                  + "real file. The change is in memory only.")
            return false
        }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let out = FileOut(
                schemaVersion: Self.currentSchema,
                suppressed: suppressed.sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) },
                answers: answers
                    .map { AnswerRecord(kind: $0.key.kind, path: $0.key.path, choice: $0.value) }
                    .sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) },
                drafts: drafts
                    .map { DraftEntry(kind: $0.key.kind, path: $0.key.path, draft: $0.value) }
                    .sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) },
                applied: applied)
            var data = try encoder.encode(out)
            if !carriedKeys.isEmpty,
               var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for (key, value) in carriedKeys where object[key] == nil { object[key] = value }
                data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys,
                                                            .withoutEscapingSlashes])
            }
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Logger.shared.warning("Could not write restructure.json: \(error.localizedDescription)")
            return false
        }
    }
}

extension RestructureStore {
    /// One rename applied to a keyed section, collision-safe: a rename's destination can equal a
    /// key recorded before the folder it named was hand-deleted, and two keys mapping onto one
    /// is a fact about the tree's history, not a programming error — the first spelling trapped
    /// (`Dictionary(uniqueKeysWithValues:)`) at the tail of a successful apply. The key that
    /// actually MOVED through the rename wins over the one already sitting at the destination:
    /// the moved claim is the one whose folder exists. (Within one rename the mapping is
    /// injective, so a collision is always exactly one moved key against one stale one.)
    static func rekeyedMap<Value>(_ map: [RestructureKey: Value],
                                  through rename: (from: String, to: String))
        -> [RestructureKey: Value] {
        var out: [RestructureKey: Value] = [:]
        for (key, value) in map {
            let newKey = key.rekeyed(rename)
            let moved = newKey != key
            if out[newKey] == nil || moved {
                out[newKey] = value
            }
        }
        return out
    }
}

private extension RestructureKey {
    /// This key with one rename applied — itself when the rename does not touch it.
    func rekeyed(_ rename: (from: String, to: String)) -> RestructureKey {
        if path == rename.from {
            return RestructureKey(kind: kind, path: rename.to)
        }
        let prefix = rename.from + "/"
        guard path.hasPrefix(prefix) else { return self }
        return RestructureKey(kind: kind, path: rename.to + "/" + path.dropFirst(prefix.count))
    }
}
