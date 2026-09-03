import Foundation

/// A restructure plan as an ordered list of typed path operations — the 6 Aug log's schema,
/// extended and versioned (ROADMAP_V5 §5.4).
///
/// **Replayable is the whole design**: §5.5 runs it forwards on the disk, replays it onto the
/// corpus, memory and store keys, and derives its inverse mechanically — so every action carries
/// `src`/`dst` as profile-relative paths, and the list is ordered as it runs.
///
/// In this milestone only the **scaffold** builder exists (`create-dir` actions, §5.2's backlog
/// fix — the one Apply that creates and never moves). The mapping-derived builder, `keep` rows
/// and the removal step arrive with §5.4/§5.5; the schema is theirs already, so landing the
/// scaffold first proves the manifest, the ledger and ⌘Z before anything destructive exists.
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
        /// The written justification — every operation in the 6 Aug log carried one, and a
        /// manifest is reviewed in a text editor before it is applied.
        public var evidence: String?
        /// Renames only: how many files the directory carried.
        public var filesCarried: Int?
        /// File moves only — **filled in at apply time, never at plan time** (invariant 5).
        public var bytes: Int?
        /// **No longer written**, and kept only so ledgers recorded before 2026-09-02 decode.
        ///
        /// It held an MD5 of every moved file, up to a 64 MB cap, computed inside the landing —
        /// which turned a 500-file merge into reading a gigabyte, while the landing flag refuses
        /// every other scan and file operation. Nothing read it: it was audit-only, and the
        /// verifier reconciles counts from a different code path rather than comparing digests.
        public var md5: String?
        /// Plan time saw a same-named file already at `dst` — the ledger's *collisions kept*
        /// line before anything runs. Predicted, not final: the tree can change between plan
        /// and apply, which is why the field below exists separately.
        public var collisionExpected: Bool?
        /// Where the file actually landed when `dst` was taken — `generateUniqueURL`'s pick,
        /// **filled at apply time**. Its own fact rather than folded into `dst`, because the
        /// inverse must restore the file's *original* name: it reads `collidedInto ?? dst` as
        /// its source (ROADMAP_V5 §5.4).
        public var collidedInto: String?
        /// `move-dir` only: this action relocates its source directory **intact, to a different
        /// parent** — it does not drain the folder the source sits in.
        ///
        /// Two rules read a `move-dir`'s source *parent* and both assume the plan is emptying it,
        /// which held for every manifest until the cross-parent pair merge existed: the apply's
        /// unlisted-source-folder veto (a parent holding anything the plan never listed is left
        /// untouched) and ``RestructureLedger/emptiedFolders(of:)`` (the removal step's scope).
        /// For a relocation both are wrong — the parent keeps everything else, and nothing was
        /// emptied — so the intent is recorded rather than inferred from the path.
        ///
        /// nil means the old, draining shape, so every manifest already on disk keeps its
        /// behaviour exactly.
        public var movesWholeFolder: Bool?

        public init(action: ActionKind, src: String? = nil, dst: String? = nil,
                    evidence: String? = nil, filesCarried: Int? = nil,
                    bytes: Int? = nil, md5: String? = nil,
                    collisionExpected: Bool? = nil, collidedInto: String? = nil,
                    movesWholeFolder: Bool? = nil) {
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
        }
    }

    public let schemaVersion: Int
    public let profileId: String
    public let manifestId: String
    /// A stamp string, injected by the caller — the manifest is a pure value and reads no clock.
    public let createdAt: String
    public let family: String
    /// §5.0's kind — which detector's finding this plan answers.
    public let kind: FindingKind
    public var note: String?
    /// The mapping the actions were derived from, as edited (§5.4's header field) — so the
    /// exported file is auditable against its own rows, not just its consequences. Absent on
    /// manifests that were never mapped (the scaffold's, the removal step's).
    public var mapping: [RestructureMapping.Row]?
    /// Ordered as they run.
    public var actions: [Action]

    /// How many actions actually DO something — `keep` rows are the plan's signature block, not
    /// operations, so a red "Apply N operations" button (and the card's "Review N operations")
    /// counting them overstated the destructive scope: one rename plus 13 keeps read as
    /// "Apply 14 operations" over a landing whose ledger then said "1 rename · 0 moved".
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

    /// The mechanical inverse (ROADMAP_V5 §5.4): reverse the list, swap `src`/`dst`, and turn
    /// `create-dir` into `remove-empty-dir` and back. `keep` inverts to itself — doing nothing
    /// twice. Derived, never authored, which is what makes `inverse.inverse == self` a testable
    /// law rather than a hope.
    ///
    /// **The involution law holds for collision-free manifests** — the shape the tests pin.
    /// Both collision facts are deliberately stripped by inversion: `collidedInto` (apply-time —
    /// the unique name a file actually landed under; its inverse moves the file back from
    /// *there*) and `collisionExpected` (plan-time — a prediction about a landing the inverse
    /// does not make). So `inverse.inverse` restores the tree's round trip exactly, and the
    /// bookkeeping only up to those two fields.
    public var inverse: RestructureManifest {
        RestructureManifest(
            schemaVersion: schemaVersion,
            profileId: profileId,
            // Toggled, not appended: inverting an inverse strips the suffix, which is half of
            // what makes `inverse.inverse == self` hold exactly.
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
                    // Where the item actually IS: the collision-renamed name when there was one.
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

/// The removal step's manifest builder — §5.5's opt-in Trash pass.
///
/// **Two origins, one builder.** A landing drains folders and offers them on its own card; §5.2's
/// third crowding filter lists the folders that were *already* empty when the survey looked, and
/// the roadmap's decided behaviour is that they get the same sheet, the same date-bucket /
/// category split, and the same ledgered, undoable landing. The only things that differ are the
/// manifest's id and the sentences that justify it, so those are what the origin carries — a
/// second copy of this construction is how the two routes would drift apart.
public enum RestructureRemoval {

    /// Where the ticked folders came from — the only axis on which the two removals differ.
    public enum Origin: Equatable, Sendable {
        /// Folders one landing itself emptied, scoped to that landing's manifest.
        case landing(manifestId: String)
        /// Folders that were already empty when the survey looked (ROADMAP_V5 §5.2).
        case standing
    }

    /// One `remove-empty-dir` per ticked path, in the order given. nil for an empty list: a
    /// landing with no actions is a junk ledger record, not a no-op.
    ///
    /// Emptiness is **not** re-checked here and must not be — the engine re-probes every path at
    /// the moment it acts (a folder that gained a file is skipped, and a folder the walk cannot
    /// fully read is never treated as empty). A plan-time check would only add a second, staler
    /// opinion.
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

    /// The deepest folder that CONTAINS every one of these paths — the family a scattered removal
    /// belongs to. `"."` when they share no ancestor but the root, which is the profile's own
    /// spelling for the tree (`FolderProfile` keys the root that way), and the common answer for
    /// the standing empties: they are wherever the tree left them.
    ///
    /// The parents are compared, not the paths themselves: one ticked `Travel/2019` belongs to
    /// `Travel`, and calling the folder its own family would name the thing being removed.
    public static func commonAncestor(of paths: [String]) -> String {
        RestructurePaths.commonAncestor(
            of: paths.map { ($0 as NSString).deletingLastPathComponent })
    }
}

/// The scaffold's manifest builder — §5.2's backlog fix as §5.4's schema.
public enum RestructureScaffold {

    /// `create-dir` actions for everything the family's vouched vocabulary expects that the
    /// newest member does not have — which is all of it, since the member fired for having no
    /// folders at all. nil when the finding is not a backlog or vouches for nothing: an empty
    /// scaffold is a card sentence, not an empty landing.
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
