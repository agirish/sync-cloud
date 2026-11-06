import Foundation

/// A restructure plan as an ordered, versioned list of typed path operations.
///
/// Built to be replayed: the apply runs it forwards on the disk, replays it onto the corpus, memory
/// and store keys, and derives its inverse mechanically. So every action carries `src`/`dst` as
/// profile-relative paths, and the list is ordered as it runs.
public struct RestructureManifest: Codable, Equatable, Sendable {

    public enum ActionKind: String, Codable, Equatable, Sendable, CaseIterable {
        case createDir = "create-dir"
        case renameDir = "rename-dir"
        case moveDir = "move-dir"
        case moveFile = "move-file"
        case keep
        case removeEmptyDir = "remove-empty-dir"
    }

    public struct Action: Codable, Equatable, Sendable {
        public let action: ActionKind
        /// Absent for `create-dir`, which makes something from nothing.
        public var src: String?
        /// Absent for `keep`, which deliberately does nothing.
        public var dst: String?
        /// The written justification: a manifest is reviewed in a text editor before it is applied.
        public var evidence: String?
        /// Renames only: how many files the directory carried.
        public var filesCarried: Int?
        /// File moves only. Filled in at apply time, never at plan time.
        public var bytes: Int?
        /// No longer written; kept so older ledgers decode. It held an MD5 of every moved file,
        /// which made a large merge read every byte while the landing blocked all other scans and
        /// file operations, and nothing read it.
        public var md5: String?
        /// Plan time saw a same-named file already at `dst`: the ledger's "collisions kept" line
        /// before anything runs. A prediction, since the tree can change before apply; hence the
        /// field below.
        public var collisionExpected: Bool?
        /// Where the file landed when `dst` was taken (`generateUniqueURL`'s pick), filled at apply
        /// time. Kept apart from `dst` because the inverse must restore the file's original name:
        /// it reads `collidedInto ?? dst` as its source.
        public var collidedInto: String?
        /// `move-dir` only: this action relocates its source directory intact to a different
        /// parent, rather than draining the folder the source sits in.
        ///
        /// Two rules read a `move-dir`'s source parent and assume the plan is emptying it: the
        /// apply's unlisted-source-folder veto (a parent holding anything the plan never listed is
        /// left alone) and ``RestructureLedger/emptiedFolders(of:)`` (the removal step's scope).
        /// For a relocation both are wrong, so the intent is recorded rather than inferred from the
        /// path. nil means the draining shape, so manifests already on disk keep their behaviour.
        public var movesWholeFolder: Bool?
        /// The moved item's file number (inode), filled in at apply time like `bytes`, for folders
        /// as well as files. A move keeps the number, so the undo can tell the item the landing put
        /// at `dst` from one put there later under the same name, and won't move a newcomer back as
        /// though it were the original. nil on older records, which fall back to `bytes`.
        ///
        /// Not enough on its own, because a save is not a move: most apps save by writing a new
        /// file and swapping it in (`replaceItemAt`), which gets a new number. Alone, every merged
        /// file edited after a landing would read as replaced and be left out of the undo. See
        /// `created`.
        public var fileNumber: Int?
        /// The moved item's creation date, as seconds since 1970, filled in at apply time with
        /// `fileNumber`. A safe save keeps the replaced file's creation date though it changes its
        /// number, and a really new file has its own, so a match on either one is the item the
        /// landing moved.
        public var created: Double?

        public init(action: ActionKind, src: String? = nil, dst: String? = nil,
                    evidence: String? = nil, filesCarried: Int? = nil,
                    bytes: Int? = nil, md5: String? = nil,
                    collisionExpected: Bool? = nil, collidedInto: String? = nil,
                    movesWholeFolder: Bool? = nil, fileNumber: Int? = nil,
                    created: Double? = nil) {
            self.action = action
            self.src = src
            self.dst = dst
            self.evidence = evidence
            self.filesCarried = filesCarried
            self.bytes = bytes
            self.md5 = md5
            self.collisionExpected = collisionExpected
            self.collidedInto = collidedInto
            self.movesWholeFolder = movesWholeFolder
            self.fileNumber = fileNumber
            self.created = created
        }
    }

    public let schemaVersion: Int
    public let profileId: String
    public let manifestId: String
    /// A stamp string, injected by the caller: the manifest is a pure value and reads no clock.
    public let createdAt: String
    public let family: String
    /// Which detector's finding this plan answers.
    public let kind: FindingKind
    public var note: String?
    /// The mapping the actions were derived from, as edited, so the exported file is auditable
    /// against its own rows, not just their consequences. Absent on manifests that were never
    /// mapped (the scaffold's, the removal step's).
    public var mapping: [RestructureMapping.Row]?
    /// Ordered as they run.
    public var actions: [Action]

    /// How many actions do something. `keep` rows are the plan's signature block, not operations,
    /// so counting them in "Apply N operations" would overstate the destructive scope.
    public var operationCount: Int {
        actions.count { $0.action != .keep }
    }

    public static let currentSchema = 2

    public init(profileId: String, manifestId: String, createdAt: String, family: String,
                kind: FindingKind, note: String? = nil, mapping: [RestructureMapping.Row]? = nil,
                actions: [Action]) {
        self.schemaVersion = Self.currentSchema
        self.profileId = profileId
        self.manifestId = manifestId
        self.createdAt = createdAt
        self.family = family
        self.kind = kind
        self.note = note
        self.mapping = mapping
        self.actions = actions
    }

    private init(schemaVersion: Int, profileId: String, manifestId: String, createdAt: String,
                 family: String, kind: FindingKind, note: String?,
                 mapping: [RestructureMapping.Row]?, actions: [Action]) {
        self.schemaVersion = schemaVersion
        self.profileId = profileId
        self.manifestId = manifestId
        self.createdAt = createdAt
        self.family = family
        self.kind = kind
        self.note = note
        self.mapping = mapping
        self.actions = actions
    }

    /// The mechanical inverse: reverse the list, swap `src`/`dst`, and turn `create-dir` into
    /// `remove-empty-dir` and back. `keep` inverts to itself. Derived, never authored, so
    /// `inverse.inverse == self` is a testable law.
    ///
    /// The law holds for collision-free manifests. Inversion strips both collision facts:
    /// `collidedInto` (where a file landed; its inverse moves it back from there) and
    /// `collisionExpected` (a prediction about a landing the inverse doesn't make). So the round
    /// trip restores the tree exactly, and the bookkeeping only up to those two fields.
    public var inverse: RestructureManifest {
        RestructureManifest(
            schemaVersion: schemaVersion,
            profileId: profileId,
            // Toggled, not appended: inverting an inverse strips the suffix, so
            // `inverse.inverse == self` holds exactly.
            manifestId: manifestId.hasSuffix("-inverse")
                ? String(manifestId.dropLast("-inverse".count))
                : manifestId + "-inverse",
            createdAt: createdAt,
            family: family,
            kind: kind,
            note: note,
            mapping: mapping,
            actions: actions.reversed().map { action in
                var inverted = action
                switch action.action {
                case .createDir:
                    inverted = Action(action: .removeEmptyDir, src: action.dst,
                                      evidence: action.evidence)
                case .removeEmptyDir:
                    inverted = Action(action: .createDir, dst: action.src,
                                      evidence: action.evidence)
                case .renameDir, .moveDir, .moveFile:
                    // Where the item is now: the collision-renamed name when there was one.
                    inverted.src = action.collidedInto ?? action.dst
                    inverted.dst = action.src
                    inverted.collisionExpected = nil
                    inverted.collidedInto = nil
                case .keep:
                    break
                }
                return inverted
            })
    }

}

/// The removal step's manifest builder: the opt-in Trash pass.
///
/// Two origins, one builder. A landing drains folders and offers them on its own card; the survey
/// lists folders that were already empty. Both get the same sheet, split and ledgered, undoable
/// landing. Only the manifest id and the justifying sentences differ, so the origin carries those,
/// and one construction keeps the two routes from drifting apart.
public enum RestructureRemoval {

    /// Where the ticked folders came from: the only way the two removals differ.
    public enum Origin: Equatable, Sendable {
        /// Folders one landing itself emptied, scoped to that landing's manifest.
        case landing(manifestId: String)
        /// Folders that were already empty when the survey looked.
        case standing
    }

    /// One `remove-empty-dir` per ticked path, in the order given. nil for an empty list: a landing
    /// with no actions is a junk ledger record, not a no-op.
    ///
    /// Emptiness is not re-checked here and must not be: the engine re-probes every path as it acts
    /// (a folder that gained a file is skipped, and one the walk can't fully read is never treated
    /// as empty). A plan-time check would only add a staler opinion.
    public static func manifest(paths: [String], family: String, origin: Origin,
                                profileId: String, createdAt: String) -> RestructureManifest? {
        guard !paths.isEmpty else { return nil }
        let id: String
        let note: String
        let evidence: String
        switch origin {
        case .landing(let manifestId):
            id = "removal-\(manifestId)-\(createdAt)"
            note = "Removal step for \(manifestId): folders that landing emptied, ticked by "
                + "hand. To the Trash, never a hard delete."
            evidence = "Emptied by \(manifestId) and still empty when ticked."
        case .standing:
            id = "removal-standing-\(createdAt)"
            note = "Removal step for folders that were already empty when the survey looked, "
                + "ticked by hand. To the Trash, never a hard delete."
            evidence = "Empty in the folder survey and still empty when ticked."
        }
        return RestructureManifest(
            profileId: profileId,
            manifestId: id,
            createdAt: createdAt,
            family: family,
            kind: .deadWeight,
            note: note,
            actions: paths.map { path in
                RestructureManifest.Action(action: .removeEmptyDir, src: path,
                                           evidence: evidence)
            })
    }

    /// The deepest folder containing every one of these paths: the family a scattered removal
    /// belongs to. `"."` when they share only the root, which is common for standing empties. The
    /// parents are compared, not the paths: one ticked `Travel/2019` belongs to `Travel`, and
    /// calling the folder its own family would name the thing being removed.
    public static func commonAncestor(of paths: [String]) -> String {
        RestructurePaths.commonAncestor(
            of: paths.map { ($0 as NSString).deletingLastPathComponent })
    }
}

/// The scaffold's manifest builder: the backlog fix as a manifest.
public enum RestructureScaffold {

    /// `create-dir` actions for everything the family's vouched vocabulary expects of the newest
    /// member, which has none of it, since it fired for having no folders. nil when the finding is
    /// not a backlog or vouches for nothing: an empty scaffold is a card sentence, not an empty
    /// landing.
    public static func manifest(for finding: StructureFinding, profileId: String,
                                manifestId: String, createdAt: String) -> RestructureManifest? {
        guard case .backlog(let scaffold, _)? = finding.detail, !scaffold.isEmpty else {
            return nil
        }
        return RestructureManifest(
            profileId: profileId,
            manifestId: manifestId,
            createdAt: createdAt,
            family: finding.family,
            kind: .backlog,
            note: "Scaffold: set up \((finding.subject as NSString).lastPathComponent) like its "
                + "siblings. Creates folders only; the flat files go to To File.",
            actions: scaffold.map { name in
                RestructureManifest.Action(
                    action: .createDir,
                    dst: (finding.subject as NSString).appendingPathComponent(name),
                    evidence: "The family's vouched scheme expects \(name)/ and this member has "
                        + "no folders yet.")
            })
    }
}
