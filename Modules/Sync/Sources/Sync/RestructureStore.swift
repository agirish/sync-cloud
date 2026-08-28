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
}

/// Everything Restructure remembers, in one app-owned file — `restructure.json`, beside
/// `people.json`.
///
/// **One store, not four** (ROADMAP_V5 §5.0, decisions block): suppressions, Ask answers, drafted
/// plans and the applied ledger share the `kind × path` identity, so they share a file. The
/// `drafts` and `applied` sections arrive with §5.4 and §5.5; until then the decoder carries any
/// section it does not model across a save rather than deleting it, the same discipline
/// ``PeopleStore`` has for hand-added keys.
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

    /// The applied ledger — one record per landing, in the order they landed (§5.0's `applied`
    /// section, §5.5's step 2 home). The inverse is ON DISK from the moment a landing starts,
    /// which is what makes a reorganisation undoable after a quit, from here, not only with ⌘Z.
    ///
    /// **Keyed by manifest id and never re-keyed**: unlike the sections above, a ledger entry is
    /// a record of what happened at the time it happened — replaying a later manifest onto its
    /// paths would rewrite history to say the earlier landing touched folders it never saw.
    @Published public private(set) var applied: [AppliedRecord] = []

    public struct AppliedRecord: Codable, Equatable, Sendable {
        public let manifest: RestructureManifest
        public let inverse: RestructureManifest
        /// The landing's stamp, injected by the writer.
        public let at: String
        /// Outcome counts — what actually happened, against what the manifest predicted.
        public var created: Int
        public var skipped: Int
        /// §5.5 step 6's ids — nil until a landing re-derives the profile (stage one of Apply
        /// records the scaffold without one; the field exists so the schema does not move when
        /// re-derivation lands).
        public var appliedUnderProfileId: String?
        public var producedProfileId: String?

        public init(manifest: RestructureManifest, inverse: RestructureManifest, at: String,
                    created: Int, skipped: Int, appliedUnderProfileId: String? = nil,
                    producedProfileId: String? = nil) {
            self.manifest = manifest
            self.inverse = inverse
            self.at = at
            self.created = created
            self.skipped = skipped
            self.appliedUnderProfileId = appliedUnderProfileId
            self.producedProfileId = producedProfileId
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

    /// Top-level keys in the file this build does not model — §5.4's `drafts`, §5.5's `applied`
    /// until they land, and anything hand-added — carried across every save untouched.
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
        save()
    }

    public func unsuppress(_ key: RestructureKey) {
        guard suppressed.contains(key) else { return }
        suppressed.remove(key)
        save()
    }

    // MARK: - Answers

    public func answer(for key: RestructureKey) -> String? { answers[key] }

    public func recordAnswer(_ choice: String, for key: RestructureKey) {
        guard answers[key] != choice else { return }
        answers[key] = choice
        save()
    }

    public func removeAnswer(for key: RestructureKey) {
        guard answers[key] != nil else { return }
        answers[key] = nil
        save()
    }

    // MARK: - The ledger

    /// Appends one landing's record. The write is immediate and whole-file, like every mutation
    /// here — §5.5 step 2 calls this with outcome *in progress* semantics folded into the counts
    /// the caller passes, and a crash after this call leaves a reversible record on disk.
    public func recordApplied(_ record: AppliedRecord) {
        applied.append(record)
        save()
    }

    /// Replaces the record with `manifestId`'s manifest — how a landing finalises its counts.
    public func updateApplied(manifestId: String,
                              _ change: (inout AppliedRecord) -> Void) {
        guard let index = applied.firstIndex(where: { $0.manifest.manifestId == manifestId })
        else { return }
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
    public func rekey(renames: [(from: String, to: String)]) {
        guard !renames.isEmpty else { return }
        var newSuppressed = suppressed
        var newAnswers = answers
        for rename in renames {
            newSuppressed = Set(newSuppressed.map { $0.rekeyed(rename) })
            newAnswers = Dictionary(uniqueKeysWithValues: newAnswers.map {
                ($0.key.rekeyed(rename), $0.value)
            })
        }
        guard newSuppressed != suppressed || newAnswers != answers else { return }
        suppressed = newSuppressed
        answers = newAnswers
        save()
    }

    // MARK: - Disk

    private struct AnswerRecord: Codable {
        let kind: FindingKind
        let path: String
        let choice: String
    }

    private struct FileIn: Decodable {
        let schemaVersion: Int?
        let suppressed: [RestructureKey]?
        let answers: [AnswerRecord]?
        let applied: [AppliedRecord]?
    }

    private struct FileOut: Encodable {
        let schemaVersion: Int
        let suppressed: [RestructureKey]
        let answers: [AnswerRecord]
        let applied: [AppliedRecord]

        /// Everything this type writes. Anything else in the file belongs to a section this build
        /// does not model yet and is carried across a save — see `carriedKeys`. Spelled out rather
        /// than derived, for ``PeopleStore``'s stated reason.
        static let modelledKeys: Set<String> = ["schemaVersion", "suppressed", "answers", "applied"]
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
        answers = Dictionary(uniqueKeysWithValues: (decoded.answers ?? []).map {
            (RestructureKey(kind: $0.kind, path: $0.path), $0.choice)
        })
        applied = decoded.applied ?? []
        carriedKeys = object.filter { !FileOut.modelledKeys.contains($0.key) }
    }

    private func save() {
        guard !isUnreadable else {
            Logger.shared.warning("Refusing to write restructure.json — it exists but could not "
                                  + "be read, so writing this session's state would overwrite the "
                                  + "real file. The change is in memory only.")
            return
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
        } catch {
            Logger.shared.warning("Could not write restructure.json: \(error.localizedDescription)")
        }
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
