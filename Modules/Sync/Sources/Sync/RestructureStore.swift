import Events
import Foundation

/// One thing Restructure remembers, named by what noticed it and where.
///
/// `kind × path` is the identity everything in ``RestructureStore`` shares: a suppression, an
/// answer, a draft and a ledger entry all key on it, so one decision serves every section. The path
/// is the finding's subject (the most specific folder it is about), for the same reason as
/// ``StructureFinding/id``: the family alone isn't unique for every kind.
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

    /// The ``StructureFinding/id`` this key corresponds to: the one spelling of the composite
    /// identity, so a caller joining store sections to rendered findings never re-derives the
    /// `kind|path` format by hand.
    public var findingId: String { "\(kind.rawValue)|\(path)" }
}

/// Everything Restructure remembers, in one app-owned file: `restructure.json`, beside
/// `people.json`.
///
/// One store, not four: suppressions, Ask answers, drafted plans and the applied ledger share the
/// `kind × path` identity, so they share a file. Any section the decoder doesn't model is carried
/// across a save rather than deleted, as ``PeopleStore`` does for hand-added keys.
///
/// Writes are whole-file and atomic, like every store beside it (`PeopleStore`, `PersonTagStore`,
/// `StorageLensStore`, `FilingVerdictCache`): the file is small, and a partial write would be worse
/// than none.
///
/// Every section survives a re-survey, because the keys are paths and the profile can be replaced
/// underneath them. What a section doesn't survive is its path moving, so an Apply replays its
/// manifest onto these keys through ``rekey(renames:context:)``, as it does onto the corpus and the
/// memory.
@MainActor
public final class RestructureStore: ObservableObject {

    /// Findings the user said never to suggest again. Read by the lens before rendering and by the
    /// rail badge; written by Never suggest this again on any card.
    @Published public private(set) var suppressed: Set<RestructureKey> = []

    /// Chosen options for Ask findings, so the detector that asked never asks twice.
    @Published public private(set) var answers: [RestructureKey: String] = [:]

    /// Drafted plans, keyed on `kind × family`: Planned, not applied. A draft survives the sheet
    /// closing, the app quitting, and a re-survey, because the key is a path and the profile can be
    /// replaced underneath it. It doesn't survive its family ceasing to exist, which the card says.
    @Published public private(set) var drafts: [RestructureKey: DraftRecord] = [:]

    public struct DraftRecord: Codable, Equatable, Sendable {
        /// The plan as derived when the sheet last saved: mapping rows in its header, actions
        /// ordered as they would run.
        public var manifest: RestructureManifest
        /// When the draft was saved, injected by the writer.
        public var savedAt: String
        /// The file `Export plan` wrote, relative to the profile folder; nil for a draft saved
        /// without exporting.
        public var exportedTo: String?
        /// The sheet's full picker vocabulary when the draft was saved: the chosen scheme's names
        /// plus any typed ones, including names no row uses, so a reopened draft keeps its unused
        /// choices. Optional: an older draft reopens with the rows' targets alone.
        public var vocabulary: [String]?

        public init(manifest: RestructureManifest, savedAt: String, exportedTo: String? = nil,
                    vocabulary: [String]? = nil) {
            self.manifest = manifest
            self.savedAt = savedAt
            self.exportedTo = exportedTo
            self.vocabulary = vocabulary
        }
    }

    /// One point per survey: how many findings of each kind the detectors produced. Append-only,
    /// oldest dropped past ``trendCap``. Only counts the detectors produced, each one a lens
    /// displayed when it was stamped; nothing invented.
    ///
    /// Stamped when the profile the findings come from changes (first load, a re-derive, a
    /// landing), never on every memo drop. A survey isn't re-run between those, so a point per drop
    /// would repeat the same number at whatever rate the memo churns.
    @Published public private(set) var trend: [TrendPoint] = []

    /// A survey's findings, counted by kind.
    public struct TrendPoint: Codable, Equatable, Sendable {
        /// When it was stamped, in `FilingProfileStore.stamp` format.
        public let at: String
        /// The profile directory the counts were derived from; also the dedupe key, since a survey
        /// doesn't change without the profile changing.
        public let profileId: String
        /// Findings per kind. Kinds with none are absent rather than zero, the rule every badge
        /// here follows; the total is the values' sum.
        public let countsByKind: [String: Int]
        /// True when a landing stamped this point rather than an ordinary survey: the dots on the
        /// line, and the only way to read cause into the shape.
        public let landing: Bool

        public init(at: String, profileId: String, countsByKind: [String: Int],
                    landing: Bool) {
            self.at = at
            self.profileId = profileId
            self.countsByKind = countsByKind
            self.landing = landing
        }

        public var total: Int { countsByKind.values.reduce(0, +) }
    }

    /// How many points are kept: years of surveys. The file is read whole at construction, so an
    /// unbounded trend would make every launch pay for history nothing reads.
    public static let trendCap = 200

    /// Which backlog nudges have been dismissed, and for which year. A year rather than a flag,
    /// because the nudge recurs: dismissing the 2026 gap in Health/Dental must not silence 2027's.
    /// Keyed like the other sections, so `rekey` moves it with a rename, and an older store decodes
    /// with it absent.
    @Published public private(set) var nudgesAcknowledged: [RestructureKey: String] = [:]

    /// The applied ledger: one record per landing, in the order they landed. The inverse is on disk
    /// from the moment a landing starts, so a reorganisation is undoable after a quit, from here,
    /// not only with ⌘Z.
    ///
    /// Keyed by manifest id and never re-keyed: a ledger entry records what happened when it
    /// happened, and replaying a later manifest onto its paths would make the earlier landing claim
    /// folders it never saw.
    @Published public private(set) var applied: [AppliedRecord] = []

    public struct AppliedRecord: Codable, Equatable, Sendable {
        /// `var`, not `let`: a landing finalises the manifest with what actually happened
        /// (collision names, bytes, file numbers), and the inverse is recomputed from that, because
        /// the inverse of the plan would move files back from names they never landed at.
        public var manifest: RestructureManifest
        public var inverse: RestructureManifest
        /// The landing's stamp, injected by the writer.
        public let at: String
        /// Outcome counts: what actually happened, against what the manifest predicted.
        public var created: Int
        public var skipped: Int
        /// Ids set when a landing re-derives the profile. nil on a scaffold record; a plan apply
        /// always fills both, or says why in `summary`.
        public var appliedUnderProfileId: String?
        public var producedProfileId: String?
        /// The landing's one-line ledger sentence: what the Applied card renders.
        public var summary: String?
        /// Stamped when Undo this reorganisation ran this record's inverse: the Undone state's
        /// evidence, and the guard against running it twice.
        public var undoneAt: String?
        /// What the undo run did: the Undone card's sentence, which never pretends the tree was
        /// untouched. A file that had moved on and was skipped is in its skip count and named in
        /// the log.
        public var undoSummary: String?
        /// The independent verifier's answer: did the re-listed tree match what the performed
        /// actions claim? nil is not "no": older records decode without it, and a landing that
        /// never reached the verifier has nothing to report. The card then says nothing.
        public var verifiedOK: Bool?
        /// What the verifier disagreed about, in one sentence; nil when it agreed or didn't run.
        public var verifierNote: String?
        /// The Setup folder whose landing has reshaped this one's tree since the user left it, set
        /// when a walk back took this history up and withheld the Undo, so the card can say why
        /// there is none. Nil on every other record.
        public var undoWithheldBy: String?
        /// True when the Undo was withheld because a landing there could have come later (its
        /// ledger wouldn't read, it carries no id, or the history predates the record of what was
        /// seen) rather than because one did. The card's words differ.
        public var undoWithheldUnsure: Bool?

        public init(manifest: RestructureManifest, inverse: RestructureManifest, at: String,
                    created: Int, skipped: Int, appliedUnderProfileId: String? = nil,
                    producedProfileId: String? = nil, summary: String? = nil,
                    undoneAt: String? = nil, undoSummary: String? = nil,
                    verifiedOK: Bool? = nil, verifierNote: String? = nil,
                    undoWithheldBy: String? = nil) {
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
            self.verifiedOK = verifiedOK
            self.verifierNote = verifierNote
            self.undoWithheldBy = undoWithheldBy
        }
    }

    /// Whether something sits at `restructure.json`'s path that this build couldn't read: a syntax
    /// error, an I/O failure, or a newer schema.
    ///
    /// A file this build couldn't read is a file it must not rewrite. Every save is a whole-file
    /// atomic write of the state in memory, which is empty after a failed load, so writing would
    /// replace the real file with nothing. The store stays usable in memory; only the disk refuses.
    @Published public private(set) var isUnreadable = false

    /// Where the file is read from and written to: the profiles directory and the folder inside it,
    /// both as handed over at construction, for the reason ``PeopleStore/directory`` documents (the
    /// id inside a profile file and the folder it was read from can disagree).
    let directory: URL
    let profileId: String
    private let fileManager: FileManager

    /// Top-level keys in the file this build doesn't model (a future build's sections, anything
    /// hand-added), carried across every save untouched, so a new section arrives without a
    /// migration.
    private var carriedKeys: [String: Any] = [:]

    /// `restructure.json` for the active profile.
    public var fileURL: URL {
        directory.appendingPathComponent("\(profileId)/restructure.json")
    }

    /// Writes an empty ledger for `profileId` when its folder has none: a Setup walk of a folder
    /// with no history of its own must not inherit the old folder's path-keyed state, but must hold
    /// a ledger, or the retire sweep's "only copy" rule keeps every old folder forever. Leaves an
    /// existing file alone. False when the write failed.
    @discardableResult
    public static func startEmptyLedger(in directory: URL, profileId: String) -> Bool {
        let store = RestructureStore(directory: directory, profileId: profileId)
        guard !FileManager.default.fileExists(atPath: store.fileURL.path) else { return true }
        return store.writeFile()
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
        // Each mutator logs: these are consequential, persistent decisions, and the log is the only
        // place they can be dated later.
        Logger.shared.info("Restructure: suppressed \(key.findingId)")
        save()
    }

    public func unsuppress(_ key: RestructureKey) {
        guard suppressed.contains(key) else { return }
        suppressed.remove(key)
        Logger.shared.info("Restructure: unsuppressed \(key.findingId)")
        save()
    }

    /// These Never suggest this again keys at once, in one write: the lens's Show them again for
    /// the findings in its scope. Keys not in the set, stale ones included, stay.
    public func unsuppress(_ keys: Set<RestructureKey>) {
        let present = suppressed.intersection(keys)
        guard !present.isEmpty else { return }
        suppressed.subtract(present)
        Logger.shared.info("Restructure: unsuppressed \(present.count) finding(s)")
        save()
    }

    /// Every Never suggest this again at once.
    public func unsuppressAll() {
        guard !suppressed.isEmpty else { return }
        Logger.shared.info("Restructure: unsuppressed all \(suppressed.count) finding(s)")
        suppressed = []
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

    /// Drops the draft a landing consumed, through the landing's own renames.
    ///
    /// A plan can rename the finding's own subject (`rename-dir IRS Docs - 2024 → 2024`), and the
    /// draft is keyed on `kind × subject`. `applyPlan` calls ``rekey(renames:context:)`` before it
    /// returns, so the pre-landing key may already have moved; removing only that one would leave a
    /// draft derived against a tree that no longer exists, still offering Review N operations. Both
    /// keys are dropped, since which is present depends on whether the rekey ran.
    ///
    /// Pass the landed manifest (`RestructureApplyOutcome.landedManifest`), not the planned one:
    /// `rekey` moved the keys through the renames that performed, and a skipped rename would
    /// compute a key the store never held.
    public func removeDraft(for key: RestructureKey, consumedBy manifest: RestructureManifest) {
        removeDraft(for: key)
        var landedKey = key
        for rename in RestructureRederive.renameMap(of: manifest) {
            landedKey = landedKey.rekeyed(rename)
        }
        guard landedKey != key else { return }
        removeDraft(for: landedKey)
    }

    /// What distinguishes two plans over one family on one day in an export's filename. Empty for a
    /// `shape` plan, which is unique per family.
    ///
    /// The subject is the folder the operations come out of, so two shadow-axis findings under one
    /// parent (`IRS Docs - 2023`, `IRS Docs - 2024`) land in two files, and re-exporting either
    /// still replaces only itself.
    static func exportSubject(of manifest: RestructureManifest) -> String {
        guard manifest.kind != .shape else { return "" }
        // The common ancestor of the sources, not the first action's name: a merge's first action
        // is a `move-file`, so two plans whose first files shared a name would write one filename
        // and silently replace each other. The ancestor is the same for rename and merge shapes,
        // and stable when a file is added or removed.
        let sources = manifest.actions.filter { $0.action != .keep }.compactMap { $0.src ?? $0.dst }
        let subject = (RestructurePaths.commonAncestor(of: sources) as NSString).lastPathComponent
        let cleaned = subject == "." ? "" : subject.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "-\(manifest.kind.rawValue)"
                               : "-\(manifest.kind.rawValue)-\(cleaned)"
    }

    /// Writes `manifest` beside the profile as `restructure-<date>-<family><subject>.json`, to
    /// review in a text editor with nothing at risk. Returns the file name it chose.
    ///
    /// A new file, not `restructure.json`, so it is written even while the store refuses writes.
    /// A same-day re-export of the same plan replaces the earlier file even if the plan was edited,
    /// so the newest reviewed plan is the one kept; an older draft's `exportedTo` can therefore name
    /// a file holding the newer plan.
    @discardableResult
    public func exportPlan(_ manifest: RestructureManifest) throws -> String {
        let date = manifest.createdAt.prefix(while: { $0 != "T" })
        // Date plus family alone isn't unique: one parent can carry two shadow-axis findings, and
        // two unrelated plans can both be root-level ("" or "."), so they would silently replace
        // each other. Same-day replacement stays sanctioned within one plan, because the subject
        // below is the finding's own folder.
        let family = manifest.family.isEmpty || manifest.family == "."
            ? "tree"
            : manifest.family.replacingOccurrences(of: "/", with: "-")
        let name = "restructure-\(date)-\(family)\(Self.exportSubject(of: manifest)).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = directory.appendingPathComponent("\(profileId)/\(name)")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        // One greppable line: the export is an act a later reader may need to date and locate
        // without the app open.
        Logger.shared.info("Restructure plan exported — \(name): "
                           + "\(manifest.actions.count) action(s) for \(manifest.family), "
                           + "beside profile \(profileId)")
        return name
    }

    // MARK: - The ledger

    /// Appends one landing's record, written at once and whole-file, so a crash after this call
    /// leaves a reversible record on disk.
    ///
    /// Returns whether the record reached the disk. The caller must know: the inverse has to be on
    /// disk before the first operation, and a swallowed write failure would let a whole
    /// reorganisation run with no record once the app quits. Other mutators can shrug off a failed
    /// save as in-memory only; this one is the licence to move files.
    @discardableResult
    public func recordApplied(_ record: AppliedRecord) -> Bool {
        applied.append(record)
        // `writeFile()`, not `save()`: that is this method's contract. Inside `batchingSaves`,
        // `save()` answers `true` for a record still only in memory, and the caller reads that as
        // "the inverse is on disk, start moving files".
        guard writeFile() else {
            // The record never reached the disk, so it must not survive in memory either: the
            // caller refuses the landing on `false`, and a phantom entry would make the retry
            // refuse too, through the lands-once guard, claiming a landing that never happened.
            applied.removeLast()
            return false
        }
        return true
    }

    /// The one landing Undo this reorganisation may run, or nil. A reorganisation is a record
    /// `applyPlan` wrote (`appliedUnderProfileId` set; scaffold records never carry one). Only the
    /// newest not-undone one is offered, because an older inverse describes a tree a later landing
    /// reshaped. It must have finished recording (`summary` set; without one the app quit
    /// mid-landing and the stored inverse may not match what moved), and the survey must still be
    /// where the landing left it: the produced directory, or the applied-under one when the
    /// re-derive failed before it could re-point.
    public func undoableReorganisation(currentProfileId: String?) -> AppliedRecord? {
        guard let record = applied.last(where: {
            $0.appliedUnderProfileId != nil && $0.undoneAt == nil
        }), record.summary != nil,
        let current = currentProfileId,
        (record.producedProfileId ?? record.appliedUnderProfileId) == current
        else { return nil }
        return record
    }

    /// Moves every live landing's produced-profile id onto `to`, for a re-derive that moved no
    /// files.
    ///
    /// The undo chain needs a landing's produced profile to be the current one
    /// (``undoableReorganisation(currentProfileId:)``), but a survey refresh mints a profile
    /// directory too. Without this, Update the survey now would silently withdraw the Undo of a
    /// landing that is exactly as reversible as before: the tree is as it left it, and
    /// `appliedUnderProfileId` still names a live directory. Only the bookkeeping moves.
    ///
    /// Undone records are left alone: their chain is finished, and moving them would make an old
    /// landing look current.
    public func repointProduced(from: String, to: String) {
        guard from != to else { return }
        var changed = false
        for index in applied.indices where applied[index].undoneAt == nil {
            // Matched exactly as `undoableReorganisation` reads it, with its fallback: a landing
            // whose re-derive failed has no `producedProfileId` and is offered its undo through
            // `?? appliedUnderProfileId`, so comparing only the produced id would leave exactly
            // those records un-undoable after a refresh.
            guard (applied[index].producedProfileId
                    ?? applied[index].appliedUnderProfileId) == from else { continue }
            applied[index].producedProfileId = to
            changed = true
        }
        guard changed else { return }
        Logger.shared.info("Restructure: ledger re-pointed from \(from) to \(to)")
        save()
    }

    /// Marks every live landing that produced `from` as one whose Undo is withheld because a
    /// landing in `root` has reshaped the tree since: the records ``repointProduced(from:to:)``
    /// would have moved, matched the same way.
    public func withholdUndo(producedBy from: String, because root: String,
                             unsure: Bool = false) {
        var changed = false
        for index in applied.indices where applied[index].undoneAt == nil {
            guard (applied[index].producedProfileId
                    ?? applied[index].appliedUnderProfileId) == from else { continue }
            applied[index].undoWithheldBy = root
            applied[index].undoWithheldUnsure = unsure ? true : nil
            changed = true
        }
        if changed { save() }
    }

    /// Replaces the record with `manifestId`'s manifest: how a landing finalises its counts.
    ///
    /// - Returns: whether the changed record is written. False when there is no such record or the
    ///   write failed (the change then lives in memory only, gone at relaunch). A change that
    ///   changes nothing answers true. Inside `batchingSaves` it answers true for a change only in
    ///   memory, as `save()` does there. A landing reads it before throwing its journal away.
    @discardableResult
    public func updateApplied(manifestId: String,
                              _ change: (inout AppliedRecord) -> Void) -> Bool {
        guard let index = applied.firstIndex(where: { $0.manifest.manifestId == manifestId })
        else {
            Logger.shared.warning("restructure.json holds no record \(manifestId) to update — "
                                  + "the change was dropped")
            return false
        }
        var record = applied[index]
        change(&record)
        guard record != applied[index] else { return true }
        applied[index] = record
        return save()
    }

    // MARK: - Lineage

    /// The stores whose state this one was opened on, oldest first: each hop's file, and the
    /// renames its keys went through on the way here. In memory only: it answers questions about
    /// this session's swaps (an undo registered before one), and nothing outlives the session to
    /// ask.
    private(set) var lineage: [(directory: URL, profileId: String,
                                renames: [(from: String, to: String)])] = []

    /// Records that this store was opened on `predecessor`'s carried state, its keys moved through
    /// `renames`: what a landing's or a survey refresh's re-derive does when it swaps stores.
    func adoptLineage(from predecessor: RestructureStore, renames: [(from: String, to: String)]) {
        lineage = predecessor.lineage
            + [(predecessor.directory, predecessor.profileId, renames)]
    }

    /// Whether `other` reads and writes the same `restructure.json` as this store.
    func isSameFile(as other: RestructureStore) -> Bool {
        fileURL.standardizedFileURL.path == other.fileURL.standardizedFileURL.path
    }

    /// `key`, as it was in `ancestor`, spelled the way this store holds it. nil when this store's
    /// state wasn't carried from `ancestor`'s (say another profile's store after a provider switch,
    /// which may hold the same kind and path about a different tree).
    func carriedKey(_ key: RestructureKey, from ancestor: RestructureStore) -> RestructureKey? {
        let file = ancestor.fileURL.standardizedFileURL.path
        guard let start = lineage.lastIndex(where: {
            $0.directory.appendingPathComponent("\($0.profileId)/restructure.json")
                .standardizedFileURL.path == file
        }) else { return nil }
        var carried = key
        for hop in lineage[start...] {
            for rename in hop.renames { carried = carried.rekeyed(rename) }
        }
        return carried
    }

    // MARK: - Replay

    /// Re-keys every section for a landed manifest's renames, in manifest order.
    ///
    /// A rename maps its own path and everything beneath it (`A/B → A/C` moves `A/B` and
    /// re-prefixes `A/B/…`) and must not touch a sibling that merely shares a name prefix: `A/BB`
    /// is a different folder. Applied in order, because a manifest's operations are ordered (a
    /// folder is vacated before its name is filled), so a later rename may act on the product of an
    /// earlier one.
    public func rekey(renames: [(from: String, to: String)], context: String? = nil) {
        guard !renames.isEmpty else { return }
        var newSuppressed = suppressed
        var newAnswers = answers
        var newDrafts = drafts
        var newNudges = nudgesAcknowledged
        for rename in renames {
            newSuppressed = Set(newSuppressed.map { $0.rekeyed(rename) })
            newAnswers = Self.rekeyedMap(newAnswers, through: rename)
            // A backlog subject is a folder path, so a landing that renames it moves this key too,
            // or the nudge would re-fire under the new name for a year already dismissed.
            newNudges = Self.rekeyedMap(newNudges, through: rename)
            // The draft's key moves with the family; the manifest inside keeps the paths it was
            // derived against. Apply re-validates a draft against the tree, and a stale path there
            // is a card sentence, not a silent rewrite of a plan the user reviewed.
            newDrafts = Self.rekeyedMap(newDrafts, through: rename)
        }
        guard newSuppressed != suppressed || newAnswers != answers || newDrafts != drafts
                || newNudges != nudgesAcknowledged else {
            return
        }
        suppressed = newSuppressed
        answers = newAnswers
        drafts = newDrafts
        nudgesAcknowledged = newNudges
        Logger.shared.info("Restructure: store rekeyed through \(renames.count) rename(s)"
            + (context.map { " after \($0)" } ?? ""))
        save()
    }

    // MARK: - Nudges

    /// Records that the nudge for this finding has been seen for `year`. Not a suppression, which
    /// hides the finding from every surface: this hides one overview line for the rest of one year.
    /// The lens keeps showing it either way.
    public func acknowledgeNudge(_ key: RestructureKey, year: String) {
        guard nudgesAcknowledged[key] != year else { return }
        nudgesAcknowledged[key] = year
        Logger.shared.info("Restructure: nudge acknowledged for \(key.findingId) (\(year))")
        save()
    }

    // MARK: - Trend

    /// Stamps one survey's finding counts. Deduped on `profileId`: findings are a pure function of
    /// the profile, so two stamps under one id are one survey counted twice. A landing stamp
    /// replaces an ordinary one for the same profile, because "this point is a landing" says more.
    @discardableResult
    public func recordTrend(_ point: TrendPoint) -> Bool {
        if let index = trend.lastIndex(where: { $0.profileId == point.profileId }) {
            guard point.landing, !trend[index].landing else { return false }
            trend[index] = point
        } else {
            trend.append(point)
            if trend.count > Self.trendCap { trend.removeFirst(trend.count - Self.trendCap) }
        }
        return save()
    }

    // MARK: - Disk

    private struct NudgeRecord: Codable {
        let kind: FindingKind
        let path: String
        let year: String
    }

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
        let nudgesAcknowledged: [NudgeRecord]?
        let trend: [TrendPoint]?
    }

    private struct FileOut: Encodable {
        let schemaVersion: Int
        let suppressed: [RestructureKey]
        let answers: [AnswerRecord]
        let drafts: [DraftEntry]
        let applied: [AppliedRecord]
        let nudgesAcknowledged: [NudgeRecord]
        let trend: [TrendPoint]

        /// Everything this type writes. Anything else in the file belongs to a section this build
        /// doesn't model and is carried across a save (see `carriedKeys`). Spelled out rather than
        /// derived, for ``PeopleStore``'s stated reason.
        static let modelledKeys: Set<String> = ["schemaVersion", "suppressed", "answers",
                                                "drafts", "applied", "nudgesAcknowledged",
                                                "trend"]
    }

    /// The schema this build writes. A file with a newer number is unreadable for writing: it may
    /// hold sections this build would flatten. "Absent", "unreadable" and "newer than me" are three
    /// different claims, and only the first is writable.
    static let currentSchema = 1

    private func load() {
        // lstat semantics on purpose: a broken symlink or an unreadable file is something at the
        // path, and must land in "unreadable, refuse writes" rather than "fresh, feel free".
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
        // `uniquingKeysWith`: a hand-edited file with a duplicated row gets no crash at store
        // construction; unreadable input gets a refusal, never a trap. Last row wins, as in JSON.
        answers = Dictionary((decoded.answers ?? []).map {
            (RestructureKey(kind: $0.kind, path: $0.path), $0.choice)
        }, uniquingKeysWith: { _, new in new })
        drafts = Dictionary((decoded.drafts ?? []).map {
            (RestructureKey(kind: $0.kind, path: $0.path), $0.draft)
        }, uniquingKeysWith: { _, new in new })
        applied = decoded.applied ?? []
        nudgesAcknowledged = Dictionary((decoded.nudgesAcknowledged ?? []).map {
            (RestructureKey(kind: $0.kind, path: $0.path), $0.year)
        }, uniquingKeysWith: { _, new in new })
        trend = decoded.trend ?? []
        carriedKeys = object.filter { !FileOut.modelledKeys.contains($0.key) }
    }

    /// How many `batchingSaves` calls are open. While this is non-zero a mutation marks the state
    /// dirty instead of rewriting the file; the outermost call writes once at the end.
    private var batchDepth = 0
    /// Whether anything asked to be saved while a batch was open.
    private var batchDirty = false

    /// Runs `body` with the per-mutation writes coalesced into one at the end. A landing would
    /// otherwise rewrite this file several times, each a whole-file encode of a ledger whose
    /// records carry a manifest and its inverse, inside the window where the landing refuses every
    /// other scan.
    ///
    /// ``recordApplied(_:)`` is deliberately not coalesced, even inside a batch: its return value
    /// is the licence to start moving files, and a `true` that meant "queued" would break the rule
    /// that the inverse is on disk before the first operation. The rest of a landing is bookkeeping
    /// about moves that already happened, which may wait.
    ///
    /// Nesting-safe. The outermost call returns whether the write reached the disk, or `true` when
    /// nothing needed writing.
    @discardableResult
    func batchingSaves<T>(_ body: () -> T) -> (value: T, saved: Bool) {
        batchDepth += 1
        let value = body()
        batchDepth -= 1
        guard batchDepth == 0, batchDirty else { return (value, true) }
        batchDirty = false
        return (value, writeFile())
    }

    @discardableResult
    private func save() -> Bool {
        guard batchDepth == 0 else {
            batchDirty = true
            return true
        }
        return writeFile()
    }

    /// The write itself: what `save()` does when no batch is open, and what a batch's flush does at
    /// its end.
    @discardableResult
    private func writeFile() -> Bool {
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
            // `.sortedKeys` makes the bytes a function of the state alone, so the file can be
            // diffed. No `.prettyPrinted`: it roughly doubles the bytes of a large ledger on every
            // save, and every reader is a parser. Not a format change: `JSONSerialization` and
            // `JSONDecoder` read both, in this build and older ones.
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let out = FileOut(
                schemaVersion: Self.currentSchema,
                suppressed: suppressed.sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) },
                answers: answers
                    .map { AnswerRecord(kind: $0.key.kind, path: $0.key.path, choice: $0.value) }
                    .sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) },
                drafts: drafts
                    .map { DraftEntry(kind: $0.key.kind, path: $0.key.path, draft: $0.value) }
                    .sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) },
                applied: applied,
                nudgesAcknowledged: nudgesAcknowledged
                    .map { NudgeRecord(kind: $0.key.kind, path: $0.key.path, year: $0.value) }
                    .sorted { ($0.kind.rawValue, $0.path) < ($1.kind.rawValue, $1.path) },
                // Stored order, which is stamp order: the line is drawn in it.
                trend: trend)
            var data = try encoder.encode(out)
            if !carriedKeys.isEmpty,
               var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for (key, value) in carriedKeys where object[key] == nil { object[key] = value }
                data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.sortedKeys,
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
    /// One rename applied to a keyed section, collision-safe. A rename's destination can equal a
    /// key recorded before the folder it named was hand-deleted; two keys mapping onto one is a
    /// fact about the tree's history, so `Dictionary(uniqueKeysWithValues:)` would trap. The key
    /// that moved through the rename wins over the stale one, since its folder exists. Within one
    /// rename the mapping is injective, so a collision is always one moved key against one stale
    /// one.
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
    /// This key with one rename applied; itself when the rename doesn't touch it.
    func rekeyed(_ rename: (from: String, to: String)) -> RestructureKey {
        if path == rename.from {
            return RestructureKey(kind: kind, path: rename.to)
        }
        let prefix = rename.from + "/"
        guard path.hasPrefix(prefix) else { return self }
        return RestructureKey(kind: kind, path: rename.to + "/" + path.dropFirst(prefix.count))
    }
}
