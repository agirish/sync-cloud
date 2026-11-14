import Foundation
import UniformTypeIdentifiers

/// The Automations rule model. An automation is a readable sentence a user writes once (or teaches
/// by example): *when a loose file matches these on-device conditions, it belongs in this folder.*
/// It steers the Organize scan's suggestions, and the Automations lens dry-runs it and files only
/// the matches the user confirms. Every condition is answered locally (path, filename glob, UTType,
/// size, modification date, on-device text), so a rule is deterministic, private and free: no
/// Claude Cloud classifier is ever consulted here.

// MARK: - File kind

/// A coarse file family a rule can match, derived from the file's extension via `UTType`.
/// Deliberately coarse ("kind is an image", not a UTI list), because that is what a person
/// reasons about.
public enum FileKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case image, pdf, video, audio, archive, document

    public var id: String { rawValue }

    /// User-facing label, also used to resolve the `{kind}` destination token.
    public var label: String {
        switch self {
        case .image: return "Image"
        case .pdf: return "PDF"
        case .video: return "Video"
        case .audio: return "Audio"
        case .archive: return "Archive"
        case .document: return "Document"
        }
    }

    /// The UTTypes this kind is satisfied by. A file matches when the type derived from its
    /// extension conforms to any of these.
    var matchingTypes: [UTType] {
        switch self {
        case .image: return [.image]
        case .pdf: return [.pdf]
        // `.movie` only, not `.audiovisualContent`, which `public.audio` also conforms to: an mp3
        // would classify as video, since `.of` checks video before audio.
        case .video: return [.movie]
        case .audio: return [.audio]
        case .archive: return [.archive, .gzip, .zip]
        // "Document" is the common office/text family, minus PDF (which has its own kind).
        case .document: return [.plainText, .rtf, .spreadsheet, .presentation,
                                UTType("com.microsoft.word.doc") ?? .text,
                                UTType("org.openxmlformats.wordprocessingml.document") ?? .text,
                                .text]
        }
    }

    /// Whether a file with the given extension is of this kind. By extension, so it needs no disk
    /// access and works for evicted cloud files.
    public func matches(fileExtension ext: String) -> Bool {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return false }
        return matchingTypes.contains { type.conforms(to: $0) }
    }

    /// The kind of a file name, or nil when the extension maps to nothing recognized. `.pdf` is
    /// checked before `.document` so a PDF resolves to "PDF", not the broader "Document".
    public static func of(fileName: String) -> FileKind? {
        let ext = (fileName as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        for kind in [FileKind.image, .pdf, .video, .audio, .archive, .document] where kind.matches(fileExtension: ext) {
            return kind
        }
        return nil
    }
}

// MARK: - Condition

/// One on-device test a rule can apply to a file, combined by ``AutomationRule/MatchMode``.
/// ``requiresContent`` marks the cases that may need the file's text read (PDFKit, Vision OCR,
/// plain text), so the evaluator pays that cost only when a rule asks for it.
public enum AutomationCondition: Sendable, Equatable, Codable, Hashable {
    /// The file's immediate parent folder is named this (case-insensitive). "Location".
    case folderNamed(String)
    /// The file name matches this shell glob (`*`, `?`), case-insensitive. Reuses ``IgnoreRules``.
    case nameMatches(String)
    /// The file is of this coarse kind (by extension → UTType).
    case kindIs(FileKind)
    /// The file is larger than this many megabytes.
    case largerThanMB(Int)
    /// The file hasn't been modified in at least this many days ("untouched").
    case untouchedForDays(Int)
    /// The file's on-device text contains this term (case-insensitive substring of the extracted
    /// excerpt).
    case contentContains(String)
    /// The file *mentions* every one of these canonical tokens, in its name or its on-device text.
    /// The learned-by-example condition: tokens come from ``FilingEngine/nameTokens(_:)``
    /// (lowercased, stopwords dropped), matched as a subset of the file's name ∪ content tokens.
    case mentionsAll([String])
    /// The file mentions any one of these phrases, each canonical tokens joined by a space ("japan
    /// airlines") and matched as ``mentionsAll`` matches. A rule taught from a chat correction keys
    /// on this: JAL is one airline, and the rule is for every airline's ticket.
    case mentionsAny([String])
    /// The document is about this person: the household member with this registry id. Keyed on
    /// the id, which survives a rename or a new name variant; a name word can't be keyed safely,
    /// since it can be one person's given name and others' surname.
    case personIs(String)
    /// A condition written by a newer build, preserved verbatim. Rules are persisted as one JSON
    /// blob, and failing on an unknown case would take the whole array with it, so the next edit
    /// would write the empty set over every rule. This round-trips untouched, and since it is never
    /// `isComplete` it never matches anything.
    case unrecognized(name: String, payload: Data)

    /// True for conditions that may need the file's text extracted, so the expensive read can be
    /// deferred. `mentionsAll` counts: content can supply a token the name lacks.
    ///
    /// **Keep this switch total, with no `default:`.** It gates whether a snippet is extracted at
    /// all, so a content condition answering `false` here gets no text and matches nothing, with
    /// no error or log line, while its rule shows as runnable. Adding a case must break the build.
    ///
    /// `personIs` is `false` on purpose: a document about someone almost always says so in its
    /// name, and forcing text extraction for every person rule costs seconds per scan. Content
    /// already read still counts (``PersonRegistry/attribute(fileName:pageSample:)``).
    /// `unrecognized` is never ``isComplete``, and ``AutomationRule/requiresContent`` asks only
    /// complete conditions, so its answer never matters.
    public var requiresContent: Bool {
        switch self {
        case .contentContains, .mentionsAll, .mentionsAny: return true
        case .folderNamed, .nameMatches, .kindIs, .largerThanMB, .untouchedForDays,
             .personIs, .unrecognized: return false
        }
    }

    /// A plain-words description for the rule summary and editor, e.g. "in a folder named Downloads".
    public var summary: String {
        switch self {
        case .folderNamed(let name):
            return "in a folder named \(name.isEmpty ? "…" : name)"
        case .nameMatches(let glob):
            return "name matches \(glob.isEmpty ? "…" : glob)"
        case .kindIs(let kind):
            return "kind is \(kind.label)"
        case .largerThanMB(let mb):
            return "larger than \(mb) MB"
        case .untouchedForDays(let days):
            return "not modified in \(days) day\(days == 1 ? "" : "s")"
        case .contentContains(let term):
            return "text contains “\(term.isEmpty ? "…" : term)”"
        case .mentionsAll(let tokens):
            let cleaned = tokens.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !cleaned.isEmpty else { return "mentions …" }
            return "mentions " + cleaned.map { "“\($0)”" }.joined(separator: " and ")
        case .mentionsAny(let phrases):
            let cleaned = phrases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !cleaned.isEmpty else { return "mentions any of …" }
            return "mentions any of " + cleaned.map { "“\($0)”" }.joined(separator: ", ")
        case .personIs(let id):
            // The id, not a display name: this type has no roster. The editor and rule list
            // substitute the name (`automationConditionChipText(_:people:)`).
            return "is \(id.isEmpty ? "…" : id)’s document"
        case .unrecognized(let name, _):
            return "\(name) (from a newer version)"
        }
    }

    /// Whether the condition is fully specified (a blank glob / term / zero threshold is a
    /// half-built condition the editor shouldn't let the user save).
    public var isComplete: Bool {
        switch self {
        case .folderNamed(let s), .nameMatches(let s), .contentContains(let s):
            return !s.trimmingCharacters(in: .whitespaces).isEmpty
        case .largerThanMB(let n): return n > 0
        case .untouchedForDays(let n): return n > 0
        case .kindIs: return true
        case .mentionsAll(let tokens):
            return tokens.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .mentionsAny(let phrases):
            return phrases.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .personIs(let id): return !id.trimmingCharacters(in: .whitespaces).isEmpty
        // Never complete, so a rule carrying one can be seen and edited but can never quietly
        // match a file on a condition this build does not understand.
        case .unrecognized: return false
        }
    }

    /// A stable key for the condition's *type* (not its value), so the editor can offer a type
    /// picker and swap the value while keeping the row.
    public var kindKey: String {
        switch self {
        case .folderNamed: return "folderNamed"
        case .nameMatches: return "nameMatches"
        case .kindIs: return "kindIs"
        case .largerThanMB: return "largerThanMB"
        case .untouchedForDays: return "untouchedForDays"
        case .contentContains: return "contentContains"
        case .mentionsAll: return "mentionsAll"
        case .mentionsAny: return "mentionsAny"
        case .personIs: return "personIs"
        case .unrecognized(let name, _): return name
        }
    }
}

// MARK: - Persistence that survives a version it does not know

extension AutomationCondition {
    /// The wire shape is exactly Swift's synthesized one: a single-key object, the case name, whose
    /// value is `{"_0": <payload>}`. Hand-written only so an unknown key survives decoding; older
    /// and newer builds read each other's bytes.
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    private enum PayloadKey: String, CodingKey { case _0 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let key = c.allKeys.first, c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Expected exactly one condition key, found \(c.allKeys.count)"))
        }
        // A known name whose payload can't be read (say a `FileKind` a newer build added) degrades
        // to `.unrecognized` like an unknown name, so only this condition is lost, not the whole
        // `conditions` array. The container is asked for with `try?` too: a payload that isn't an
        // object (`{"kindIs":"pdf"}`) makes `nestedContainer` throw, and must reach the same
        // recovery.
        if let payload = try? c.nestedContainer(keyedBy: PayloadKey.self, forKey: key),
           let recognized = try? Self.recognized(name: key.stringValue, payload: payload) {
            self = recognized
        } else {
            // Kept as bytes to be written back untouched. `RawPayload` makes them by round-tripping
            // a `JSONFragment`, so it survives exactly what that type can express.
            let raw = try c.decode(RawPayload.self, forKey: key)
            self = .unrecognized(name: key.stringValue, payload: raw.data)
        }
    }

    /// The case for a name this build knows, or nil for one it doesn't. Throwing means "my case, but
    /// an unreadable payload", which the caller treats like an unknown name.
    private static func recognized(name: String,
                                   payload: KeyedDecodingContainer<PayloadKey>) throws -> AutomationCondition? {
        switch name {
        case "folderNamed": return .folderNamed(try payload.decode(String.self, forKey: ._0))
        case "nameMatches": return .nameMatches(try payload.decode(String.self, forKey: ._0))
        case "kindIs": return .kindIs(try payload.decode(FileKind.self, forKey: ._0))
        case "largerThanMB": return .largerThanMB(try payload.decode(Int.self, forKey: ._0))
        case "untouchedForDays": return .untouchedForDays(try payload.decode(Int.self, forKey: ._0))
        case "contentContains": return .contentContains(try payload.decode(String.self, forKey: ._0))
        case "mentionsAll": return .mentionsAll(try payload.decode([String].self, forKey: ._0))
        case "mentionsAny": return .mentionsAny(try payload.decode([String].self, forKey: ._0))
        case "personIs": return .personIs(try payload.decode(String.self, forKey: ._0))
        default: return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        func write(_ value: some Encodable, _ name: String) throws {
            var payload = c.nestedContainer(keyedBy: PayloadKey.self, forKey: AnyKey(stringValue: name))
            try payload.encode(value, forKey: ._0)
        }
        switch self {
        case .folderNamed(let v): try write(v, "folderNamed")
        case .nameMatches(let v): try write(v, "nameMatches")
        case .kindIs(let v): try write(v, "kindIs")
        case .largerThanMB(let v): try write(v, "largerThanMB")
        case .untouchedForDays(let v): try write(v, "untouchedForDays")
        case .contentContains(let v): try write(v, "contentContains")
        case .mentionsAll(let v): try write(v, "mentionsAll")
        case .mentionsAny(let v): try write(v, "mentionsAny")
        case .personIs(let v): try write(v, "personIs")
        case .unrecognized(let name, let payload):
            try c.encode(RawPayload(data: payload), forKey: AnyKey(stringValue: name))
        }
    }

    /// Carries an arbitrary JSON value through decode and encode without interpreting it.
    ///
    /// It stores the bytes a `JSONFragment` re-encodes to, so a payload is only as faithful as that
    /// type.
    private struct RawPayload: Codable {
        let data: Data
        init(data: Data) { self.data = data }
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(JSONFragment.self)
            data = try JSONEncoder().encode(value)
        }
        func encode(to encoder: Encoder) throws {
            let value = try JSONDecoder().decode(JSONFragment.self, from: data)
            var c = encoder.singleValueContainer()
            try c.encode(value)
        }
    }
}

// MARK: - Rule

/// A single automation. `destinationTemplate` is provider-relative (`Documents/Invoices/{year}`),
/// resolved against whichever provider root the preview runs over, so a rule is portable across
/// providers (unlike ``FilingRule``, which stores an absolute destination).
public struct AutomationRule: Sendable, Equatable, Codable, Identifiable, Hashable {
    public var id: UUID
    /// A short human name, e.g. "Invoices". Labels the rule everywhere it appears.
    public var name: String
    /// A disabled rule is kept (so the user's work isn't lost) but skipped by the preview.
    public var enabled: Bool
    /// Whether every condition must hold (`all`) or just one (`any`).
    public var matchMode: MatchMode
    public var conditions: [AutomationCondition]
    /// Provider-relative destination folder, may contain tokens (see ``AutomationEvaluator``).
    public var destinationTemplate: String
    /// The folder survey's root the destination is relative to, for a rule taught by a correction
    /// in Ask Claude: such a rule acts only in that tree and is inert elsewhere, as an absolute rule
    /// is outside its own. Nil (older and hand-made rules) resolves against whichever tree is
    /// scanned.
    public var surveyRoot: String?

    /// Top-level keys this build has no case for, kept verbatim so a round-trip doesn't silently drop
    /// the user's data. A rule carrying one still runs: everything this build needs is understood.
    private var unknownFields: [String: JSONFragment]
    /// Keys this build knows but whose value it couldn't read, such as a newer build's `matchMode`.
    /// The value is written back in place of the substituted default, so opening the file here
    /// doesn't destroy what a newer build wrote. And the rule is never ``isRunnable``: the missing
    /// part is what says which files it claims.
    private var unreadableFields: [String: JSONFragment]

    public enum MatchMode: String, Codable, Sendable, CaseIterable, Identifiable {
        case all, any
        public var id: String { rawValue }
        /// The connector shown between conditions, e.g. "all of" / "any of".
        public var label: String { self == .all ? "all of" : "any of" }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        matchMode: MatchMode = .all,
        conditions: [AutomationCondition] = [],
        destinationTemplate: String = "",
        surveyRoot: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matchMode = matchMode
        self.conditions = conditions
        self.destinationTemplate = destinationTemplate
        self.surveyRoot = surveyRoot
        self.unknownFields = [:]
        self.unreadableFields = [:]
    }

    /// A rule is runnable only with a name, a destination, and conditions the evaluator can satisfy:
    /// ANY-OF needs one complete condition, ALL-OF needs every one. An all-of rule with a half-built
    /// row matches nothing, so it must read as incomplete everywhere (pill, preview, count).
    ///
    /// A rule carrying a value this build could not read is never runnable — see
    /// ``unreadableFields``.
    public var isRunnable: Bool {
        guard unreadableFields.isEmpty else { return false }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !destinationTemplate.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch matchMode {
        case .all: return !conditions.isEmpty && conditions.allSatisfy { $0.isComplete }
        case .any: return conditions.contains { $0.isComplete }
        }
    }

    /// True when the rule carries a value written by a build that knows more than this one. Such a
    /// rule is never ``isRunnable``, and this tells it apart from a half-built rule, so the user
    /// isn't told to add a condition and destination it already has.
    public var hasUnreadableValues: Bool { !unreadableFields.isEmpty }

    /// True when any complete condition reads file text (the preview then fetches a snippet), or the
    /// destination is named from page 1 (`{travel-month}`).
    public var requiresContent: Bool {
        conditions.contains { $0.requiresContent && $0.isComplete } || destinationReadsContent
    }

    /// The destination is named from page 1, so a file the rule matches by name alone still needs
    /// its text read to know where it goes.
    public var destinationReadsContent: Bool { AutomationTravelDate.isUsed(in: destinationTemplate) }

    /// Whether the rule may act in a scan of `providerRoot`: a rule taught for one survey's tree
    /// (``surveyRoot``) acts only there, in either spelling of a link on the way.
    public func acts(in providerRoot: String) -> Bool {
        surveyRoot.map { SourceSurveyStore.sameFolder($0, providerRoot) } ?? true
    }

    /// A one-line plain-words summary, e.g. "PDF · text contains “invoice” → Documents/Invoices/{year}".
    public var summary: String {
        let parts = conditions.filter { $0.isComplete }.map { $0.summary }
        let lhs: String
        if parts.isEmpty {
            lhs = "any file"
        } else if parts.count == 1 {
            lhs = parts[0]
        } else {
            lhs = "\(matchMode.label): " + parts.joined(separator: " · ")
        }
        let dest = destinationTemplate.isEmpty ? "…" : destinationTemplate
        return "\(lhs) → \(dest)"
    }
}

// MARK: - Persistence that survives a version it does not know

/// The rules are persisted as one JSON blob under one key, so a single value this build can't
/// read would fail the whole array decode, and the next save would write the empty set over every
/// rule. (`FileSyncManager.decodePersistedStore` keeps undecodable bytes under a sibling key, but
/// nothing offers them back.) So this decoder loses at most the one value it can't read:
///
/// - A key this build doesn't know is kept verbatim and written back on the next save.
/// - A key it expects but doesn't find falls back to the initializer's default, as
///   ``PaneTabsStore/Entry`` does.
/// - A `matchMode` it can't evaluate is preserved and the rule made inert: guessing `all` or `any`
///   would file by a rule the user never wrote.
///
/// There is deliberately no `schemaVersion`: the per-field tolerance and
/// ``AutomationRule/isRunnable`` already do what one would, and a future build can add the key and
/// this one will carry it through untouched.
extension AutomationRule {

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, enabled, matchMode, conditions, destinationTemplate, surveyRoot
    }

    /// A key made from a string at runtime — needed to reach the keys this build has no case for.
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ key: CodingKeys) { self.stringValue = key.stringValue }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var unreadable: [String: JSONFragment] = [:]

        /// One known field. Absent takes the initializer's default; present but unreadable is
        /// carried verbatim, or the next save would write the default over the real value. Nothing
        /// here throws, so the array decode can't fail on one rule's bad field.
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            let anyKey = AnyKey(key)
            guard c.contains(anyKey) else { return nil }
            if let decoded = try? c.decode(type, forKey: anyKey) { return decoded }
            if let raw = try? c.decode(JSONFragment.self, forKey: anyKey) {
                unreadable[key.stringValue] = raw
            }
            return nil
        }
        id = value(UUID.self, .id) ?? UUID()
        name = value(String.self, .name) ?? ""
        enabled = value(Bool.self, .enabled) ?? true
        matchMode = value(MatchMode.self, .matchMode) ?? .all
        conditions = value([AutomationCondition].self, .conditions) ?? []
        destinationTemplate = value(String.self, .destinationTemplate) ?? ""
        surveyRoot = value(String.self, .surveyRoot)
        unreadableFields = unreadable

        let known = Set(CodingKeys.allCases.map(\.stringValue))
        var carried: [String: JSONFragment] = [:]
        for key in c.allKeys where !known.contains(key.stringValue) {
            if let fragment = try? c.decode(JSONFragment.self, forKey: key) {
                carried[key.stringValue] = fragment
            }
        }
        unknownFields = carried
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        // Keys this build has no case for. They cannot collide with a known one by construction,
        // and writing them first means that if that ever stopped being true the real value wins.
        for (name, fragment) in unknownFields.sorted(by: { $0.key < $1.key }) {
            try c.encode(fragment, forKey: AnyKey(name))
        }
        try c.encode(id, forKey: AnyKey(.id))
        try c.encode(name, forKey: AnyKey(.name))
        try c.encode(enabled, forKey: AnyKey(.enabled))
        try c.encode(matchMode, forKey: AnyKey(.matchMode))
        try c.encode(conditions, forKey: AnyKey(.conditions))
        try c.encode(destinationTemplate, forKey: AnyKey(.destinationTemplate))
        // Only when set, so a rule without one writes the bytes it always did.
        if let surveyRoot { try c.encode(surveyRoot, forKey: AnyKey(.surveyRoot)) }
        // Last, so these overwrite the defaults substituted above: a field this build couldn't read
        // goes back to disk as it came off it.
        for (name, fragment) in unreadableFields.sorted(by: { $0.key < $1.key }) {
            try c.encode(fragment, forKey: AnyKey(name))
        }
    }
}

/// The smallest JSON value model that can hold anything this build doesn't recognise: a future
/// condition's payload (``AutomationCondition/unrecognized``) or a rule field it has no case for.
/// A value, not raw `Data`, because it sits inside a `Codable`, `Hashable` struct and is written
/// back through the caller's encoder.
public indirect enum JSONFragment: Codable, Equatable, Hashable, Sendable {
    case null, bool(Bool), integer(Int), unsignedInteger(UInt64), number(Double), string(String)
    case array([JSONFragment]), object([String: JSONFragment])

    /// `integer` is tried before `number`: as `Double`, any integer past 2^53 is silently rewritten
    /// (`9007199254740993` becomes `…992`), and a nanosecond timestamp reaches that range. `7` stays
    /// `7`, not `7.0`, and `true` decodes as a Bool, not 1.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .integer(v) }
        // Above `Int64.max` and still integral (a 20-digit id, a `UInt64` hash): `Double` would
        // rewrite it. Beyond `UInt64.max` it still degrades to `Double`; keeping it exact would
        // need the source token, which `Codable` doesn't provide.
        else if let v = try? c.decode(UInt64.self) { self = .unsignedInteger(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONFragment].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONFragment].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .unsignedInteger(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
