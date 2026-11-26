import CommonCrypto
import CryptoKit
import Events
import Foundation
import Security

/// Why a backup could not be made or read. Each case is something Settings says in words.
public enum VaultBackupError: Error, Equatable, Sendable {
    /// No passphrase has been set, or the one given is too short to be worth sealing with.
    case noPassphrase
    case passphraseTooShort
    /// The file is not a Vault backup this build knows, or was cut short.
    case notABackup
    /// It is a backup, and this passphrase does not open it (or the file was altered).
    case wrongPassphrase
    /// The Vault on this Mac could not be read to back it up, or written to restore into.
    case vaultUnreadable
    case notWritten
    /// The owner did not prove it.
    case notProved
    /// A newer SyncCloud made it (a backup's version, or its Vault's format, above this build's),
    /// or saved the Vault being backed up: this build would lose what it cannot read.
    case newerFormat
}

/// What a backup holds, and when it was made.
///
/// Version 1, every build before 7.2's: the saved IDs (``entries``) and the typed contacts. Not
/// what was read and is still waiting to be confirmed: that is found again by reading the documents.
///
/// Version 2, a Vault kept as the v7.2 document: the whole ``document``, waiting IDs, the user's
/// own data and the set-aside numbers included. ``entries`` and ``contacts`` are then the
/// document's, for counting and for a Vault still kept in the v1 files.
public struct VaultBackupContents: Codable, Equatable, Sendable {
    /// The highest version this build reads, and the one it writes for a document.
    public static let newestVersion = 2

    public var version: Int
    public var madeAt: Date
    public var entries: [VaultEntry]
    /// The Vault's document: version 2 only.
    public var document: VaultDocument?
    /// Records a later build wrote, as their JSON: read from a backup's `entries` when this build
    /// cannot decode them (``laterRecords`` counts them), and put back with a restore, so a
    /// restore here does not drop them.
    public var newer: [Data] = []
    /// The backup's `entries` as they are sealed, when made here from the Vault's file: each
    /// record as ``VaultFile`` seals it (a later build's fields and records kept). Not decoded.
    var sealedEntries: [Data]?
    /// The backup's records as stored, one by one, with what each holds that this build does not
    /// read: a restore seals them back so (``VaultStore/save(_:newer:carrying:)``).
    var stored: VaultRecords?
    /// A version 1 backup's `entries` as their JSON: what the migration's own reader
    /// (``VaultLegacyFormat``) makes records of, for a restore into the document.
    var entriesPlain: Data?

    /// What was typed for each person in People (phones, emails, home addresses): it lives
    /// beside what was read, not with the IDs, and would otherwise be lost to a restore. Nil in a
    /// backup made before contacts, or with none typed.
    public var contacts: [String: VaultContacts]?

    public init(version: Int = 1, madeAt: Date, entries: [VaultEntry], contacts: [String: VaultContacts]? = nil) {
        self.version = version
        self.madeAt = madeAt
        self.entries = entries
        self.contacts = contacts
    }

    /// A version 2 backup of `document`. Throws for a record that does not convert.
    public init(madeAt: Date, document: VaultDocument) throws {
        version = 2
        self.madeAt = madeAt
        self.document = document
        entries = try document.entries()
        contacts = document.contacts.isEmpty ? nil : document.contacts
    }

    private enum CodingKeys: String, CodingKey { case version, madeAt, entries, contacts, document }

    /// A record a later build wrote (a kind, a place or a pin this one does not know) is passed
    /// over, so a backup still restores every record it can read rather than none (VT30). A
    /// version 2 backup's document is read strictly, as the Vault's own is.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        madeAt = try c.decode(Date.self, forKey: .madeAt)
        if version >= 2 {
            let document = try c.decode(VaultDocument.self, forKey: .document)
            guard version == 2, document.format == VaultDocument.format else {
                throw DecodingError.dataCorruptedError(forKey: .document, in: c, debugDescription: "a newer backup or document")
            }
            self.document = document
            entries = try document.entries()
            contacts = document.contacts.isEmpty ? nil : document.contacts
            return
        }
        var list = try c.nestedUnkeyedContainer(forKey: .entries)
        var entries: [VaultEntry] = []
        var skipped = 0
        while !list.isAtEnd {
            if let entry = try? list.decode(VaultLegacyFormat.Entry.self) {
                entries.append(entry.entry)
            } else {
                // A failed element leaves the container where it was; step past it.
                _ = try list.decode(LaterRecord.self)
                skipped += 1
            }
        }
        self.entries = entries
        laterRecords = skipped
        // Lenient: a backup's IDs are never lost over what was typed beside them.
        contacts = try? c.decodeIfPresent([String: VaultContacts].self, forKey: .contacts)
    }

    /// Version 1 as every build before 7.2 wrote it, key for key, each entry as a v1 Vault stores
    /// it (``VaultLegacyFormat/Entry``); version 2 the document alone.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(madeAt, forKey: .madeAt)
        if let document {
            try c.encode(document, forKey: .document)
        } else {
            try c.encode(entries.map(VaultLegacyFormat.Entry.init), forKey: .entries)
            try c.encodeIfPresent(contacts, forKey: .contacts)
        }
    }

    /// How many records in the backup need a newer SyncCloud. Not encoded: a backup is written
    /// from what this build holds.
    public private(set) var laterRecords = 0

    private struct LaterRecord: Decodable {}

    /// What the backup holds: its version, date, records, document and a later build's records.
    /// How they were stored (``stored``, ``sealedEntries``, ``entriesPlain``) is how they go back,
    /// not what they are.
    public static func == (a: Self, b: Self) -> Bool {
        a.version == b.version && a.madeAt == b.madeAt && a.entries == b.entries && a.newer == b.newer
            && a.laterRecords == b.laterRecords && a.contacts == b.contacts && a.document == b.document
    }

    /// The backup as a document, to restore into one: version 2's own; version 1's saved IDs made
    /// into records as the migration makes them (``VaultLegacyFormat``, or each entry as it is
    /// when a later build's record keeps that reader from taking the list), with the typed
    /// contacts. A later build's records have no place in this build's document: they are counted.
    func asDocument(at date: Date) -> VaultDocument {
        if let document { return document }
        let converted = entriesPlain.flatMap { try? VaultLegacyFormat.entries(fromPlain: $0) } ?? entries
        if !newer.isEmpty {
            Logger.shared.warning("Vault: \(newer.count) record(s) in a backup need a newer SyncCloud and cannot go into this build’s Vault — passed over")
        }
        return VaultDocument(entries: converted, state: VaultReadingState(contacts: contacts), setAside: .init(), kinds: [],
                             savedAt: date)
    }
}

/// A backup's bytes: the Vault's IDs sealed under a key made from a passphrase, so the file opens
/// on any Mac that is given the passphrase and on none that is not.
///
/// The Vault's own file is sealed with a random key in this Mac's Keychain, which is why it
/// cannot be read anywhere else, and why a lost Mac or a reset keychain loses it. A backup trades
/// that for a secret the owner carries: `SCVBACK1`, the work factor, a random salt, then the
/// IDs sealed with AES-256-GCM under PBKDF2-HMAC-SHA256 of the passphrase. A lowered work factor
/// or a swapped salt derives another key, so the file does not open; the header is also the box's
/// authenticated data.
public enum VaultBackupFile {
    static let marker = Data("SCVBACK1".utf8)
    /// PBKDF2 rounds for a new backup. Stored in each file, so a later build can raise it and
    /// still open an older backup.
    public static let rounds: UInt32 = 600_000
    /// The least a file may claim: one that asks for almost no work is not one this app made.
    static let leastRounds: UInt32 = 100_000
    /// The most a file may claim. The header is read before anything is proved, and a file in a
    /// synced folder is anyone's to write: one asking for billions of rounds would hold the app
    /// for over an hour. Eight times what this build writes leaves room to raise ``rounds``.
    static let mostRounds: UInt32 = 4_800_000
    static let saltLength = 16
    public static let fileExtension = "scvault"
    /// Shorter than this is refused: the passphrase is all that guards the file once it leaves
    /// this Mac.
    public static let leastPassphraseLength = 12

    static func key(passphrase: String, salt: Data, rounds: UInt32) -> SymmetricKey? {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count,
                                 saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
        }
        guard status == Int32(kCCSuccess) else { return nil }
        return SymmetricKey(data: Data(derived))
    }

    /// `encoded` with its `entries` replaced by `sealed`, when there are any.
    private static func withEntries(_ encoded: Data, _ sealed: [Data]) throws -> Data {
        guard !sealed.isEmpty, var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        object["entries"] = try sealed.map { try JSONSerialization.jsonObject(with: $0) }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The entries of a backup that was opened, each unchanged one as it was stored there
    /// (``VaultBackupContents/stored``), so sealing it again keeps what an older build wrote.
    private static func asStored(_ contents: VaultBackupContents) -> [Data] {
        guard var records = contents.stored, !records.stored.isEmpty || !records.laterFields.isEmpty else { return [] }
        records.entries = contents.entries
        records.newer = []
        return (try? VaultFile.elements(of: records)) ?? []
    }

    private static func header(rounds: UInt32, salt: Data) -> Data {
        var bytes = marker
        withUnsafeBytes(of: rounds.bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(salt)
        return bytes
    }

    /// `rounds` and `salt` are parameters for tests; a real backup takes the defaults.
    public static func seal(_ contents: VaultBackupContents, passphrase: String, rounds: UInt32 = rounds,
                            salt: Data? = nil) throws -> Data {
        guard passphrase.count >= leastPassphraseLength else { throw VaultBackupError.passphraseTooShort }
        var random = [UInt8](repeating: 0, count: saltLength)
        guard salt != nil || SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw VaultBackupError.notWritten
        }
        let salt = salt ?? Data(random)
        // The whole header is the marker the box authenticates, as the Vault's own files do with
        // theirs (VT55).
        guard let key = key(passphrase: passphrase, salt: salt, rounds: rounds),
              let plain = try? withEntries(VaultFile.jsonEncoder().encode(contents), contents.sealedEntries ?? asStored(contents)),
              let sealed = try? VaultFile.sealPlain(plain, marker: header(rounds: rounds, salt: salt), with: key) else {
            throw VaultBackupError.notWritten
        }
        return sealed
    }

    public static func open(_ data: Data, passphrase: String) throws -> VaultBackupContents {
        let headLength = marker.count + 4 + saltLength
        guard data.count > headLength, data.prefix(marker.count) == marker else { throw VaultBackupError.notABackup }
        let head = data.prefix(headLength)
        let rounds = head.dropFirst(marker.count).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let salt = Data(head.suffix(saltLength))
        guard rounds >= leastRounds, rounds <= mostRounds,
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(headLength)) else {
            throw VaultBackupError.notABackup
        }
        guard let key = key(passphrase: passphrase, salt: salt, rounds: rounds),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data(head)) else {
            throw VaultBackupError.wrongPassphrase
        }
        // A newer SyncCloud's backup, or one of a newer SyncCloud's Vault, is refused as that:
        // what this build cannot read would be lost to a restore.
        let object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
        if let version = object?["version"] as? Int, version > VaultBackupContents.newestVersion { throw VaultBackupError.newerFormat }
        if let format = (object?["document"] as? [String: Any])?["format"] as? Int, format > VaultDocument.format {
            throw VaultBackupError.newerFormat
        }
        guard var contents = try? VaultFile.jsonDecoder().decode(VaultBackupContents.self, from: plain) else {
            throw VaultBackupError.notABackup
        }
        // Each record as stored: those this build passes over as their JSON, and later fields on
        // those it reads, so a restore here keeps them.
        if contents.document == nil, let list = object?["entries"] as? [Any] {
            let records = VaultFile.records(fromList: list)
            contents.newer = records.newer
            contents.stored = records
            contents.entriesPlain = try? JSONSerialization.data(withJSONObject: list)
        }
        return contents
    }
}

/// How a backup is put back.
public enum VaultRestoreMode: Sendable {
    /// Adds the backup's IDs that this Vault does not hold, by their number. Nothing is removed
    /// or changed.
    case addMissing
    /// This Vault becomes the backup's. What it held is set aside in a file of its own first.
    case replace
}

/// Backing the Vault up and restoring it (Settings ▸ Vault).
///
/// The passphrase is kept in the login Keychain so a backup can be made without asking for it
/// each week; opening a backup on another Mac takes typing it. A backup holds every ID in full,
/// so making one and restoring one both ask the Mac's owner to prove it, as showing an ID does.
///
/// On the main actor, with the panel's model and Settings, the only places it is used from.
@MainActor
public struct VaultBackup {
    public let store: VaultStore
    private let keychain: KeychainStore
    private let authenticator: VaultAuthenticating
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let clock: @Sendable () -> Date
    /// PBKDF2 rounds for a backup made here: ``VaultBackupFile/rounds``, lowered only by tests.
    private let rounds: UInt32
    /// Sealing and opening, each with its key derivation: ``VaultBackupFile``'s, run off the main
    /// actor (VT58). Injectable so a test can see where they run.
    typealias Seal = @Sendable (VaultBackupContents, String, UInt32) throws -> Data
    typealias Open = @Sendable (Data, String) throws -> VaultBackupContents
    private let seal: Seal
    private let open: Open

    public init(store: VaultStore, keychain: KeychainStore = SecItemKeychainStore(),
                authenticator: VaultAuthenticating = VaultDeviceOwnerProof(), defaults: UserDefaults = .standard,
                fileManager: FileManager = .default, clock: @escaping @Sendable () -> Date = { Date() },
                rounds: UInt32 = VaultBackupFile.rounds) {
        self.init(store: store, keychain: keychain, authenticator: authenticator, defaults: defaults,
                  fileManager: fileManager, clock: clock, rounds: rounds,
                  seal: { try VaultBackupFile.seal($0, passphrase: $1, rounds: $2) },
                  open: { try VaultBackupFile.open($0, passphrase: $1) })
    }

    init(store: VaultStore, keychain: KeychainStore, authenticator: VaultAuthenticating, defaults: UserDefaults,
         fileManager: FileManager, clock: @escaping @Sendable () -> Date, rounds: UInt32,
         seal: @escaping Seal, open: @escaping Open) {
        self.store = store
        self.keychain = keychain
        self.authenticator = authenticator
        self.defaults = defaults
        self.fileManager = fileManager
        self.clock = clock
        self.rounds = rounds
        self.seal = seal
        self.open = open
    }

    /// A line for the Vault's activity list, when it keeps one.
    private func note(_ kind: VaultActivityEvent.Kind, _ what: String) {
        guard VaultActivitySettings.keeps(in: defaults) else { return }
        let now = clock()
        VaultActivityStore.beside(store, keychain: keychain, fileManager: fileManager).append([VaultActivityEvent(at: now, kind: kind, what: what)], now: now)
    }

    // MARK: Settings

    public static let folderKey = "vaultBackupFolder"
    public static let lastKey = "vaultBackupLast"
    public static let weeklyKey = "vaultBackupWeekly"
    /// Posted after a restore wrote the Vault's file: a panel holding the old IDs lets them go.
    /// Its `userInfo` names the file (``restoredPathKey``), so only that Vault's panel answers.
    public static let didRestore = Notification.Name("VaultBackupDidRestore")
    public static let restoredPathKey = "path"

    /// Where backups go: the folder chosen, else `~/Documents/Backups/Vault`.
    public var folder: URL {
        if let chosen = defaults.string(forKey: Self.folderKey), !chosen.isEmpty { return URL(fileURLWithPath: chosen) }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Backups/Vault")
    }

    public var lastBackup: Date? { defaults.object(forKey: Self.lastKey) as? Date }

    public var isWeekly: Bool { defaults.object(forKey: Self.weeklyKey) as? Bool ?? true }

    /// Whether the weekly backup is owed: weekly is on, a passphrase is set, and none was made in
    /// the last seven days.
    public var isDue: Bool {
        guard isWeekly else { return false }
        // The date first, the Keychain only when it says a week has passed: the panel asks at
        // every open, and each passphrase read is a Keychain round trip (VT10).
        if let last = lastBackup, clock().timeIntervalSince(last) < 7 * 86_400 { return false }
        return hasPassphrase
    }

    // MARK: The passphrase

    private static let service = "com.synccloud.vault-backup"

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "passphrase"]
    }

    public var hasPassphrase: Bool { passphrase() != nil }

    func passphrase() -> String? {
        var query = query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(query)
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    /// Keeps `passphrase` for the backups made from now on. Backups already made open with the
    /// passphrase they were made with, not this one.
    /// The kept passphrase is changed in place, never deleted first: a Keychain that refuses the
    /// change leaves the old one, so the weekly backup goes on rather than stopping for want of one.
    public func setPassphrase(_ passphrase: String) throws {
        guard passphrase.count >= VaultBackupFile.leastPassphraseLength else { throw VaultBackupError.passphraseTooShort }
        let data = Data(passphrase.utf8)
        var status = keychain.update(query(), attributes: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var item = query()
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "SyncCloud Vault backup passphrase"
            status = keychain.add(item)
        }
        guard status == errSecSuccess else {
            Logger.shared.warning("Vault: the Keychain refused to keep the backup passphrase (status \(status))")
            throw VaultBackupError.notWritten
        }
    }

    // MARK: Backing up

    static func fileName(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .current, from: date)
        return String(format: "Vault Backup %04d-%02d-%02d.%@", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1,
                      VaultBackupFile.fileExtension)
    }

    /// Seals `entries` under the kept passphrase and writes them to the backup folder, beside every
    /// backup made before: never over one, not even the same day's, which may be the only copy
    /// that moves the Vault to another Mac (`Vault Backup 2026-11-23 2.scvault` beside it). No
    /// proof is asked here: the caller holds the IDs already, which took one.
    ///
    /// The key is derived off the main actor (VT58): PBKDF2 at ``VaultBackupFile/rounds`` takes most
    /// of a second, which held the panel as it opened for the weekly backup.
    ///
    /// A version 1 backup: what a Vault still kept in the v1 files backs up. One kept as the
    /// document backs up with ``write(document:)``.
    @discardableResult
    public func write(_ entries: [VaultEntry], contacts: [String: VaultContacts] = [:]) async throws -> URL {
        guard let passphrase = passphrase() else { throw VaultBackupError.noPassphrase }
        let now = clock()
        var contents = VaultBackupContents(madeAt: now, entries: entries, contacts: contacts.isEmpty ? nil : contacts)
        // Each record as the Vault's file seals it: a later build's records, and its fields on
        // records this build reads, go with it. The backup is the Vault's, not this build's view.
        if let held = try? store.loadRecords() {
            var records = VaultRecords(entries: entries, newer: held.newer, laterFields: held.laterFields, stored: held.stored)
            records.laterFields = records.laterFields.filter { id, _ in entries.contains { $0.id == id } }
            contents.sealedEntries = try? VaultFile.elements(of: records)
        }
        return try await write(contents, passphrase: passphrase, at: now)
    }

    /// ``write(_:contacts:)`` for a Vault kept as the v7.2 document: a version 2 backup of the
    /// whole of it, waiting IDs, the user's own data and the set-aside numbers included. A later
    /// build's document is not backed up here (``VaultBackupError/newerFormat``): this build
    /// would leave out what it cannot read.
    @discardableResult
    public func write(document: VaultDocument) async throws -> URL {
        guard document.format == VaultDocument.format else { throw VaultBackupError.newerFormat }
        guard let passphrase = passphrase() else { throw VaultBackupError.noPassphrase }
        var document = document
        // Which key its set-aside numbers were made under, for Add Missing to tell: a document
        // not yet written here has no stamp.
        if document.setAside.keyID.isEmpty, let keyID = store.keyID { document.setAside.keyID = keyID }
        let now = clock()
        let contents: VaultBackupContents
        do { contents = try VaultBackupContents(madeAt: now, document: document) } catch { throw VaultBackupError.vaultUnreadable }
        return try await write(contents, passphrase: passphrase, at: now)
    }

    private func write(_ contents: VaultBackupContents, passphrase: String, at now: Date) async throws -> URL {
        let entries = contents.entries
        let rounds = rounds, seal = seal
        let sealed = try await Task.detached(priority: .userInitiated) {
            try seal(contents, passphrase, rounds)
        }.value
        var url = freeName(for: now)
        do {
            // A name taken between the look and the write (Back Up Now beside the weekly
            // backup) moves on to the next free one, never over it.
            var tries = 0
            while true {
                do {
                    try SealedFile.write(sealed, to: url, fileManager: fileManager, replacing: false)
                    break
                } catch CocoaError.fileWriteFileExists where tries < 20 {
                    tries += 1
                    url = freeName(for: now)
                }
            }
        } catch {
            Logger.shared.warning("Vault: a backup could not be written — \(error.localizedDescription)")
            throw VaultBackupError.notWritten
        }
        defaults.set(now, forKey: Self.lastKey)
        // A count and nothing else: neither the folder's name nor an ID belongs in the log.
        Logger.shared.info("Vault: backed up \(entries.count) ID(s)")
        note(.backedUp, entries.count == 1 ? "Backed up 1 ID" : "Backed up \(entries.count) IDs")
        return url
    }

    /// The day's name in the backup folder, or the first ` 2`, ` 3` … after it no file has.
    func freeName(for date: Date) -> URL {
        let first = Self.fileName(date)
        let stem = (first as NSString).deletingPathExtension
        var url = folder.appendingPathComponent(first)
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem) \(n).\(VaultBackupFile.fileExtension)")
            n += 1
        }
        return url
    }

    /// Back Up Now: proves it is the owner, reads the Vault, and writes a backup, with the
    /// household's typed contacts as the weekly backup carries them.
    public func backUpNow() async -> Result<URL, VaultBackupError> {
        guard hasPassphrase else { return .failure(.noPassphrase) }
        guard case .allowed = await authenticator.prove(reason: "back up your Vault") else { return .failure(.notProved) }
        do {
            // The document whole, as the panel's weekly backup makes it; the v1 files as before.
            if store.fileFormat == .document {
                guard let loaded = try? store.loadDocument(settingCacheAside: false) else { return .failure(.vaultUnreadable) }
                guard !loaded.readOnly else { return .failure(.newerFormat) }
                return .success(try await write(document: loaded.document))
            }
            guard let entries = try? store.load() else { return .failure(.vaultUnreadable) }
            let contacts = store.openReading().state?.contacts ?? [:]
            return .success(try await write(entries, contacts: contacts))
        } catch let error as VaultBackupError { return .failure(error) } catch {
            return .failure(.notWritten)
        }
    }

    // MARK: Restoring

    /// Opens a backup file with `passphrase`; with none given, with the kept one. The key is
    /// derived off the main actor, as ``write(_:)`` does.
    public func read(_ url: URL, passphrase: String? = nil) async -> Result<VaultBackupContents, VaultBackupError> {
        guard let data = fileManager.contents(atPath: url.path) else { return .failure(.notABackup) }
        guard let passphrase = passphrase ?? self.passphrase() else { return .failure(.noPassphrase) }
        do {
            let open = open
            let contents = try await Task.detached(priority: .userInitiated) {
                try open(data, passphrase)
            }.value
            if contents.laterRecords > 0 {
                Logger.shared.warning("Vault: \(contents.laterRecords) record(s) in a backup need a newer SyncCloud — passed over")
            }
            return .success(contents)
        } catch let error as VaultBackupError {
            return .failure(error)
        } catch {
            return .failure(.notABackup)
        }
    }

    /// What ``restore(_:mode:)`` would do, without doing it: how many of the backup's IDs this
    /// Vault lacks. Nil when the Vault on this Mac cannot be read (then only Replace applies).
    public func missing(from contents: VaultBackupContents) -> Int? {
        guard let held = heldIDs() else { return nil }
        let have = Set(held.map { VaultReading.normalized($0.value) })
        return contents.entries.filter { !have.contains(VaultReading.normalized($0.value)) }.count
    }

    /// The saved IDs this Vault holds, from the document or the v1 file: nil when it cannot be
    /// read, or a later build's document holds it (only Replace applies to that one).
    private func heldIDs() -> [VaultEntry]? {
        guard store.keepsDocument else { return try? store.load() }
        let found: VaultStore.DocumentLoad?
        do { found = try store.loadDocument(settingCacheAside: false) } catch { return nil }
        guard let loaded = found else { return [] }
        guard !loaded.readOnly else { return nil }
        return try? loaded.document.entries()
    }

    /// A stored record's id, read from its JSON.
    static func id(of record: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: record) as? [String: Any])?["id"] as? String
    }

    /// Puts what was typed for each person back beside what was read. A Replace has set the
    /// reading file aside, so it starts one holding them alone (what is read comes back with the
    /// next read); Add Missing gives each person what they lack, keeping what is here.
    func restoreContacts(_ restored: [String: VaultContacts]?, mode: VaultRestoreMode) {
        guard let restored, !restored.isEmpty else { return }
        var state: VaultReadingState
        switch mode == .replace ? .none : store.openReading() {
        case .loaded(let held): state = held
        case .none: state = VaultReadingState(generation: VaultSetAside.generation(in: defaults))
        default:
            // A reading file that will not open is never sealed over.
            Logger.shared.warning("Vault: the typed contacts in the backup could not be put back")
            return
        }
        state.contacts = Self.merged(contacts: state.contacts ?? [:], restored)
        do { try store.saveReading(state) } catch {
            Logger.shared.warning("Vault: the typed contacts in the backup could not be put back")
        }
    }

    /// Each person's typed contacts with what `restored` holds that they lack: a phone by its
    /// digits, an email, an address by its key, and each "not theirs" mark.
    static func merged(contacts: [String: VaultContacts], _ restored: [String: VaultContacts]) -> [String: VaultContacts] {
        var contacts = contacts
        for (person, theirs) in restored {
            var mine = contacts[person] ?? VaultContacts()
            for phone in theirs.phones
            where !mine.phones.contains(where: { VaultContacts.phoneKey($0.value) == VaultContacts.phoneKey(phone.value) }) {
                mine.phones.append(phone)
            }
            for email in theirs.emails where !mine.emails.contains(where: { $0.value == email.value }) { mine.emails.append(email) }
            for key in theirs.notTheirPhones where !mine.notTheirPhones.contains(key) { mine.notTheirPhones.append(key) }
            for address in theirs.addresses where !mine.addresses.contains(where: { $0.address.key == address.address.key }) {
                mine.addresses.append(address)
            }
            for key in theirs.notTheirs where !mine.notTheirs.contains(key) { mine.notTheirs.append(key) }
            contacts[person] = mine
        }
        return contacts
    }

    /// Replace never deletes: the Vault's file and what was read are renamed aside first
    /// (``VaultStore/moveAsideForReplace(at:)``), which is also what lets a Vault this Mac cannot open be
    /// replaced at all.
    ///
    /// Into a Vault kept as the v7.2 document, the document is written (``restoreDocument(_:mode:)``),
    /// from a backup of either version. Into one still kept in the v1 files, the v1 file is, as
    /// before 7.2: a version 2 backup gives it its saved IDs, typed contacts and kinds.
    public func restore(_ contents: VaultBackupContents, mode: VaultRestoreMode) async -> Result<Int, VaultBackupError> {
        guard case .allowed = await authenticator.prove(reason: "restore your Vault from a backup") else {
            return .failure(.notProved)
        }
        if store.keepsDocument { return restoreDocument(contents, mode: mode) }
        let entries: [VaultEntry]
        switch mode {
        case .addMissing:
            guard let held = try? store.load() else { return .failure(.vaultUnreadable) }
            let have = Set(held.map { VaultReading.normalized($0.value) })
            // A backup made before a number was corrected holds the old number under the same
            // id. It comes back as an ID of its own: two records with one id would be removed
            // together and edited as one.
            var ids = Set(held.map(\.id))
            // An ID this Vault holds only as a later build's record is held all the same: its
            // older copy in the backup does not come back beside it.
            let heldLater = Set(((try? store.loadRecords()) ?? VaultRecords()).newer.compactMap(Self.id(of:)))
            let missing = contents.entries
                .filter { !have.contains(VaultReading.normalized($0.value)) && !heldLater.contains($0.id.uuidString) }
                .map { ids.insert($0.id).inserted ? $0 : $0.reissued() }
            entries = held + missing
        case .replace:
            entries = contents.entries
        }
        // A later build's records in the backup come back too: all of them on a Replace; on Add
        // Missing, those whose id this Vault does not hold already.
        let newer: [Data]
        if mode == .replace {
            newer = contents.newer
        } else {
            let heldIDs = Set(((try? store.loadRecords()) ?? VaultRecords()).newer.compactMap(Self.id(of:)) + entries.map(\.id.uuidString))
            newer = contents.newer.filter { Self.id(of: $0).map { !heldIDs.contains($0) } ?? true }
        }
        // Replace sets what is here aside first, and puts it back if the new Vault cannot be
        // written (a refused Keychain, a full disk): never a Mac left with no Vault in place.
        var moved: [VaultStore.Aside] = []
        if mode == .replace {
            store.keepBackupOfCurrent()
            guard let aside = store.moveAsideForReplace(at: clock()) else { return .failure(.notWritten) }
            moved = aside
        }
        do {
            try store.save(entries, newer: newer, carrying: contents.stored)
        } catch {
            store.putBack(moved)
            return .failure(.notWritten)
        }
        restoreContacts(contents.contacts, mode: mode)
        // The kinds a version 2 backup's IDs may be on, beside those here (kept in UserDefaults
        // while the Vault is kept in the v1 files).
        if let kinds = contents.document?.kinds, !kinds.isEmpty {
            var held = VaultKinds.load(from: defaults)
            held.custom += kinds.filter { kind in !held.custom.contains { $0.id == kind.id } }
            held.save(to: defaults)
        }
        restored(contents, mode: mode, count: entries.count)
        return .success(entries.count)
    }

    /// The log line, the activity entry and the notice every restore ends with.
    private func restored(_ contents: VaultBackupContents, mode: VaultRestoreMode, count: Int) {
        Logger.shared.info("Vault: restored from a backup (\(mode == .replace ? "replaced" : "added what was missing")), \(count) ID(s) now")
        note(.restored, mode == .replace ? "Replaced the Vault from a backup of \(contents.entries.count) ID(s)"
                                         : "Added what was missing from a backup of \(contents.entries.count) ID(s)")
        NotificationCenter.default.post(name: Self.didRestore, object: nil, userInfo: [Self.restoredPathKey: store.fileURL.path])
    }

    // MARK: Restoring into the document

    /// ``restore(_:mode:)`` for a Vault kept as the v7.2 document: one atomic write of the document.
    ///
    /// - Replace: the backup's document (a version 1 backup's IDs and contacts made into one,
    ///   keeping this Vault's kinds, as a Replace before 7.2 left UserDefaults' alone), holding this
    ///   Vault's set-aside numbers and Forget generation: what was set aside here stays set aside.
    ///   The Vault and its cache are renamed aside first and put back if the write fails.
    /// - Add Missing: ``addingMissing(_:to:sameKey:isSetAside:)``. Refused for a Vault this Mac
    ///   cannot open, or a later build's.
    func restoreDocument(_ contents: VaultBackupContents, mode: VaultRestoreMode) -> Result<Int, VaultBackupError> {
        let now = clock()
        let incoming = contents.asDocument(at: now)
        let current: VaultStore.DocumentLoad?
        let opened: Bool
        do { (current, opened) = (try store.loadDocument(settingCacheAside: false), true) } catch { (current, opened) = (nil, false) }
        let keyID = store.keyID
        var document: VaultDocument
        switch mode {
        case .addMissing:
            guard opened, current?.readOnly != true else { return .failure(.vaultUnreadable) }
            let held = current?.document ?? VaultDocument(entries: [], state: VaultReadingState(), setAside: .init(), kinds: [],
                                                          savedAt: now)
            let fingerprints = Set(held.setAside.fingerprints)
            document = Self.addingMissing(incoming, to: held, sameKey: keyID != nil && incoming.setAside.keyID == keyID) { value in
                // A number whose fingerprint cannot be had here is taken as set aside: it is
                // offered again by the next read, never shown against the user's choice.
                guard !fingerprints.isEmpty else { return false }
                return store.fingerprint(value).map(fingerprints.contains) ?? true
            }
        case .replace:
            document = incoming
            document.migratedFrom = nil
            if let held = current?.document {
                document.setAside = held.setAside
                if contents.document == nil { document.kinds = held.kinds }
            } else if keyID == nil || incoming.setAside.keyID != keyID {
                // This Vault's do not open; the backup's are kept only when made under this key.
                document.setAside = .init()
            }
        }
        if mode == .replace { store.keepBackupOfCurrent() }
        do {
            // Replace sets the Vault's files aside and puts them back, if refused, under the lock.
            try store.saveDocument(document, expecting: mode == .replace ? .absent : current?.onDisk ?? .absent,
                                   replacingAt: mode == .replace ? now : nil)
        } catch {
            return .failure(.notWritten)
        }
        let count = document.records.filter { $0.state == .saved }.count
        restored(contents, mode: mode, count: count)
        return .success(count)
    }

    /// `held` with what `backup` holds that it lacks, nothing here removed or changed:
    ///
    /// - each saved record whose number no saved record here has, under an id of its own when
    ///   its id is taken here (a backup from before a number was corrected holds the old number
    ///   under the same id);
    /// - each record waiting in To Confirm whose number is neither saved nor waiting here, nor
    ///   set aside here (`isSetAside`), when both were read under the same rules (else the next
    ///   read finds it again);
    /// - each name, role, lesson and choice under a key not here, each kind whose id is not here,
    ///   and each person's typed contacts as ``merged(contacts:_:)`` gives them;
    /// - the backup's set-aside numbers, when made under this Vault's key (`sameKey`).
    static func addingMissing(_ backup: VaultDocument, to held: VaultDocument, sameKey: Bool,
                              isSetAside: (String) -> Bool) -> VaultDocument {
        var result = held
        var ids = Set(held.records.map(\.id))
        func ownID(_ record: VaultRecord) -> VaultRecord {
            var record = record
            while !ids.insert(record.id).inserted { record.id = UUID() }
            return record
        }
        func number(_ record: VaultRecord) -> String? { record.value.map(VaultReading.normalized) }
        let heldSaved = held.records.filter { $0.state == .saved }
        let heldWaiting = held.records.filter { $0.state == .toConfirm }
        let savedHere = Set(heldSaved.compactMap(number))
        let addedSaved = backup.records
            .filter { $0.state == .saved && number($0).map { !savedHere.contains($0) } == true }
            .map(ownID)
        var addedWaiting: [VaultRecord] = []
        if backup.reading.readerVersion == held.reading.readerVersion {
            var taken = savedHere.union(addedSaved.compactMap(number)).union(heldWaiting.compactMap(number))
            for record in backup.records where record.state == .toConfirm {
                guard let value = record.value, taken.insert(VaultReading.normalized(value)).inserted, !isSetAside(value) else { continue }
                addedWaiting.append(ownID(record))
            }
        }
        result.records = heldSaved + addedSaved + heldWaiting + addedWaiting
        result.names.merge(backup.names) { mine, _ in mine }
        result.nameRoles.merge(backup.nameRoles) { mine, _ in mine }
        result.lessons.merge(backup.lessons) { mine, _ in mine }
        result.choices.merge(backup.choices) { mine, _ in mine }
        result.kinds += backup.kinds.filter { kind in !held.kinds.contains { $0.id == kind.id } }
        result.contacts = merged(contacts: held.contacts, backup.contacts)
        if sameKey {
            result.setAside.fingerprints = Set(held.setAside.fingerprints).union(backup.setAside.fingerprints).sorted()
        }
        return result
    }
}
