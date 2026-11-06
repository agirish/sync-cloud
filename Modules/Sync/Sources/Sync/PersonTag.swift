import Foundation

/// What the user said about whether a document is a person's.
///
/// Only the user's verdicts are written. Computed attributions are recomputed on demand: persisted,
/// they would stop tracking the roster and go stale when a name is added. What can't be recomputed
/// is what the user decided, so that alone is the file.
public enum PersonTagVerdict: Sendable, Equatable {
    /// Theirs: durable through renames and moves, and shown above any computed evidence.
    case confirmed
    /// Not theirs. Persisted because the channels are deterministic: the same weak match would
    /// reappear on every gather unless the refusal is remembered.
    case rejected
    /// A verdict written by a newer build of the app, kept exactly as it was read.
    ///
    /// Why the file has hand-written `Codable`: a synthesized decoder that meets an unknown case
    /// throws on the whole array, and the next save wipes every verdict. A `"maybe"` from a future
    /// build must be kept and written back untouched, or opening the file in this build loses data.
    case unrecognized(String)

    /// The string as it is stored, so an unrecognized verdict round-trips verbatim.
    public var rawValue: String {
        switch self {
        case .confirmed: return "confirmed"
        case .rejected: return "rejected"
        case .unrecognized(let raw): return raw
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "confirmed": self = .confirmed
        case "rejected": self = .rejected
        default: self = .unrecognized(rawValue)
        }
    }

    /// Whether this build knows what to do with it. An unrecognized verdict is carried, never acted
    /// on: guessing that an unknown word means "yes" turns a future "maybe" into a wrong answer.
    public var isActionable: Bool {
        switch self {
        case .confirmed, .rejected: return true
        case .unrecognized: return false
        }
    }
}

/// What a verdict is attached to.
///
/// The fingerprint where one exists, the path otherwise. Only PDFs can be fingerprinted
/// (``ContentFingerprint/fingerprintableExtensions``), and a photo or `.docx` still needs a verdict.
/// A path key is the weaker promise: it doesn't survive a move, which Organize exists to make, and
/// the surface says so.
public enum PersonTagKey: Sendable, Equatable, Hashable {
    /// ``ContentFingerprint/digest(of:)``: survives a rename, a move, and a provider re-stamping
    /// the bytes on re-download.
    case fingerprint(String)
    /// Path relative to the surveyed root, as the corpus keys it.
    case path(String)
}

/// One verdict: this person, this document, this answer.
public struct PersonTag: Sendable, Equatable, Identifiable {
    public let personId: String
    public let key: PersonTagKey
    public let verdict: PersonTagVerdict
    /// The path the verdict was made at, carried even for a fingerprint key so an auditable list
    /// can name the file. The key identifies the document; this answers
    /// `PersonTagIndex.byRecordedPath` lookups, and `PersonTagStore.record` refreshes it on a
    /// re-answer and matches on it to supersede a differently-keyed verdict on the same document.
    public let recordedPath: String

    public var id: String { "\(personId)|\(keyDescription)" }

    var keyDescription: String {
        switch key {
        case .fingerprint(let f): return "f:\(f)"
        case .path(let p): return "p:\(p)"
        }
    }

    public init(personId: String, key: PersonTagKey, verdict: PersonTagVerdict,
                recordedPath: String) {
        self.personId = personId
        self.key = key
        self.verdict = verdict
        self.recordedPath = recordedPath
    }
}

// MARK: - On-disk shape

/// The file, decoded tag by tag.
///
/// Tag by tag so a malformed or future-shaped entry costs only itself; a synthesized
/// `[PersonTag]` decoder throws on the first surprise and takes every verdict with it.
struct PersonTagFile: Sendable, Equatable {
    /// The version the file was written under, kept rather than assumed. `encode` writes the
    /// higher of this and this build's, so a newer file is never relabelled as older.
    var schemaVersion: Int
    var tags: [PersonTag]
    /// Elements this build could not decode into a `PersonTag`, held exactly as they arrived.
    ///
    /// A tag that can't be read must not be discarded: skipped, it would vanish from the file at
    /// the next save. So the raw value is carried and written back. It plays no part in any lookup:
    /// it is data preserved, not a verdict honoured.
    var unreadable: [JSONFragment]

    init(schemaVersion: Int = PersonTagFile.currentSchema, tags: [PersonTag] = [],
         unreadable: [JSONFragment] = []) {
        self.schemaVersion = schemaVersion
        self.tags = tags
        self.unreadable = unreadable
    }

    static let currentSchema = 1
}

extension PersonTag: Codable {
    private enum Key: String, CodingKey {
        case person, verdict, fingerprint, path, at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        personId = try c.decode(String.self, forKey: .person)
        verdict = PersonTagVerdict(rawValue: try c.decode(String.self, forKey: .verdict))
        // A tag with neither key names no document and throws, so the file keeps it raw in
        // `unreadable`; a tag with both prefers the fingerprint, the stronger promise.
        if let f = try c.decodeIfPresent(String.self, forKey: .fingerprint), !f.isEmpty {
            key = .fingerprint(f)
        } else if let p = try c.decodeIfPresent(String.self, forKey: .path), !p.isEmpty {
            key = .path(p)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c,
                                                   debugDescription: "a tag with no fingerprint and no path")
        }
        // A tag with no `at`: a path key already names its file; a fingerprint key has no path to
        // show, so it is empty.
        let fallbackPath: String
        if case .path(let p) = key { fallbackPath = p } else { fallbackPath = "" }
        recordedPath = try c.decodeIfPresent(String.self, forKey: .at) ?? fallbackPath
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(personId, forKey: .person)
        // The raw string, so an unrecognized verdict is written back exactly as it was read.
        try c.encode(verdict.rawValue, forKey: .verdict)
        switch key {
        case .fingerprint(let f): try c.encode(f, forKey: .fingerprint)
        case .path(let p): try c.encode(p, forKey: .path)
        }
        if !recordedPath.isEmpty { try c.encode(recordedPath, forKey: .at) }
    }
}

extension PersonTagFile: Codable {
    private enum Key: String, CodingKey { case schemaVersion, tags, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? PersonTagFile.currentSchema
        // Not `decode([PersonTag].self)`: decoding the array as a unit lets one bad element throw
        // away every good one. Each element gets its own `try?`, so a bad one costs only itself.
        var list: [PersonTag] = []
        var raw: [JSONFragment] = []
        if var array = try? c.nestedUnkeyedContainer(forKey: .tags) {
            while !array.isAtEnd {
                // A failed element must still be consumed or the loop can't advance. `JSONFragment`
                // consumes and keeps it, so `encode` writes it back as found. `AnyIgnored` is the
                // last resort for an element even that can't represent.
                if let tag = try? array.decode(PersonTag.self) {
                    list.append(tag)
                } else if let fragment = try? array.decode(JSONFragment.self) {
                    raw.append(fragment)
                } else {
                    _ = try? array.decode(AnyIgnored.self)
                }
            }
        }
        tags = list
        unreadable = raw
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        // The higher of the two, not this build's own: this write carries a newer build's tags
        // through `unreadable`, and stamping `currentSchema` would wrongly label them as this
        // build's shape.
        try c.encode(max(schemaVersion, PersonTagFile.currentSchema), forKey: .schemaVersion)
        // Elements this build couldn't read go back beside the ones it could, appended last so the
        // readable tags keep the store's order.
        var array = c.nestedUnkeyedContainer(forKey: .tags)
        for tag in tags { try array.encode(tag) }
        for fragment in unreadable { try array.encode(fragment) }
        try c.encode("Whose document this is, as YOU said — never what the app worked out. "
                     + "Computed attributions are recomputed on every gather and are not stored. "
                     + "Keyed by the document's text fingerprint where it has one, so a verdict "
                     + "survives a rename or a move; by path otherwise.", forKey: .note)
    }
}

/// Consumes one element of an unkeyed container without caring what it was, so a tag this build
/// cannot decode can be stepped over rather than ending the decode.
private struct AnyIgnored: Decodable {
    init(from decoder: Decoder) throws {
        // Succeeds for any JSON value: a single-value container accepts objects and arrays too, as
        // long as nothing is asked of them.
        _ = try decoder.singleValueContainer()
    }
}
