import Foundation

/// One number as the v7.2 document stores it (``VaultDocument``): a saved ID or one waiting in To
/// Confirm, in one shape (VT1's stored shape). In memory the Vault still works with
/// ``VaultEntry`` and ``VaultFind``; a record is what they become as the document is sealed, and
/// what they are made from again as it opens. Both conversions are lossless: an entry or a find
/// made into a record and back is `==` to what it was.
///
/// Like an entry it never prints its number.
public struct VaultRecord: Codable, Equatable, Sendable, Identifiable {
    /// Saved in the Vault, or read and waiting in To Confirm.
    public enum State: String, Codable, Sendable { case saved, toConfirm }

    /// One line of the record: its number (``isMain``), a detail read off its document, or a field
    /// added by hand.
    public struct Field: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case number, secret, text, date, phone, address }
        /// Typed by the user, or read off a document.
        public enum From: String, Codable, Sendable { case typed, read }
        /// What it holds: text, or a calendar day.
        public enum Value: Codable, Equatable, Sendable {
            case text(String)
            case date(Date)

            private enum CodingKeys: String, CodingKey, CaseIterable { case text, date }

            public init(from decoder: Decoder) throws {
                try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
                let c = try decoder.container(keyedBy: CodingKeys.self)
                switch (c.contains(.text), c.contains(.date)) {
                case (true, false): self = .text(try c.decode(String.self, forKey: .text))
                case (false, true): self = .date(try c.decode(Date.self, forKey: .date))
                default:
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                            debugDescription: "a field’s value is neither text nor a date"))
                }
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let text): try c.encode(text, forKey: .text)
                case .date(let date): try c.encode(date, forKey: .date)
                }
            }
        }

        public var label: String
        public var kind: Kind
        public var value: Value
        /// The record's number. Exactly one field of a record is.
        public var isMain: Bool
        /// Its ending is a secret too while it is hidden (``VaultCategory/hidesEnding``).
        public var hidesEnding: Bool
        public var from: From

        public init(label: String, kind: Kind, value: Value, isMain: Bool = false, hidesEnding: Bool = false, from: From) {
            self.label = label
            self.kind = kind
            self.value = value
            self.isMain = isMain
            self.hidesEnding = hidesEnding
            self.from = from
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case label, kind, value, isMain, hidesEnding, from }

        public init(from decoder: Decoder) throws {
            try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            kind = try c.decode(Kind.self, forKey: .kind)
            value = try c.decode(Value.self, forKey: .value)
            isMain = try c.decode(Bool.self, forKey: .isMain)
            hidesEnding = try c.decode(Bool.self, forKey: .hidesEnding)
            from = try c.decode(From.self, forKey: .from)
        }

        /// What the main field's label is. Never read back: the main field is found by ``isMain``.
        static let mainLabel = "Number"

        /// A record's number.
        static func main(_ value: String, category: VaultCategory, from: From) -> Field {
            Field(label: mainLabel, kind: .number, value: .text(value), isMain: true,
                  hidesEnding: category.hidesEnding, from: from)
        }

        /// A detail beside the number: text, a date, or a number in its own right.
        init(_ detail: VaultDetail, from: From) {
            switch detail.value {
            case .text(let text): self.init(label: detail.label, kind: .text, value: .text(text), from: from)
            case .date(let date): self.init(label: detail.label, kind: .date, value: .date(date), from: from)
            case .number(let number): self.init(label: detail.label, kind: .number, value: .text(number), from: from)
            }
        }

        /// The detail this field is. A kind this build never writes reads as the nearest it has:
        /// a secret as a number, a phone or an address as text.
        func detail() throws -> VaultDetail {
            switch (kind, value) {
            case (.text, .text(let text)), (.phone, .text(let text)), (.address, .text(let text)):
                return VaultDetail(label, .text(text))
            case (.number, .text(let number)), (.secret, .text(let number)):
                return VaultDetail(label, .number(number))
            case (.date, .date(let date)):
                return VaultDetail(label, .date(date))
            default:
                throw VaultRecordError.fieldValue
            }
        }
    }

    /// Whose it is, as the user said: a person in People, or the household. Absent goes by the
    /// name the document was read with.
    public enum Owner: Codable, Equatable, Sendable {
        case person(String)
        case household

        private enum CodingKeys: String, CodingKey, CaseIterable { case person, household }

        public init(from decoder: Decoder) throws {
            try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch (c.contains(.person), c.contains(.household)) {
            case (true, false): self = .person(try c.decode(String.self, forKey: .person))
            case (false, true):
                try VaultStrictKeys.checkEmpty(c.superDecoder(forKey: .household))
                self = .household
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "an owner is neither a person nor the household"))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .person(let id): try c.encode(id, forKey: .person)
            case .household: try c.encode(VaultEmpty(), forKey: .household)
            }
        }

        init?(_ assignment: VaultAssignment?) {
            switch assignment {
            case .person(let id)?: self = .person(id)
            case .household?: self = .household
            case nil: return nil
            }
        }

        var assignment: VaultAssignment {
            switch self {
            case .person(let id): return .person(id)
            case .household: return .household
            }
        }
    }

    /// Where the number came from: typed in, or read off a document.
    public enum Origin: Codable, Equatable, Sendable {
        case typed
        /// `savedFrom`: the document a saved ID was saved from, which can differ from what its
        /// facts now put first; nil for a waiting one, and for a saved one stored without it.
        /// `facts`: what was read, with no ``VaultReadFacts/details``: those are the record's
        /// fields read off its documents.
        case read(savedFrom: String?, facts: VaultReadFacts?)

        private enum CodingKeys: String, CodingKey, CaseIterable { case typed, read }
        private enum ReadKeys: String, CodingKey, CaseIterable { case savedFrom, facts }

        public init(from decoder: Decoder) throws {
            try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch (c.contains(.typed), c.contains(.read)) {
            case (true, false):
                try VaultStrictKeys.checkEmpty(c.superDecoder(forKey: .typed))
                self = .typed
            case (false, true):
                let inner = try c.superDecoder(forKey: .read)
                try VaultStrictKeys.check(inner, known: Set(ReadKeys.allCases.map(\.stringValue)))
                let read = try inner.container(keyedBy: ReadKeys.self)
                self = .read(savedFrom: try read.decodeIfPresent(String.self, forKey: .savedFrom),
                             facts: try read.decodeIfPresent(VaultReadFacts.self, forKey: .facts))
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "an origin is neither typed nor read"))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .typed: try c.encode(VaultEmpty(), forKey: .typed)
            case .read(let savedFrom, let facts):
                var read = c.nestedContainer(keyedBy: ReadKeys.self, forKey: .read)
                try read.encodeIfPresent(savedFrom, forKey: .savedFrom)
                try read.encodeIfPresent(facts, forKey: .facts)
            }
        }
    }

    /// What the user chose about it besides whose it is (that is ``owner``).
    public struct Choices: Codable, Equatable, Sendable {
        public var pin: VaultPin?
        public var geo: VaultGeo?
        public var card: VaultCardID?
        /// The copy it is read from (Read from This Copy), by path.
        public var source: String?

        public init(pin: VaultPin? = nil, geo: VaultGeo? = nil, card: VaultCardID? = nil, source: String? = nil) {
            self.pin = pin
            self.geo = geo
            self.card = card
            self.source = source
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case pin, geo, card, source }

        public init(from decoder: Decoder) throws {
            try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pin = try c.decodeIfPresent(VaultPin.self, forKey: .pin)
            geo = try c.decodeIfPresent(VaultGeo.self, forKey: .geo)
            card = try c.decodeIfPresent(VaultCardID.self, forKey: .card)
            source = try c.decodeIfPresent(String.self, forKey: .source)
        }

        func choices(owner: Owner?) -> VaultChoices {
            VaultChoices(pin: pin, assignment: owner?.assignment, geo: geo, card: card, source: source)
        }
    }

    public var id: UUID
    public var state: State
    public var title: String
    public var category: VaultCategory
    public var note: String
    /// Exactly one ``Field/isMain`` (the number), first; then the details read off its documents,
    /// in order; then the fields added by hand.
    public var fields: [Field]
    public var owner: Owner?
    /// The name on its document as the user corrected it.
    public var holderName: String?
    public var origin: Origin
    public var choices: Choices
    public var readAs: [VaultReadAs]?
    public var notOn: [String]?
    public var notFields: [String]?
    /// Absent for a waiting record.
    public var addedAt: Date?
    public var updatedAt: Date?

    public init(id: UUID, state: State, title: String, category: VaultCategory, note: String, fields: [Field],
                owner: Owner? = nil, holderName: String? = nil, origin: Origin, choices: Choices = Choices(),
                readAs: [VaultReadAs]? = nil, notOn: [String]? = nil, notFields: [String]? = nil,
                addedAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.state = state
        self.title = title
        self.category = category
        self.note = note
        self.fields = fields
        self.owner = owner
        self.holderName = holderName
        self.origin = origin
        self.choices = choices
        self.readAs = readAs
        self.notOn = notOn
        self.notFields = notFields
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, state, title, category, note, fields, owner, holderName, origin, choices, readAs, notOn, notFields, addedAt, updatedAt
    }

    /// Every key a record is stored with.
    static let storedKeys = Set(CodingKeys.allCases.map(\.stringValue))

    public init(from decoder: Decoder) throws {
        try VaultStrictKeys.check(decoder, known: Self.storedKeys)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        state = try c.decode(State.self, forKey: .state)
        title = try c.decode(String.self, forKey: .title)
        category = try c.decode(VaultCategory.self, forKey: .category)
        note = try c.decode(String.self, forKey: .note)
        fields = try c.decode([Field].self, forKey: .fields)
        owner = try c.decodeIfPresent(Owner.self, forKey: .owner)
        holderName = try c.decodeIfPresent(String.self, forKey: .holderName)
        origin = try c.decode(Origin.self, forKey: .origin)
        choices = try c.decode(Choices.self, forKey: .choices)
        readAs = try c.decodeIfPresent([VaultReadAs].self, forKey: .readAs)
        notOn = try c.decodeIfPresent([String].self, forKey: .notOn)
        notFields = try c.decodeIfPresent([String].self, forKey: .notFields)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(state, forKey: .state)
        try c.encode(title, forKey: .title)
        try c.encode(category, forKey: .category)
        try c.encode(note, forKey: .note)
        try c.encode(fields, forKey: .fields)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encodeIfPresent(holderName, forKey: .holderName)
        try c.encode(origin, forKey: .origin)
        try c.encode(choices, forKey: .choices)
        try c.encodeIfPresent(readAs, forKey: .readAs)
        try c.encodeIfPresent(notOn, forKey: .notOn)
        try c.encodeIfPresent(notFields, forKey: .notFields)
        try c.encodeIfPresent(addedAt, forKey: .addedAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    /// The number, from the main field.
    public var value: String? {
        guard case .text(let value)? = fields.first(where: \.isMain)?.value else { return nil }
        return value
    }

    /// The number, the details read and the fields typed, checked for the record's shape.
    func splitFields() throws -> (value: String, read: [VaultDetail], typed: [VaultDetail]) {
        let mains = fields.filter(\.isMain)
        guard mains.count == 1, fields.first?.isMain == true, case .text(let value) = mains[0].value else {
            throw VaultRecordError.mainField
        }
        var read: [VaultDetail] = [], typed: [VaultDetail] = []
        for field in fields.dropFirst() {
            if field.isMain { throw VaultRecordError.mainField }
            switch field.from {
            case .read:
                // Read details come before hand fields.
                guard typed.isEmpty else { throw VaultRecordError.fieldOrder }
                read.append(try field.detail())
            case .typed:
                typed.append(try field.detail())
            }
        }
        return (value, read, typed)
    }
}

/// Why a record is not an entry or a find. Never carries a value.
public enum VaultRecordError: Error, Equatable, Sendable {
    /// Not exactly one main field, first.
    case mainField
    /// A field whose value is not its kind's.
    case fieldValue
    /// A read detail after a field typed by hand.
    case fieldOrder
    /// Read details with no facts to hold them, or on a number typed in.
    case readFieldsWithoutFacts
    /// A saved record without its dates, or one whose facts say another kind.
    case notASavedRecord
    /// A waiting record holding what only a saved one can.
    case notAWaitingRecord
}

/// `{}`: the household owner, a typed origin.
struct VaultEmpty: Codable {
    init() {}
    init(from decoder: Decoder) throws { try VaultStrictKeys.checkEmpty(decoder) }
    func encode(to encoder: Encoder) throws { _ = encoder.container(keyedBy: VaultAnyKey.self) }
}

/// Any key, for reading which keys an object holds.
struct VaultAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension CodingUserInfoKey {
    /// Set to `true` for a document a later build wrote (``VaultDocument/format`` higher than this
    /// build's): keys this build does not know are let pass, as it only reads.
    static let vaultTolerant = CodingUserInfoKey(rawValue: "vaultTolerant")!
}

/// A document of this build's format holds only the keys this build writes: one it does not know
/// means a later build wrote it without raising the format, and it is not read as this build's.
enum VaultStrictKeys {
    static func check(_ decoder: Decoder, known: Set<String>) throws {
        guard decoder.userInfo[.vaultTolerant] as? Bool != true else { return }
        let keys = try decoder.container(keyedBy: VaultAnyKey.self).allKeys
        let unknown = keys.filter { !known.contains($0.stringValue) }.count
        guard unknown == 0 else {
            // A count only: a key's name is the shape, not the contents, but nothing is said that
            // need not be.
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "\(unknown) key(s) this build does not write"))
        }
    }

    static func checkEmpty(_ decoder: Decoder) throws { try check(decoder, known: []) }
}

// MARK: Entries and finds

extension VaultEntry {
    /// The saved ID `record` holds. Throws for a waiting record, or one not in a saved record's
    /// shape.
    public init(record: VaultRecord) throws {
        guard record.state == .saved, let addedAt = record.addedAt, let updatedAt = record.updatedAt else {
            throw VaultRecordError.notASavedRecord
        }
        let (value, read, typed) = try record.splitFields()
        var facts: VaultReadFacts?
        var savedFrom: String?
        switch record.origin {
        case .typed:
            guard read.isEmpty else { throw VaultRecordError.readFieldsWithoutFacts }
        case .read(let from, let readFacts):
            savedFrom = from
            guard readFacts != nil || read.isEmpty else { throw VaultRecordError.readFieldsWithoutFacts }
            facts = readFacts
            facts?.details = read
        }
        // What was read says which kind it is, and the record says the same.
        if let facts, facts.category != record.category { throw VaultRecordError.notASavedRecord }
        self.init(id: record.id, title: record.title, value: value, note: record.note, savedFrom: savedFrom,
                  addedAt: addedAt, updatedAt: updatedAt, category: record.category, facts: facts)
        assignment = record.owner?.assignment
        pin = record.choices.pin
        geo = record.choices.geo
        card = record.choices.card
        chosenSource = record.choices.source
        holderName = record.holderName
        readAs = record.readAs
        notOn = record.notOn
        notFields = record.notFields
        fields = typed.isEmpty ? nil : typed
    }
}

extension VaultRecord {
    /// A saved ID's record. Where it came from: read, from the document it was saved from
    /// (``VaultEntry/savedFrom``) or with facts alone; else typed in.
    public init(_ entry: VaultEntry) {
        let read = entry.savedFrom != nil || entry.facts != nil
        var stripped = entry.facts
        stripped?.details = []
        let from: Field.From = read ? .read : .typed
        self.init(id: entry.id, state: .saved, title: entry.title, category: entry.category, note: entry.note,
                  fields: [Field.main(entry.value, category: entry.category, from: from)]
                      + (entry.facts?.details ?? []).map { Field($0, from: .read) }
                      + (entry.fields ?? []).map { Field($0, from: .typed) },
                  owner: Owner(entry.assignment), holderName: entry.holderName,
                  origin: read ? .read(savedFrom: entry.savedFrom, facts: stripped) : .typed,
                  choices: Choices(pin: entry.pin, geo: entry.geo, card: entry.card, source: entry.chosenSource),
                  readAs: entry.readAs, notOn: entry.notOn, notFields: entry.notFields,
                  addedAt: entry.addedAt, updatedAt: entry.updatedAt)
    }

    /// A waiting ID's record.
    public init(_ find: VaultFind) {
        var stripped = find.facts
        stripped.details = []
        self.init(id: find.id, state: .toConfirm, title: find.title, category: find.facts.category, note: find.note,
                  fields: [Field.main(find.value, category: find.facts.category, from: .read)]
                      + find.facts.details.map { Field($0, from: .read) },
                  owner: Owner(find.assignment), origin: .read(savedFrom: nil, facts: stripped),
                  choices: Choices(pin: find.pin, geo: find.geo, card: find.card, source: find.chosenSource))
    }
}

extension VaultFind {
    /// The waiting ID `record` holds. Throws for a saved record, or one holding what only a saved
    /// one can.
    public init(record: VaultRecord) throws {
        guard record.state == .toConfirm, record.addedAt == nil, record.updatedAt == nil, record.holderName == nil,
              record.readAs == nil, record.notOn == nil, record.notFields == nil,
              case .read(nil, let stored?) = record.origin, stored.category == record.category else {
            throw VaultRecordError.notAWaitingRecord
        }
        let (value, read, typed) = try record.splitFields()
        guard typed.isEmpty else { throw VaultRecordError.notAWaitingRecord }
        var facts = stored
        facts.details = read
        self.init(id: record.id, title: record.title, value: value, note: record.note, facts: facts,
                  choices: record.choices.choices(owner: record.owner))
    }
}

extension VaultRecord: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "VaultRecord(\(state.rawValue), \(title), \(VaultMask.described(value ?? "", as: category)))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
