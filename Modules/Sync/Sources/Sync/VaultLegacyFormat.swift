import Foundation

/// The v1 files, read for the migration to the v7.2 document (``VaultMigration``) and kept
/// readable for good: old backups and the committed format files are in them.
///
/// - `vault.sealed` under `SCVAULT1`: a JSON array of entries.
/// - `vault-reading.sealed` under `SCVREAD1`: one ``VaultReadingState``.
///
/// Read strictly, unlike the everyday load (``VaultFile/openRecords(_:with:)``), which keeps what it
/// cannot read aside: the migration converts only what it reads in full. An element that does not
/// decode, or holds a key at any depth that reading drops, is counted and refuses the whole.
///
/// The entries are read through a shape of their own (``Entry``), every key any build stored
/// included: ``VaultEntry`` holds only what an entry means, and is not stored as itself.
enum VaultLegacyFormat {
    static let vaultMarker = Data("SCVAULT1".utf8)
    static let readingMarker = Data("SCVREAD1".utf8)

    /// Why v1 JSON was not taken: counts only.
    struct Refused: Error, Equatable {
        /// Elements that did not decode.
        var undecodable = 0
        /// Keys, at any depth, that decoding dropped or changed.
        var unexpected = 0
        /// The JSON was not the shape at all (not a list, not an object).
        var notTheShape = false
    }

    /// Every entry in a v1 Vault's JSON, as this build holds it (``Entry/entry``).
    static func entries(fromPlain plain: Data) throws -> [VaultEntry] {
        guard let list = try? JSONSerialization.jsonObject(with: plain) as? [Any] else { throw Refused(notTheShape: true) }
        let decoder = VaultFile.jsonDecoder(), encoder = VaultFile.jsonEncoder()
        var refused = Refused()
        var entries: [VaultEntry] = []
        for element in list {
            guard let json = try? JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed]),
                  let legacy = try? decoder.decode(Entry.self, from: json) else {
                refused.undecodable += 1
                continue
            }
            guard let again = try? JSONSerialization.jsonObject(with: encoder.encode(legacy)) else {
                refused.undecodable += 1
                continue
            }
            refused.unexpected += differences(stored: element, read: again)
            entries.append(legacy.entry)
        }
        guard refused == Refused() else { throw refused }
        return entries
    }

    /// The v1 reading file's state. Its own decoding is lenient (a field it cannot read is left
    /// empty), so anything that leniency dropped is counted here as unexpected.
    static func readingState(fromPlain plain: Data) throws -> VaultReadingState {
        guard let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw Refused(notTheShape: true)
        }
        guard let state = try? VaultFile.jsonDecoder().decode(VaultReadingState.self, from: plain),
              let again = try? JSONSerialization.jsonObject(with: VaultFile.jsonEncoder().encode(state)) else {
            throw Refused(undecodable: 1)
        }
        let unexpected = differences(stored: object, read: again)
        guard unexpected == 0 else { throw Refused(unexpected: unexpected) }
        return state
    }

    /// How many keys of `stored`, at any depth, are missing from `read` or hold another value
    /// there. `read` is what decoding `stored` and encoding it again gave: it may hold more (a
    /// field an older build did not write, now written empty), never less. A stored null is no
    /// key: decoding takes it as absent.
    static func differences(stored: Any, read: Any) -> Int {
        switch (stored, read) {
        case (let stored as [String: Any], let read as [String: Any]):
            return stored.reduce(0) { count, pair in
                guard !(pair.value is NSNull) else { return count }
                guard let value = read[pair.key] else { return count + 1 }
                return count + differences(stored: pair.value, read: value)
            }
        case (let stored as [Any], let read as [Any]):
            return zip(stored, read).reduce(abs(stored.count - read.count)) { $0 + differences(stored: $1.0, read: $1.1) }
        case (let stored as NSObject, let read as NSObject):
            return stored.isEqual(read) ? 0 : 1
        default:
            return 1
        }
    }
}

extension VaultLegacyFormat {
    /// One entry as any v1 build stored it: every key, the retired ones (`older`, `dated`, a bare
    /// `kind`, `household` beside a person) included. Encoded again exactly as decoded, so
    /// ``differences(stored:read:)`` sees only what decoding lost.
    ///
    /// Also how this build writes a v1 file while the migration is gated off
    /// (``VaultFile/seal(_:with:)``, a v1 passphrase backup): ``init(_:)`` gives an entry the
    /// keys every v1 build reads, `kind` and the document's date among them.
    struct Entry: Codable {
        /// What a v1 entry belonged to, before categories: it grouped the list.
        enum Kind: String, Codable {
            case identity, health, phone, home, money, other

            /// The kind a number of `category` is stored as, for a v1 build that groups by kind.
            init(_ category: VaultCategory) {
                switch category {
                case .passport, .usVisa, .i94, .uscisCase, .driversLicense, .ssn, .pan, .aadhaar, .voterID: self = .identity
                case .health: self = .health
                case .utilities: self = .phone
                case .loans: self = .home
                case .other: self = .other
                }
            }

            /// The card a number stored before categories goes on, by its kind. "Identity and
            /// Travel" covered several cards, so its title decides which.
            func category(title: String) -> VaultCategory {
                switch self {
                case .identity:
                    let name = title.lowercased()
                    if name.contains("passport") { return .passport }
                    if name.contains("visa") { return .usVisa }
                    if name.contains("i-94") || name.contains("i94") { return .i94 }
                    if name.contains("receipt") || name.contains("uscis") { return .uscisCase }
                    if name.contains("licen") { return .driversLicense }
                    if name.contains("social security") || name.contains("ssn") || name.contains("itin") { return .ssn }
                    if name.contains("aadha") { return .aadhaar }
                    if name.contains("voter") || name.contains("epic") { return .voterID }
                    if name.range(of: #"\bpan\b"#, options: .regularExpression) != nil || name.contains("permanent account") { return .pan }
                    return .other
                case .health: return .health
                case .phone: return .utilities
                case .home, .money: return .loans
                case .other: return .other
                }
            }
        }

        var id: UUID
        var title: String
        var value: String
        var personID: String?
        var note: String
        var kind: Kind
        var sourcePath: String?
        var addedAt: Date
        var updatedAt: Date
        var dated: Date?
        var older: Bool?
        var category: VaultCategory?
        var facts: VaultReadFacts?
        var pin: VaultPin?
        var household: Bool?
        var geo: VaultGeo?
        var card: VaultCardID?
        var holderName: String?
        var chosenSource: String?
        var readAs: [VaultReadAs]?
        var notOn: [String]?
        var fields: [VaultDetail]?
        var notFields: [String]?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, title, value, personID, note, kind, sourcePath, addedAt, updatedAt, dated, older, category, facts, pin
            case household, geo, card, holderName, chosenSource, readAs, notOn, fields, notFields
        }

        /// Every key a v1 entry was stored with. A key outside it is a later build's, kept as it
        /// came (``VaultRecords/laterFields``).
        static let storedKeys = Set(CodingKeys.allCases.map(\.stringValue))

        /// `entry` as a v1 build stores it: its kind its category's, the document's date its
        /// facts', whose it is as ``VaultEntry/assignment`` keeps it.
        init(_ entry: VaultEntry) {
            id = entry.id
            title = entry.title
            value = entry.value
            personID = entry.personID
            note = entry.note
            kind = Kind(entry.category)
            sourcePath = entry.savedFrom
            addedAt = entry.addedAt
            updatedAt = entry.updatedAt
            dated = entry.facts?.dated
            category = entry.category
            facts = entry.facts
            pin = entry.pin
            household = entry.household
            geo = entry.geo
            card = entry.card
            holderName = entry.holderName
            chosenSource = entry.chosenSource
            readAs = entry.readAs
            notOn = entry.notOn
            fields = entry.fields
            notFields = entry.notFields
        }

        /// What it meant: its category the facts' or the one chosen, else its kind's; an old pin
        /// from `older` when no pin was chosen; whose from `household` before the person; the
        /// document's date dropped (the facts hold it).
        var entry: VaultEntry {
            var entry = VaultEntry(id: id, title: title, value: value, note: note, savedFrom: sourcePath,
                                   addedAt: addedAt, updatedAt: updatedAt,
                                   category: category ?? kind.category(title: title), facts: facts)
            entry.assignment = household == true ? .household : personID.map { .person($0) }
            entry.pin = pin ?? (older == true ? .older : nil)
            entry.geo = geo
            entry.card = card
            entry.holderName = holderName
            entry.chosenSource = chosenSource
            entry.readAs = readAs
            entry.notOn = notOn
            entry.fields = fields
            entry.notFields = notFields
            return entry
        }
    }
}
