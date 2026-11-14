import CryptoKit
import Foundation

/// What a folder has **received**: the discriminative content of the documents already filed in it.
///
/// The companion to ``FolderProfile``: the profile records what a folder *is*, mined from names;
/// this records what it has been given, mined from page 1. Names are often useless (payslips named
/// `Nov 30 Paycheck EMP.pdf` beside `Payslip_2025-11-28.pdf`, screenshots carrying only a case
/// number), and adding this to the profile roughly doubles top-1 routing accuracy.
///
/// Not portable, like the profile: it describes one person's documents. A missing memory restores
/// profile-only behaviour exactly.
public struct FilingMemory: Sendable, Equatable {
    public let profileId: String
    /// Salt for ``hash(_:salt:)``, stored beside the hashes it produces. It keeps the file, which
    /// sits in Application Support and gets backed up, from being a readable list of account
    /// numbers. It is **obfuscation, not a security boundary.**
    public let salt: String
    public let folders: [String: FilingMemoryEntry]

    public init(profileId: String, salt: String, folders: [String: FilingMemoryEntry]) {
        self.profileId = profileId
        self.salt = salt
        self.folders = folders
    }

    public var isEmpty: Bool { folders.isEmpty }

    /// `sha256(salt + token)`, first 16 hex characters. The offline builder writes these, so any
    /// change here silently stops every identifier matching (lost accuracy, no error);
    /// `FilingProfileStoreTests/theIdentifierHashMatchesTheBuilder` pins a token and salt to a
    /// literal.
    static func hash(_ token: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + token).utf8))
        // The first eight bytes: sixteen hex characters, the builder's form.
        return HexEncoding.string(digest.prefix(8))
    }
}

/// One folder's learned content.
public struct FilingMemoryEntry: Sendable, Equatable {
    /// How many filed documents this was learned from. Scores divide by its square root so a folder
    /// doesn't win on volume.
    public let docs: Int
    /// Readable words (provider, document type, clinician, plan name) with their rarity weight.
    /// Readable on purpose: they are also the useful half of a paid-tier prompt.
    public let anchors: [FilingMemoryToken]
    /// Digit-bearing tokens (account last-4, case, member and policy numbers), hashed.
    public let idHashes: [FilingMemoryToken]
    /// The folder's own modification time when this entry was learned, whole seconds since 1970:
    /// the staleness key. A directory's mtime moves when a child is added, removed or renamed, the
    /// events that make learned content wrong, so comparing it with the disk names the folders
    /// worth re-reading without opening a document. nil (the builder couldn't stat it) reads as
    /// stale.
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
    /// Share of this folder's documents whose first page contains the token, 0…1, or nil for an
    /// artifact built without it. Weight ranks how well a word tells this folder from others, which
    /// makes the heaviest word the one least likely to recur (one campaign's `awesome` over every
    /// bill's `autopay`), so a rule needs both. See ``AutomationRuleProposer/recurrenceFloor``.
    public let docFrequency: Double?

    public init(token: String, weight: Double, docFrequency: Double? = nil) {
        self.token = token
        self.weight = weight
        self.docFrequency = docFrequency
    }
}

// MARK: - Decoding the on-disk shape

extension FilingMemoryToken: Decodable {
    /// Stored as a positional array `["kaiser", 3.9, 0.85]`, because across tens of thousands of
    /// tokens the key names would be a third of the file. The third element (document share) is
    /// optional: an artifact without it decodes with `nil`, which is why the proposer has a
    /// family-agreement fallback.
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
        // The builder writes a JSON null when it couldn't stat the folder; `decodeIfPresent`
        // tolerates both null and an absent key.
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
    /// The same positional array the reader expects: `["kaiser", 3.9, 0.85]`. **Write the third
    /// element whenever it is known.** It is optional by position, so a file without it still
    /// decodes and silently sends ``AutomationRuleProposer`` back to keying rules on the rarest
    /// word rather than the recurring one.
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
        // `encode`, not `encodeIfPresent`: null and absent mean the same to the reader, and writing
        // the key keeps the shape identical to the Python builder's.
        try c.encode(folderModified, forKey: .folderModified)
    }
}
