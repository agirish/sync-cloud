import Foundation

/// What the user said about whether a document is a person's.
///
/// **Only his verdicts are ever written.** Everything the channels compute is recomputed on demand
/// and shown as such; the moment a computed attribution were persisted it would stop tracking the
/// roster, and a name added to `people.json` next week would leave a stale tag behind claiming
/// otherwise. What cannot be recomputed is what he decided, so that — and only that — is the file.
public enum PersonTagVerdict: Sendable, Equatable {
    /// His: durable through renames and moves, and shown above any computed evidence.
    case confirmed
    /// Not his. **The whole point of persisting a rejection**: the channels are deterministic, so
    /// the same weak match reappears on every gather forever unless the refusal is remembered.
    case rejected
    /// A verdict written by a newer build of the app, kept exactly as it was read.
    ///
    /// **This case is why the file has hand-written `Codable`, and it is not hypothetical here.**
    /// `personIs` rules once lost their entire file to this: the rule conditions were one JSON blob
    /// with a synthesized decoder, so a build that met a case it did not know threw on the *whole
    /// array* and the user's rules were silently wiped. A tag file that meets `"maybe"` from a
    /// future build must skip that one tag, keep the rest, and write `"maybe"` back untouched —
    /// otherwise round-tripping through this build is data loss for the build that wrote it.
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
    /// on: guessing that an unknown word means "yes" is how a future "maybe" becomes a wrong answer.
    public var isActionable: Bool {
        switch self {
        case .confirmed, .rejected: return true
        case .unrecognized: return false
        }
    }
}

/// What a verdict is attached to.
///
/// **The fingerprint where one exists, the path otherwise**, and the fallback is a real fallback
/// rather than a lesser option: only PDFs can be fingerprinted at all
/// (``ContentFingerprint/fingerprintableExtensions``), and a photo or a `.docx` still needs to be
/// taggable. A path-keyed verdict is the weaker promise — it does not survive the file moving, which
/// is exactly what Organize exists to do — and the surface says so rather than pretending both keys
/// mean the same thing.
public enum PersonTagKey: Sendable, Equatable, Hashable {
    /// ``ContentFingerprint/digest(of:)`` — survives a rename, a move, and a provider re-stamping
    /// the bytes on re-download, which is the case item 18 was built for.
    case fingerprint(String)
    /// Path relative to the surveyed root, as the corpus keys it.
    case path(String)
}

/// One verdict: this person, this document, this answer.
public struct PersonTag: Sendable, Equatable, Identifiable {
    public let personId: String
    public let key: PersonTagKey
    public let verdict: PersonTagVerdict
    /// The path the verdict was made at — carried even for a fingerprint key, because a list of
    /// verdicts the user can audit has to say *which file*, and a digest is not a file to a reader.
    /// Where the verdict was recorded. Advisory for identity — the KEY is what identifies the
    /// document — but it is what `PersonTagIndex.byRecordedPath` answers a path lookup from, and
    /// `PersonTagStore.record` both refreshes it when a document is re-answered somewhere new and
    /// matches on it to supersede a differently-keyed verdict on the same document.
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
/// **Tag by tag is the whole design.** A malformed or future-shaped entry costs that entry and
/// nothing else; the alternative — one `[PersonTag]` with a synthesized decoder — throws on the
/// first surprise and takes every verdict the user ever made with it.
struct PersonTagFile: Sendable, Equatable {
    /// The version the file was written under, kept rather than assumed. See `encode`: this build
    /// re-stamps whichever is HIGHER, so opening a newer file does not relabel it as an older one.
    var schemaVersion: Int
    var tags: [PersonTag]
    /// Elements this build could not decode into a `PersonTag`, held exactly as they arrived.
    ///
    /// **A tag that cannot be read is not a tag that can be discarded.** Decoding tag-by-tag stops
    /// one bad element taking the file down, but the element itself was then swallowed by an
    /// ignore-wrapper — not counted, not logged — and the next verdict the user recorded rewrote
    /// the file without it. Forty judgements could disappear with nothing on screen and nothing in
    /// the log. Same failure the automation rules had, same answer: carry the raw value and write
    /// it back. It plays no part in any lookup, which is the point — it is data being preserved,
    /// not a verdict being honoured.
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
        // A tag with neither key names no document and is dropped by the container; a tag with both
        // prefers the fingerprint, which is the stronger promise.
        if let f = try c.decodeIfPresent(String.self, forKey: .fingerprint), !f.isEmpty {
            key = .fingerprint(f)
        } else if let p = try c.decodeIfPresent(String.self, forKey: .path), !p.isEmpty {
            key = .path(p)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c,
                                                   debugDescription: "a tag with no fingerprint and no path")
        }
        // A path-keyed tag written before `at` existed already names its file in the key; a
        // fingerprint-keyed one written that way genuinely has no path to show, and says so.
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
        // **Not `decode([PersonTag].self)`.** Decoding the array as a unit means one bad element
        // throws away every good one — the failure that wiped the rule file. Each element is
        // decoded in its own `try?` so a tag this build cannot read costs exactly itself.
        var list: [PersonTag] = []
        var raw: [JSONFragment] = []
        if var array = try? c.nestedUnkeyedContainer(forKey: .tags) {
            while !array.isAtEnd {
                // A failed element still has to be consumed, or the loop cannot advance past it —
                // and consuming it is where it used to be LOST. `JSONFragment` consumes it and
                // keeps it, so `encode` can put it back exactly as it was found. `AnyIgnored`
                // remains the last resort for an element even that cannot represent, which is the
                // only case where stepping over really is all that can be done.
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
        // **The higher of the two, not this build's own.** Stamping `currentSchema` unconditionally
        // relabels a file a newer build wrote as one written by this one — while that same write
        // now carries the newer build's own tags through `unreadable`. The number would then be the
        // only thing in the file claiming those tags are v1 shaped, and it would be wrong. Reading
        // it here is also what stops `schemaVersion` being a field nothing consults, which is the
        // pattern this file was faulted for rather than the fix for it.
        try c.encode(max(schemaVersion, PersonTagFile.currentSchema), forKey: .schemaVersion)
        // Elements this build could not read go back in beside the ones it could. Appended last so
        // the tags it understands keep the order the store sorted them into.
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
