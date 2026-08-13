import CryptoKit
import Foundation

/// What a folder has **received** — the discriminative content of the documents already filed in it.
///
/// The companion to ``FolderProfile``, and the distinction is the point: the profile records what a
/// folder *is*, mined from names, while this records what it has *been given*, mined from page 1.
/// Names are frequently useless — a tree holds fourteen payslips called `Nov 30 Paycheck HPE.pdf`
/// belonging with files called `Payslip_2025-11-28.pdf`, and screenshots carrying nothing but a case
/// number that only an already-filed confirmation can attribute. Measured over 9,558 filed documents
/// choosing one of ~2,950 folders, adding this to the profile takes top-1 routing from 28.9% to
/// 58.2% and top-3 from 40.2% to 77.4%.
///
/// **Not portable, for the same reason the profile is not.** It is a description of one person's
/// documents; a missing memory restores the profile-only behaviour exactly.
public struct FilingMemory: Sendable, Equatable {
    public let profileId: String
    /// Salt for ``hash(_:)``. Stored beside the hashes it produces, necessarily — this keeps the
    /// file from being a readable list of account numbers, which is worth doing because it sits in
    /// Application Support and gets backed up. It is **obfuscation, not a security boundary.**
    public let salt: String
    public let folders: [String: FilingMemoryEntry]

    public init(profileId: String, salt: String, folders: [String: FilingMemoryEntry]) {
        self.profileId = profileId
        self.salt = salt
        self.folders = folders
    }

    public var isEmpty: Bool { folders.isEmpty }

    /// The stored form of a digit-bearing token. Matching is equality on this, so a candidate file's
    /// tokens are hashed the same way and compared — the raw account number never has to be stored.
    public func hash(_ token: String) -> String {
        FilingMemory.hash(token, salt: salt)
    }

    /// `sha256(salt + token)`, first 16 hex characters.
    ///
    /// The exact form matters: the builder that writes the file produces these, so a change here
    /// silently stops every identifier matching — the failure is a quiet loss of accuracy, not an
    /// error, which is why ``FilingMemoryTests`` pins a known token/salt pair against a literal.
    static func hash(_ token: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + token).utf8))
        var hex = ""
        hex.reserveCapacity(16)
        for byte in digest {
            hex += String(format: "%02x", byte)
            if hex.count >= 16 { break }
        }
        return String(hex.prefix(16))
    }
}

/// One folder's learned content.
public struct FilingMemoryEntry: Sendable, Equatable {
    /// How many filed documents this was learned from. Scores divide by its square root so a folder
    /// does not win on sheer volume.
    public let docs: Int
    /// Readable words — provider, document type, clinician, plan name — with their rarity weight.
    /// Readable on purpose: these are also the useful half of a prompt for the paid tier.
    public let anchors: [FilingMemoryToken]
    /// Digit-bearing tokens (account last-4, case, member and policy numbers), hashed.
    public let idHashes: [FilingMemoryToken]
    /// The folder's own modification time when this entry was learned, whole seconds since 1970.
    ///
    /// **The staleness key, and it was being written and thrown away.** The builder has stamped this
    /// since the memory first shipped; nothing decoded it, so every re-survey was a full one. A
    /// directory's mtime moves when a child is added, removed or renamed — exactly the events that
    /// make a folder's learned content wrong — so comparing it against the disk names the folders
    /// worth re-reading without opening a single document. nil for an entry from a build that could
    /// not stat the folder, which reads as "assume stale".
    public let folderModified: Int?

    public init(docs: Int, anchors: [FilingMemoryToken], idHashes: [FilingMemoryToken],
                folderModified: Int? = nil) {
        self.docs = docs
        self.anchors = anchors
        self.idHashes = idHashes
        self.folderModified = folderModified
    }
}

/// A token, how much it discriminates, and how often it comes back.
public struct FilingMemoryToken: Sendable, Equatable {
    public let token: String
    /// Rarity: higher means it appears in fewer folders.
    public let weight: Double
    /// Share of THIS folder's documents whose first page contains the token, 0…1 — and nil for an
    /// artifact built before the builder recorded it.
    ///
    /// **The two numbers answer opposite questions and a rule needs both.** Weight ranks how well a
    /// word tells this folder from every other one, which makes the heaviest word the one least
    /// likely to be seen again: `Home/Utilities/T-Mobile/2025` weighs `awesome` (one campaign) above
    /// `autopay` (every bill). A rule keyed on rarity alone matched nothing else in the tree 7.8% of
    /// the time. See ``AutomationRuleProposer/recurrenceFloor``.
    public let docFrequency: Double?

    public init(token: String, weight: Double, docFrequency: Double? = nil) {
        self.token = token
        self.weight = weight
        self.docFrequency = docFrequency
    }
}

// MARK: - Decoding the on-disk shape

extension FilingMemoryToken: Decodable {
    /// Stored as a positional array `["kaiser", 3.9, 0.85]` rather than an object, because at
    /// ~58,000 tokens the key names would be a third of the file. The third element is the document
    /// share and is **optional**: an artifact written before it existed decodes with `nil` there and
    /// keeps working, which is why the proposer has a family-agreement fallback rather than a
    /// requirement.
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        token = try c.decode(String.self)
        weight = (try? c.decode(Double.self)) ?? 1.0
        docFrequency = c.isAtEnd ? nil : try? c.decode(Double.self)
    }
}

extension FilingMemoryEntry: Decodable {
    private enum Key: String, CodingKey { case docs, anchors, idHashes, folderModified }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        docs = try c.decodeIfPresent(Int.self, forKey: .docs) ?? 0
        anchors = try c.decodeIfPresent([FilingMemoryToken].self, forKey: .anchors) ?? []
        idHashes = try c.decodeIfPresent([FilingMemoryToken].self, forKey: .idHashes) ?? []
        // Written as a JSON null when the builder could not stat the folder, so this must tolerate
        // an explicit null and not only an absent key — `decodeIfPresent` does both.
        folderModified = try c.decodeIfPresent(Int.self, forKey: .folderModified)
    }
}

extension FilingMemory: Decodable {
    private enum Key: String, CodingKey {
        case profileId, salt, folders
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        salt = try c.decodeIfPresent(String.self, forKey: .salt) ?? ""
        folders = try c.decodeIfPresent([String: FilingMemoryEntry].self, forKey: .folders) ?? [:]
    }
}

// MARK: - Writing it back

extension FilingMemoryToken: Encodable {
    /// The same positional array the reader expects — `["kaiser", 3.9, 0.85]`.
    ///
    /// **The third element is written whenever it is known**, and that is not a formality: it is
    /// optional *by position*, so a writer that stops emitting it produces a file that still decodes
    /// perfectly and quietly takes ``AutomationRuleProposer`` back to keying rules on the rarest word
    /// rather than the recurring one. A survey that rebuilt the memory without it would undo that
    /// work with no error anywhere.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(token)
        try c.encode(weight)
        if let docFrequency { try c.encode(docFrequency) }
    }
}

extension FilingMemoryEntry: Encodable {
    private enum WriteKey: String, CodingKey { case docs, anchors, idHashes, folderModified }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WriteKey.self)
        try c.encode(docs, forKey: .docs)
        try c.encode(anchors, forKey: .anchors)
        try c.encode(idHashes, forKey: .idHashes)
        // `encode` rather than `encodeIfPresent`: a null stamp and an absent one mean the same thing
        // to the reader, and writing the key keeps the shape identical to the Python builder's.
        try c.encode(folderModified, forKey: .folderModified)
    }
}
