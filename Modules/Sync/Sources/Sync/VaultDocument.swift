import CryptoKit
import Events
import Foundation

/// The v7.2 Vault file (VT6): every saved ID and every one waiting in To Confirm, and the user's
/// own data beside them, in one sealed document written in one atomic swap. What reading can find
/// again is apart, in ``VaultCache``.
///
/// Sealed as `vault.sealed` under the marker `SCVAULT2`, so a build before it fails to open it
/// (``VaultFile/openPlain(_:marker:with:)``), says the Vault is unreadable, and never writes over it.
///
/// ``format`` says which build's shape it is. This build's: read and written as usual. A higher
/// one, a later build's: read as far as this build can and never written (``VaultDocumentOpened/readOnly``).
public struct VaultDocument: Codable, Equatable, Sendable {
    /// This build's format.
    public static let format = 1
    /// `SCVAULT` and the file's generation: 1 was the array of entries.
    static let marker = Data("SCVAULT2".utf8)

    public var format: Int
    /// The build that sealed it: "7.2 (702)".
    public var savedBy: String
    public var savedAt: Date
    /// The saved records, then those waiting in To Confirm.
    public var records: [VaultRecord]
    public var reading: Reading
    public var setAside: SetAside
    /// Names corrected everywhere, by ``VaultReading/spellingKey(_:)``.
    public var names: [String: String]
    public var nameRoles: [String: VaultNameRoles]
    public var contacts: [String: VaultContacts]
    /// What choosing a kind taught, by folder.
    public var lessons: [String: VaultCardID]
    /// Choices about waiting numbers made under an older build's rules, by number.
    public var choices: [String: VaultChoice]
    /// The household's own kinds.
    public var kinds: [VaultCustomKind]
    /// What the migration from the v1 files consumed, by their bytes' SHA-256: what each later
    /// open checks leftover files against. Nil for a Vault begun as a document.
    public var migratedFrom: MigratedFrom?

    /// What reading rules the waiting records were made under.
    public struct Reading: Codable, Equatable, Sendable {
        /// ``VaultReading/version`` when they were read.
        public var readerVersion: Int
        public var needsReadAgain: Bool
        public var staleSources: [String]

        public init(readerVersion: Int, needsReadAgain: Bool = false, staleSources: [String] = []) {
            self.readerVersion = readerVersion
            self.needsReadAgain = needsReadAgain
            self.staleSources = staleSources
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case readerVersion, needsReadAgain, staleSources }

        public init(from decoder: Decoder) throws {
            try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            readerVersion = try c.decode(Int.self, forKey: .readerVersion)
            needsReadAgain = try c.decode(Bool.self, forKey: .needsReadAgain)
            staleSources = try c.decode([String].self, forKey: .staleSources)
        }
    }

    /// Numbers not to be offered again, as fingerprints under the Vault's key
    /// (``VaultStore/fingerprint(_:makingKey:)``), and the Forget generation.
    public struct SetAside: Codable, Equatable, Sendable {
        /// Raised by every Forget (``VaultSetAside/generation(in:)`` before 7.2).
        public var generation: Int
        /// Which key the fingerprints were made under (``VaultDocument/keyID(for:)``).
        public var keyID: String
        public var fingerprints: [String]

        public init(generation: Int = 0, keyID: String = "", fingerprints: [String] = []) {
            self.generation = generation
            self.keyID = keyID
            self.fingerprints = fingerprints
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case generation, keyID, fingerprints }

        public init(from decoder: Decoder) throws {
            try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            generation = try c.decode(Int.self, forKey: .generation)
            keyID = try c.decode(String.self, forKey: .keyID)
            fingerprints = try c.decode([String].self, forKey: .fingerprints)
        }
    }

    public struct MigratedFrom: Codable, Equatable, Sendable {
        /// The SCVAULT1 file's SHA-256, hex; nil when there was none.
        public var vault: String?
        /// The SCVREAD1 file's SHA-256, hex; nil when there was none.
        public var reading: String?
        /// How many set-aside fingerprints came from UserDefaults.
        public var fingerprints: Int

        public init(vault: String?, reading: String?, fingerprints: Int) {
            self.vault = vault
            self.reading = reading
            self.fingerprints = fingerprints
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case vault, reading, fingerprints }

        public init(from decoder: Decoder) throws {
            try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            vault = try c.decodeIfPresent(String.self, forKey: .vault)
            reading = try c.decodeIfPresent(String.self, forKey: .reading)
            fingerprints = try c.decode(Int.self, forKey: .fingerprints)
        }
    }

    public init(format: Int = VaultDocument.format, savedBy: String = VaultDocument.thisBuild, savedAt: Date,
                records: [VaultRecord] = [], reading: Reading, setAside: SetAside = SetAside(),
                names: [String: String] = [:], nameRoles: [String: VaultNameRoles] = [:],
                contacts: [String: VaultContacts] = [:], lessons: [String: VaultCardID] = [:],
                choices: [String: VaultChoice] = [:], kinds: [VaultCustomKind] = [], migratedFrom: MigratedFrom? = nil) {
        self.format = format
        self.savedBy = savedBy
        self.savedAt = savedAt
        self.records = records
        self.reading = reading
        self.setAside = setAside
        self.names = names
        self.nameRoles = nameRoles
        self.contacts = contacts
        self.lessons = lessons
        self.choices = choices
        self.kinds = kinds
        self.migratedFrom = migratedFrom
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case format, savedBy, savedAt, records, reading, setAside, names, nameRoles, contacts, lessons, choices, kinds
        case migratedFrom
    }

    public init(from decoder: Decoder) throws {
        try VaultStrictKeys.check(decoder, known: Set(CodingKeys.allCases.map(\.stringValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        savedBy = try c.decode(String.self, forKey: .savedBy)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        records = try c.decode([VaultRecord].self, forKey: .records)
        reading = try c.decode(Reading.self, forKey: .reading)
        setAside = try c.decode(SetAside.self, forKey: .setAside)
        names = try c.decode([String: String].self, forKey: .names)
        nameRoles = try c.decode([String: VaultNameRoles].self, forKey: .nameRoles)
        contacts = try c.decode([String: VaultContacts].self, forKey: .contacts)
        lessons = try c.decode([String: VaultCardID].self, forKey: .lessons)
        choices = try c.decode([String: VaultChoice].self, forKey: .choices)
        kinds = try c.decode([VaultCustomKind].self, forKey: .kinds)
        migratedFrom = try c.decodeIfPresent(MigratedFrom.self, forKey: .migratedFrom)
    }

    /// This build, as `savedBy` names it: its version and build number.
    public static var thisBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// The first 16 hex digits of HMAC-SHA256(key, "SyncCloud set-aside key id"): which key the
    /// fingerprints were made under, without the key.
    public static func keyID(for key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("SyncCloud set-aside key id".utf8), using: key)
        return String(mac.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // MARK: Format

    /// What a document's format stamp says to do with it.
    public enum Stamp: Equatable, Sendable {
        /// This build's: read and written.
        case current
        /// A later build's: read as far as this build can, never written.
        case newer(Int)
    }

    /// The format stamp of a document's JSON. Throws for JSON with none, or one below the first.
    static func stamp(of plain: Data) throws -> Stamp {
        guard let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let format = object["format"] as? Int, format >= Self.format else { throw VaultError.unreadableFile }
        return format == Self.format ? .current : .newer(format)
    }

    // MARK: Entries, finds and the reading state

    /// The saved IDs, in order.
    public func entries() throws -> [VaultEntry] {
        try records.filter { $0.state == .saved }.map(VaultEntry.init(record:))
    }

    /// The waiting IDs, in order.
    public func finds() throws -> [VaultFind] {
        try records.filter { $0.state == .toConfirm }.map(VaultFind.init(record:))
    }

    /// The reading state as the v1 reading file would have held it: the waiting IDs and the user's
    /// own data from here, what reading can find again from `cache` when it was made under the
    /// same rules (else nothing: the next read finds it again).
    public func readingState(cache: VaultCache?) throws -> VaultReadingState {
        let cache = cache.flatMap { $0.fits(self) ? $0 : nil }
        return VaultReadingState(
            version: reading.readerVersion, generation: cache?.generation ?? setAside.generation,
            finds: try finds(), read: cache?.read ?? [:], mentions: cache?.mentions ?? [:], copies: cache?.copies ?? [:],
            choices: choices, needsReadAgain: reading.needsReadAgain, lessons: lessons,
            staleSources: reading.staleSources.isEmpty ? nil : reading.staleSources,
            notFound: cache?.notFound, needsDiscover: cache?.needsDiscover, copiesChanged: cache?.copiesChanged,
            lastRefreshed: cache?.lastRefreshed, lastDiscovered: cache?.lastDiscovered, names: names,
            nameRoles: nameRoles.isEmpty ? nil : nameRoles, contacts: contacts.isEmpty ? nil : contacts,
            copyNumbers: cache?.copyNumbers)
    }

    /// The document holding `entries`, `state`'s waiting IDs and user data, and the set-aside
    /// numbers and kinds given. What reading can find again is ``VaultCache/init(_:)``'s.
    public init(entries: [VaultEntry], state: VaultReadingState, setAside: SetAside, kinds: [VaultCustomKind],
                savedAt: Date, migratedFrom: MigratedFrom? = nil) {
        self.init(savedAt: savedAt,
                  records: entries.map(VaultRecord.init) + state.finds.map(VaultRecord.init),
                  reading: Reading(readerVersion: state.version, needsReadAgain: state.needsReadAgain,
                                   staleSources: state.staleSources ?? []),
                  setAside: setAside, names: state.names, nameRoles: state.nameRoles ?? [:],
                  contacts: state.contacts ?? [:], lessons: state.lessons, choices: state.choices, kinds: kinds,
                  migratedFrom: migratedFrom)
    }

    /// What a save changes: everything but when and by which build it was sealed.
    public func sameContents(as other: VaultDocument) -> Bool {
        var mine = self, theirs = other
        (mine.savedAt, mine.savedBy, theirs.savedAt, theirs.savedBy) = (.distantPast, "", .distantPast, "")
        return mine == theirs
    }

    /// What a backup is kept for: the saved records and the user's own data. A change only to
    /// what is waiting, or to the reading rules, makes no backup.
    public func sameSavedData(as other: VaultDocument) -> Bool {
        func kept(_ document: VaultDocument) -> VaultDocument {
            var kept = document
            kept.records = kept.records.filter { $0.state == .saved }
            kept.reading = Reading(readerVersion: 0)
            (kept.savedAt, kept.savedBy) = (.distantPast, "")
            return kept
        }
        // As the file holds them: its dates are whole seconds, the model's have fractions, and
        // compared as they are, every save after an edit kept a backup (the third review).
        let encoder = VaultFile.jsonEncoder()
        if let mine = try? encoder.encode(kept(self)), let theirs = try? encoder.encode(kept(other)) { return mine == theirs }
        return kept(self) == kept(other)
    }

    /// The saved records' ids.
    var savedIDs: Set<UUID> { Set(records.filter { $0.state == .saved }.map(\.id)) }

    // MARK: Opening

    /// Opens a document's JSON: strictly when it is this build's format, as far as it can when a
    /// later build's. Throws ``VaultError/unreadableFile`` for anything else.
    static func open(plain: Data) throws -> VaultDocumentOpened {
        switch try stamp(of: plain) {
        case .current:
            do {
                return VaultDocumentOpened(document: try VaultFile.jsonDecoder().decode(VaultDocument.self, from: plain),
                                           readOnly: false, unread: 0)
            } catch {
                Logger.shared.warning("Vault: the Vault document is this build's format and did not decode — \(VaultDocument.why(error))")
                throw VaultError.unreadableFile
            }
        case .newer(let format):
            return try tolerant(plain, format: format)
        }
    }

    /// A later build's document: each part this build can read, the records one by one (a record
    /// it cannot read is counted, never drawn), keys it does not know let pass.
    private static func tolerant(_ plain: Data, format: Int) throws -> VaultDocumentOpened {
        guard let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw VaultError.unreadableFile }
        let decoder = VaultFile.jsonDecoder()
        decoder.userInfo[.vaultTolerant] = true
        func part<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            guard let value = object[key], !(value is NSNull),
                  let json = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
            return try? decoder.decode(T.self, from: json)
        }
        var unread = 0
        var records: [VaultRecord] = []
        for element in object["records"] as? [Any] ?? [] {
            if let json = try? JSONSerialization.data(withJSONObject: element),
               let record = try? decoder.decode(VaultRecord.self, from: json),
               (record.state == .saved ? (try? VaultEntry(record: record)) != nil : (try? VaultFind(record: record)) != nil) {
                records.append(record)
            } else {
                unread += 1
            }
        }
        let document = VaultDocument(
            format: format, savedBy: part("savedBy", String.self) ?? "", savedAt: part("savedAt", Date.self) ?? .distantPast,
            records: records, reading: part("reading", Reading.self) ?? Reading(readerVersion: 0),
            setAside: part("setAside", SetAside.self) ?? SetAside(), names: part("names", [String: String].self) ?? [:],
            nameRoles: part("nameRoles", [String: VaultNameRoles].self) ?? [:],
            contacts: part("contacts", [String: VaultContacts].self) ?? [:],
            lessons: part("lessons", [String: VaultCardID].self) ?? [:],
            choices: part("choices", [String: VaultChoice].self) ?? [:],
            kinds: part("kinds", [VaultCustomKind].self) ?? [],
            migratedFrom: part("migratedFrom", MigratedFrom.self))
        Logger.shared.warning("Vault: the Vault was saved by a newer SyncCloud (format \(format)); it opens read-only, \(unread) record(s) this build cannot read")
        return VaultDocumentOpened(document: document, readOnly: true, unread: unread)
    }

    /// A decoding error, for a log line: where it went wrong, never a value.
    static func why(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return "not JSON this build reads" }
        let context: DecodingError.Context
        switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c): context = c
        @unknown default: return "not JSON this build reads"
        }
        // Positions and key names only: a dictionary key can be a number (`copies`, `mentions`)
        // or a name (`names`), so those are left out.
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? (VaultDocument.knownKeys.contains($0.stringValue) ? $0.stringValue : "…") }
        return "at \(path.joined(separator: "."))"
    }

    /// Key names safe to log.
    private static let knownKeys: Set<String> = VaultRecord.storedKeys.union(
        ["format", "savedBy", "savedAt", "records", "reading", "setAside", "names", "nameRoles", "contacts", "lessons",
         "choices", "kinds", "migratedFrom", "facts", "label", "kind", "value", "isMain", "hidesEnding", "from"])
}

/// What opening a document gave.
public struct VaultDocumentOpened: Equatable, Sendable {
    public var document: VaultDocument
    /// A later build's format: nothing is written over it.
    public var readOnly: Bool
    /// Records a later build wrote that this one cannot read (read-only only).
    public var unread: Int
}

/// What reading can find again (VT6), sealed apart from the document as `vault-cache.sealed`
/// under the marker `SCVCACH1`: which files were read, what each said about each number, and the
/// documents that only name one. A cache that does not open is set aside and started fresh: a
/// read builds it again, and no write of the document waits on it.
public struct VaultCache: Codable, Equatable, Sendable {
    public static let format = 1
    static let marker = Data("SCVCACH1".utf8)

    public var format: Int
    /// The reading rules it was made under: a cache made under others is not used.
    public var readerVersion: Int
    /// The Forget generation the read index belongs to.
    public var generation: Int
    public var read: [String: String]
    public var mentions: [String: [VaultSource]]
    public var copies: [String: [String: VaultFind]]
    public var copyNumbers: [String: VaultCopyNumbers]?
    public var notFound: [String]?
    public var needsDiscover: Bool?
    public var copiesChanged: Bool?
    public var lastRefreshed: Date?
    public var lastDiscovered: Date?

    public init(format: Int = VaultCache.format, readerVersion: Int, generation: Int, read: [String: String] = [:],
                mentions: [String: [VaultSource]] = [:], copies: [String: [String: VaultFind]] = [:],
                copyNumbers: [String: VaultCopyNumbers]? = nil, notFound: [String]? = nil, needsDiscover: Bool? = nil,
                copiesChanged: Bool? = nil, lastRefreshed: Date? = nil, lastDiscovered: Date? = nil) {
        self.format = format
        self.readerVersion = readerVersion
        self.generation = generation
        self.read = read
        self.mentions = mentions
        self.copies = copies
        self.copyNumbers = copyNumbers
        self.notFound = notFound
        self.needsDiscover = needsDiscover
        self.copiesChanged = copiesChanged
        self.lastRefreshed = lastRefreshed
        self.lastDiscovered = lastDiscovered
    }

    /// What `state` holds that reading finds again.
    public init(_ state: VaultReadingState) {
        self.init(readerVersion: state.version, generation: state.generation, read: state.read,
                  mentions: state.mentions, copies: state.copies, copyNumbers: state.copyNumbers,
                  notFound: state.notFound, needsDiscover: state.needsDiscover, copiesChanged: state.copiesChanged,
                  lastRefreshed: state.lastRefreshed, lastDiscovered: state.lastDiscovered)
    }

    /// Whether it was made for `document`: this build's format, under the same reading rules.
    func fits(_ document: VaultDocument) -> Bool {
        format == Self.format && readerVersion == document.reading.readerVersion
    }
}

extension VaultDocument: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultDocument(format \(format), \(records.count) records)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension VaultCache: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "VaultCache(\(read.count) files read)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
