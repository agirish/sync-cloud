import Foundation
import UniformTypeIdentifiers

/// N2 Automations — the rule model. An automation is a small, readable sentence a user authors
/// once (or teaches by example): *when a loose file matches these on-device conditions, it belongs
/// in this folder.* A rule acts in two places: it steers the Organize scan's suggestions, and the
/// Automations lens dry-runs it over a folder and then files the matches you confirm — nothing
/// ever moves without that confirmation. Every condition is answered by a local signal (path,
/// filename glob, UTType, file size, modification date, or on-device text) so a rule is
/// deterministic, private, and free — no Claude Cloud classifier is ever consulted on the
/// automation path.

// MARK: - File kind

/// A coarse file family a rule can match, derived purely from the file's extension via `UTType`
/// (offline, deterministic). Deliberately coarse — the palette offers "kind is an image", not a
/// long UTI list — because that is what a person reasons about.
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
        // `.movie` only — deliberately NOT `.audiovisualContent`, which `public.audio` also conforms
        // to, so an mp3/m4a would otherwise classify as video (and `.of` checks video before audio).
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

    /// Whether a file with the given extension is of this kind. Extension-driven so it stays pure
    /// (no disk access) and works even for evicted cloud files whose bytes aren't local.
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

/// One on-device test a rule can apply to a file. Combined with ``AutomationRule/MatchMode``
/// (all/any). Every case is answerable locally; ``requiresContent`` marks the one case that needs
/// the file's text read (PDFKit / Vision OCR / plain text), so the evaluator only pays that cost
/// when a rule actually asks for it.
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
    /// The file *mentions* every one of these canonical tokens — in its name or its on-device text.
    /// This is the learned-by-example condition remembered filing rules (F3) migrated into: tokens
    /// are produced by ``FilingEngine/nameTokens(_:)`` (lowercased, stopwords dropped) and matching
    /// is a subset test against the file's name ∪ content tokens, exactly as F3 matched.
    case mentionsAll([String])
    /// The document is **about this person** — the household member whose registry id this is.
    ///
    /// Keyed on the id rather than on a name, deliberately: `Person.id` survives a rename and the
    /// addition of a name variant, so a rule taught today keeps working when "Shweta Ravindra Dani"
    /// is added to her record tomorrow. A word-based rule cannot — and could not be written safely
    /// in the first place, since `abhishek` is one person's given name and three others' surname.
    case personIs(String)
    /// A condition written by a **newer build** of the app, preserved verbatim.
    ///
    /// **Not a real condition — a survival mechanism.** Rules are persisted as one JSON blob, and
    /// the synthesized enum decoder throws on an unknown case name, which took the *whole array*
    /// with it: every rule vanished from the UI and the next edit wrote the empty set back over
    /// them. Keeping the raw payload means an unknown condition round-trips through this build
    /// untouched, and `isComplete` being false means it never silently matches anything.
    case unrecognized(name: String, payload: Data)

    /// True for conditions that may need the file's text extracted. Used to defer the expensive
    /// read. `mentionsAll` counts: a token can be satisfied by content when the name alone misses.
    ///
    /// **Written out case by case, with no `default:`, deliberately.** This value is what gates
    /// building the snippet extractor at all, so a content-reading condition that answers `false`
    /// here is never given any text to read: the rule shows a green "runnable" pill and then
    /// matches no file, ever — no error, no log line. A `default:` makes that the automatic fate of
    /// the next case anyone adds. Its sibling ``AutomationEvaluator/matches(_:_:now:)`` is
    /// exhaustive for the same reason, and that is exactly why a new case gets *answered* there and
    /// silently mis-answered here. Adding a case must break the build; leave this switch total.
    ///
    /// **`personIs` deliberately does NOT**, and that is a judgement rather than an oversight: a
    /// document that is about someone almost always says so in its name, and making every person
    /// rule force a text extraction over a whole inbox would spend seconds per scan to catch the
    /// minority case. Content still counts where it has already been read — see
    /// ``PersonRegistry/attribute(fileName:pageSample:)``.
    ///
    /// **`unrecognized` answers `false`, and cannot be wrong either way**: it is never
    /// ``isComplete``, and ``AutomationRule/requiresContent`` only asks complete conditions, so a
    /// condition from a newer build never reaches this question in production.
    public var requiresContent: Bool {
        switch self {
        case .contentContains, .mentionsAll: return true
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
        case .personIs(let id):
            // The id, not a display name: this type has no roster to look one up in, and a
            // summary that guessed would go stale the moment a person was renamed. The editor and
            // the rule list substitute the name they know — see `summary(resolvingPeople:)`.
            return "is \(id.isEmpty ? "…" : id)'s document"
        case .unrecognized(let name, _):
            return "\(name) (from a newer version)"
        }
    }

    /// The same sentence with person ids replaced by the names on the roster — "is Aditi's
    /// document". Falls back to the id when the roster does not know them, which is what a rule
    /// pointing at a deleted person should look like: visible, not silently blank.
    public func summary(resolvingPeople registry: PersonRegistry?) -> String {
        guard case .personIs(let id) = self, let registry else { return summary }
        guard let person = registry.people.first(where: { $0.id == id }) else {
            return "is \(id)'s document (not on your People list)"
        }
        return "is \(person.displayName)'s document"
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
        case .personIs(let id): return !id.trimmingCharacters(in: .whitespaces).isEmpty
        // Never complete, so a rule carrying one can be seen and edited but can never quietly
        // match a file on a condition this build does not understand.
        case .unrecognized: return false
        }
    }

    /// A stable key for the condition's *type* (not its value) — lets the editor offer a type
    /// picker and swap the associated value while keeping the row.
    public var kindKey: String {
        switch self {
        case .folderNamed: return "folderNamed"
        case .nameMatches: return "nameMatches"
        case .kindIs: return "kindIs"
        case .largerThanMB: return "largerThanMB"
        case .untouchedForDays: return "untouchedForDays"
        case .contentContains: return "contentContains"
        case .mentionsAll: return "mentionsAll"
        case .personIs: return "personIs"
        case .unrecognized(let name, _): return name
        }
    }
}

// MARK: - Persistence that survives a version it does not know

extension AutomationCondition {
    /// The wire shape is **exactly what Swift synthesized before this existed** — a single-key
    /// object whose key is the case name and whose value is `{"_0": <payload>}`. Written by hand
    /// only so that decoding an unknown key can be survivable; every byte an older build wrote
    /// still decodes here, and every byte this writes still decodes there.
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
        let payload = try c.nestedContainer(keyedBy: PayloadKey.self, forKey: key)
        switch key.stringValue {
        case "folderNamed": self = .folderNamed(try payload.decode(String.self, forKey: ._0))
        case "nameMatches": self = .nameMatches(try payload.decode(String.self, forKey: ._0))
        case "kindIs": self = .kindIs(try payload.decode(FileKind.self, forKey: ._0))
        case "largerThanMB": self = .largerThanMB(try payload.decode(Int.self, forKey: ._0))
        case "untouchedForDays": self = .untouchedForDays(try payload.decode(Int.self, forKey: ._0))
        case "contentContains": self = .contentContains(try payload.decode(String.self, forKey: ._0))
        case "mentionsAll": self = .mentionsAll(try payload.decode([String].self, forKey: ._0))
        case "personIs": self = .personIs(try payload.decode(String.self, forKey: ._0))
        default:
            // Kept as bytes so it can be written back untouched. Decoding it as `JSONValue` would
            // mean re-encoding through this build's idea of the shape; the raw data cannot drift.
            let raw = try c.decode(RawPayload.self, forKey: key)
            self = .unrecognized(name: key.stringValue, payload: raw.data)
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
        case .personIs(let v): try write(v, "personIs")
        case .unrecognized(let name, let payload):
            try c.encode(RawPayload(data: payload), forKey: AnyKey(stringValue: name))
        }
    }

    /// Carries an arbitrary JSON value through decode and encode without interpreting it.
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

    /// The smallest JSON value model that can hold anything a future case's payload might be.
    private indirect enum JSONFragment: Codable {
        case null, bool(Bool), number(Double), string(String)
        case array([JSONFragment]), object([String: JSONFragment])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSONFragment].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSONFragment].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }
}

// MARK: - Rule

/// A single automation. `destinationTemplate` is **provider-relative** (e.g.
/// `Documents/Invoices/{year}`) — resolved against whichever provider root the preview runs over —
/// so a rule is portable across providers rather than pinned to one absolute path (unlike
/// ``FilingRule``, which stores an absolute, provider-scoped destination).
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

    /// Top-level keys this build has **no case for**, kept verbatim so a round-trip through it is
    /// not a silent downgrade of the user's data. Harmless: a rule carrying one still runs, because
    /// everything this build needs in order to evaluate it is present and understood.
    private var unknownFields: [String: JSONFragment]
    /// Keys this build **does** know but whose value it could not read — a `matchMode` a newer build
    /// added, a `conditions` array holding something this build has no case for.
    ///
    /// Two things follow, and both matter. The value is kept exactly as it arrived and written back
    /// in place of the default that was substituted, so opening the file here does not destroy what
    /// a newer build wrote. And the rule is never ``isRunnable``: a rule whose meaning is only
    /// partly known must not act, because the part that is missing is precisely the part that says
    /// which files it claims.
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
        destinationTemplate: String = ""
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.matchMode = matchMode
        self.conditions = conditions
        self.destinationTemplate = destinationTemplate
        self.unknownFields = [:]
        self.unreadableFields = [:]
    }

    /// A rule is runnable only when it has a name, a destination, and conditions the
    /// evaluator can actually satisfy: ANY-OF needs at least one complete condition; ALL-OF
    /// needs EVERY condition complete — matches() proves "all" over nothing less, so an
    /// all-of rule with a half-built row is inert and must read as incomplete everywhere
    /// (card pill, preview gating, runnable count) rather than promising its complete half.
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

    /// True when any (complete) condition reads file text — the preview then fetches a snippet.
    public var requiresContent: Bool {
        conditions.contains { $0.requiresContent && $0.isComplete }
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

/// The rules are persisted as **one JSON blob under one key**, which is what makes every question
/// here all-or-nothing: a single value this build cannot read throws out of the array decode, every
/// rule disappears from the UI, and the next rule the user creates writes the empty set back over
/// them. `FileSyncManager.readPersistedStore` keeps the undecodable bytes under a sibling key, but
/// that is a floor — nothing in the app offers them back.
///
/// So this decoder is written to lose at most the one value it cannot read:
///
/// - **A key this build does not know is kept verbatim** and written back on the next save. Editing
///   a rule in an older build is then not a silent downgrade of data a newer one wrote.
/// - **A key this build expects but does not find falls back** to the initializer's own default,
///   rather than taking the array with it — the shape ``FilingRule`` and ``PaneTabsStore/Entry``
///   already use, and for the same reason.
/// - **A `matchMode` this build cannot evaluate is preserved and the rule made inert.** Guessing
///   `all` or `any` would file the user's files by a rule they never wrote.
///
/// **There is deliberately no `schemaVersion`,** which is the one thing this store is missing that
/// its seven siblings have. A version number is only worth what the code does with it, and the two
/// useful jobs are already covered: telling a shape apart is what the tolerance above does per
/// field, and refusing to act on a shape this build does not understand is what
/// ``AutomationRule/isRunnable`` does per rule. Stamping a number that nothing reads is the pattern
/// `PersonTag` was faulted for. Should a future build want one, it can add the key and this build
/// will carry it through untouched — which is precisely the point of the unknown-field bag.
extension AutomationRule {

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, enabled, matchMode, conditions, destinationTemplate
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

        /// One known field. Absent is not the same as unreadable, and the difference is the whole
        /// design: an absent key takes the initializer's own default and costs nothing, while a key
        /// that is THERE and cannot be read is carried verbatim — otherwise this build substitutes
        /// a default, the next save writes that default over the real value, and the user's rule is
        /// quietly destroyed by a build that only opened it. Nothing here throws, which is the
        /// property that matters: the array decode can no longer fail on one rule's one bad field.
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
        // LAST, deliberately: these overwrite the defaults substituted above, so what goes back to
        // disk for a field this build could not read is what came off it.
        for (name, fragment) in unreadableFields.sorted(by: { $0.key < $1.key }) {
            try c.encode(fragment, forKey: AnyKey(name))
        }
    }
}

/// The smallest JSON value model that can hold anything a field this build does not know might be.
/// Kept as a value rather than as raw `Data` because it has to sit inside a `Codable`, `Hashable`
/// struct and be written back through whatever encoder the caller is using.
indirect enum JSONFragment: Codable, Equatable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONFragment]), object([String: JSONFragment])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONFragment].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONFragment].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
