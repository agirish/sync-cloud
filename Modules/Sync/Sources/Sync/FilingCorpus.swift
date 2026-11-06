import Foundation

/// What every already-filed document contributed, kept so a re-survey doesn't read it again.
///
/// ``FilingMemory`` is the per-folder aggregate the router scores against; this is the
/// per-document ledger behind it. Extraction is the only expensive part of a survey (hours of PDF
/// parsing and OCR, against seconds of arithmetic), so keeping the tokens means a re-survey reads
/// only the documents that changed.
///
/// **Tokens, never text:** raw page-1 text would make this a readable list of account numbers.
/// It keeps what the memory builder consumes: readable anchors, and digit-bearing tokens under the
/// memory's salted hash, which is why ``salt`` is stored too; a corpus under another salt can't
/// contribute to a memory. Filename tokens are derived from the key at build time, so a rename
/// costs a re-key, never a re-read.
public struct FilingCorpus: Sendable, Equatable {
    public static let currentSchema = 1

    public let profileId: String
    /// The salt every ``documents`` id hash was produced under. Must equal the memory's.
    public let salt: String
    /// Keyed by path relative to the surveyed root, as
    /// ``FilingEngine/relativeFolderPaths(of:limit:)`` relativises, so a corpus key and a memory
    /// key name the same folder.
    public var documents: [String: FilingCorpusDocument]
    /// When a survey last looked, whatever it found. On the corpus, not the memory: the memory is
    /// written only on change because its bytes key every cached verdict, so a stamp there would
    /// throw the cache away to record that nothing happened. Optional, so older or builder-written
    /// corpora still decode.
    public var surveyedAt: Date?

    public init(profileId: String, salt: String, documents: [String: FilingCorpusDocument] = [:],
                surveyedAt: Date? = nil) {
        self.profileId = profileId
        self.salt = salt
        self.documents = documents
        self.surveyedAt = surveyedAt
    }

    public var isEmpty: Bool { documents.isEmpty }
}

/// One document's contribution, stamped with what it was read at.
public struct FilingCorpusDocument: Sendable, Equatable {
    /// Size in bytes and whole-second mtime when the tokens below were derived: the "has this
    /// changed?" test, cheap during a walk that runs anyway. Misses only an edit that keeps both.
    public let size: Int
    public let modified: Int
    /// Readable page-1 tokens, deduplicated: the builder counts documents per token, not
    /// occurrences.
    public let anchors: [String]
    /// Digit-bearing page-1 tokens, salted-hashed.
    public let idHashes: [String]

    public init(size: Int, modified: Int, anchors: [String], idHashes: [String]) {
        self.size = size
        self.modified = modified
        self.anchors = anchors
        self.idHashes = idHashes
    }

    /// True when the document was read and yielded nothing usable: an image-only scan, a PDF whose
    /// fonts carry no `ToUnicode` map, a two-line receipt. Recorded rather than left out, or a
    /// folder of scans (the costliest to read) is re-read every survey; stamped, it costs one
    /// `stat`.
    public var isBlank: Bool { anchors.isEmpty && idHashes.isEmpty }
}

// MARK: - On-disk shape

extension FilingCorpusDocument: Codable {
    /// Short keys: across thousands of documents, full key names are a real share of the file, and
    /// nobody hand-inspects this one the way they do the memory and profile.
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
        // Omitted when empty rather than written as `[]`: blank documents are common in a folder of
        // scans.
        if !anchors.isEmpty { try c.encode(anchors, forKey: .anchors) }
        if !idHashes.isEmpty { try c.encode(idHashes, forKey: .idHashes) }
    }
}

extension FilingCorpus: Codable {
    private enum Key: String, CodingKey {
        case schemaVersion, profileId, salt, note, documents, surveyedAt, kind
    }

    /// What a corpus document says it is. Absent in older corpora and the offline builder's output,
    /// so the guard below fires only on a `kind` that is present and names something else.
    static let kind = "filing-corpus"

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        // **A file that says it is something else is not a corpus.** Everything below is
        // `decodeIfPresent ?? default` so older and builder-written corpora load, which means any
        // JSON sharing none of these keys decodes as an empty corpus: `.loaded`, not `.unreadable`
        // (``FilingSurveyStore/CorpusRead``). `.unreadable` makes the survey refuse and leave the
        // bytes alone; an empty `.loaded` is merged and written over the memory, discarding its
        // learned content and every cached verdict keyed to it. ``DocumentSurveyCheckpoint`` lives
        // next door, so one misplaced file would do exactly that. An unknown `kind` throws, and the
        // survey's refusal does the rest.
        if let kind = try c.decodeIfPresent(String.self, forKey: .kind), kind != FilingCorpus.kind {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "\(kind) is not a filing corpus")
        }
        // As for the other filing artifacts, a foreign schema is discarded, not half-read. Being
        // wrong costs a full re-survey, which is what an absent corpus means anyway.
        if let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion), v != FilingCorpus.currentSchema {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                                                   debugDescription: "corpus schema \(v) is not \(FilingCorpus.currentSchema)")
        }
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? "default"
        salt = try c.decodeIfPresent(String.self, forKey: .salt) ?? ""
        documents = try c.decodeIfPresent([String: FilingCorpusDocument].self, forKey: .documents) ?? [:]
        // Parsed leniently: a hand-edited or foreign stamp reads as "unknown", never as a decode
        // failure that would cost a full re-survey over a display field.
        surveyedAt = (try? c.decodeIfPresent(String.self, forKey: .surveyedAt))
            .flatMap { $0 }.flatMap(FilingArtifactStamp.date(from:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(FilingCorpus.currentSchema, forKey: .schemaVersion)
        // Written so the guard above has something to read back, and so a corpus can't be mistaken
        // for survey progress or the reverse.
        try c.encode(FilingCorpus.kind, forKey: .kind)
        try c.encode(profileId, forKey: .profileId)
        try c.encode(salt, forKey: .salt)
        try c.encode(documents, forKey: .documents)
        if let surveyedAt {
            try c.encode(FilingArtifactStamp.string(from: surveyedAt), forKey: .surveyedAt)
        }
        try c.encode("Page-1 tokens of each already-filed document, so a re-survey only has to read "
                     + "what changed. Companion to filing-memory.json, which is this aggregated by "
                     + "folder. Digit-bearing tokens are salted hashes under the salt above; no raw "
                     + "document text is stored.", forKey: .note)
    }
}
