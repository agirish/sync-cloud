import Foundation

/// What every already-filed document contributed, kept so a re-survey does not have to read it again.
///
/// ``FilingMemory`` is the per-*folder* aggregate the router scores against. This is the per-*document*
/// ledger behind it, and it exists for one reason: **extraction is the only expensive part of a
/// survey.** Reading page 1 of 9,525 documents is hours of PDF parsing and OCR; deriving the memory
/// from tokens that have already been read is seconds of arithmetic. Keeping the tokens means a
/// re-survey costs only the documents that actually changed — on the tree this was built for, 13
/// folders' worth against 2,296 unchanged ones.
///
/// **Tokens, never text.** The memory file is careful not to be a readable list of account numbers,
/// and a per-document store of raw page-1 text would undo that at ten times the size. What is kept
/// is exactly what the memory builder consumes: the readable anchors, and digit-bearing tokens under
/// the *same salted hash* the memory uses. That is why ``salt`` is stored here too — the two files
/// have to agree, and a corpus written under a different salt cannot contribute to a memory.
///
/// **Content tokens only; filename tokens are derived at build time.** The builder scores a document
/// by its page-1 tokens *and* its filename, but a filename is the half that changes — the rename pass
/// exists to change it. Deriving it from the key on every build means a rename costs a re-key, never
/// a re-read.
public struct FilingCorpus: Sendable, Equatable {
    public static let currentSchema = 1

    public let profileId: String
    /// The salt every ``documents`` id hash was produced under. Must equal the memory's.
    public let salt: String
    /// Keyed by path relative to the surveyed root — the same relativisation
    /// ``FilingEngine/relativeFolderPaths(of:limit:)`` uses, so a corpus key and a memory key name
    /// the same folder.
    public var documents: [String: FilingCorpusDocument]

    public init(profileId: String, salt: String, documents: [String: FilingCorpusDocument] = [:]) {
        self.profileId = profileId
        self.salt = salt
        self.documents = documents
    }

    public var isEmpty: Bool { documents.isEmpty }
}

/// One document's contribution, stamped with what it was read at.
public struct FilingCorpusDocument: Sendable, Equatable {
    /// Size in bytes and whole-second mtime at the moment the tokens below were derived. Together
    /// they are the "has this changed?" test: cheap to read during a walk that is happening anyway,
    /// and wrong only for an edit that preserves both — which for an archived document means an edit
    /// that preserved the byte count to the second, and would change page 1 without changing what
    /// the folder is for.
    public let size: Int
    public let modified: Int
    /// Readable page-1 tokens, deduplicated — a document contributes each token once, because the
    /// builder counts documents-per-token and not occurrences.
    public let anchors: [String]
    /// Digit-bearing page-1 tokens, salted-hashed.
    public let idHashes: [String]

    public init(size: Int, modified: Int, anchors: [String], idHashes: [String]) {
        self.size = size
        self.modified = modified
        self.anchors = anchors
        self.idHashes = idHashes
    }

    /// True when the document was read and yielded nothing usable — an image-only scan, a PDF whose
    /// fonts carry no `ToUnicode` map, a two-line receipt.
    ///
    /// **Recorded rather than forgotten, and that is the point.** An unusable document that is simply
    /// absent from the corpus gets re-read on every single survey — the pathological case being a
    /// folder of scans, which is both the most expensive to read and the least rewarding. Stamped,
    /// it costs one `stat` a survey until it changes.
    public var isBlank: Bool { anchors.isEmpty && idHashes.isEmpty }
}

// MARK: - On-disk shape

extension FilingCorpusDocument: Codable {
    /// Short keys, deliberately. At ~9,500 documents carrying ~40 tokens each, `"anchors"` spelled
    /// in full for every one of them is a measurable fraction of the file for no reader's benefit —
    /// nothing hand-edits this the way the memory and the profile get hand-inspected.
    private enum Key: String, CodingKey { case size = "s", modified = "m", anchors = "a", idHashes = "i" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        modified = try c.decodeIfPresent(Int.self, forKey: .modified) ?? 0
        anchors = try c.decodeIfPresent([String].self, forKey: .anchors) ?? []
        idHashes = try c.decodeIfPresent([String].self, forKey: .idHashes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(size, forKey: .size)
        try c.encode(modified, forKey: .modified)
        // Omitted when empty rather than written as `[]`: a blank document is the common case in a
        // folder of scans and this is the difference between two bytes and none, ~9,500 times over.
        if !anchors.isEmpty { try c.encode(anchors, forKey: .anchors) }
        if !idHashes.isEmpty { try c.encode(idHashes, forKey: .idHashes) }
    }
}

extension FilingCorpus: Codable {
    private enum Key: String, CodingKey { case schemaVersion, profileId, salt, note, documents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        // Same rule as the other filing artifacts: a foreign schema is discarded, not half-read. The
        // cost of being wrong here is a full re-survey, which is exactly what an absent corpus means.
        if let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion), v != FilingCorpus.currentSchema {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                                                   debugDescription: "corpus schema \(v) is not \(FilingCorpus.currentSchema)")
        }
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        salt = try c.decodeIfPresent(String.self, forKey: .salt) ?? ""
        documents = try c.decodeIfPresent([String: FilingCorpusDocument].self, forKey: .documents) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(FilingCorpus.currentSchema, forKey: .schemaVersion)
        try c.encode(profileId, forKey: .profileId)
        try c.encode(salt, forKey: .salt)
        try c.encode(documents, forKey: .documents)
        try c.encode("Page-1 tokens of each already-filed document, so a re-survey only has to read "
                     + "what changed. Companion to filing-memory.json, which is this aggregated by "
                     + "folder. Digit-bearing tokens are salted hashes under the salt above; no raw "
                     + "document text is stored.", forKey: .note)
    }
}
