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

    public enum ActionKind: String, Codable, Equatable, Sendable {
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

        public init(action: ActionKind, src: String? = nil, dst: String? = nil,
                    evidence: String? = nil, filesCarried: Int? = nil,
                    bytes: Int? = nil, md5: String? = nil,
                    collisionExpected: Bool? = nil, collidedInto: String? = nil) {
            self.action = action
            self.src = src
            self.dst = dst
            self.evidence = evidence
            self.filesCarried = filesCarried
            self.bytes = bytes
            self.md5 = md5
            self.collisionExpected = collisionExpected
            self.collidedInto = collidedInto
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
