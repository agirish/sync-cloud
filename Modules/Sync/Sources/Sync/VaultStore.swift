import CryptoKit
import Events
import Foundation
import Security

/// Why the Vault could not be read or written. Each case is something the panel says in words;
/// none carries an entry.
public enum VaultError: Error, Equatable, Sendable {
    /// A sealed file is on disk but its key is not in the Keychain: another Mac's file, or a key
    /// removed in Keychain Access. The file is left alone; without its key nothing can read it.
    case keyMissing
    /// The Keychain has the key and will not hand it over now (locked, denied, or a policy).
    case keyUnreadable(OSStatus)
    /// The Keychain refused to keep a new key, so nothing was written.
    case keyNotSaved(OSStatus)
    /// The file is not a Vault file this build knows, or was cut short.
    case unreadableFile
    /// The file did not open with this Mac's key: damaged, or sealed with another key.
    case wrongKeyOrDamaged
    /// The disk refused the write. The file on disk is the one from before.
    case notWritten
    /// The write would have removed this many records at once. Nothing in the app removes more
    /// than one, so it is taken for a mistake and refused (VT20); the file on disk is the one
    /// from before.
    case wouldDrop(Int)
    /// The file changed since this copy of the app last read or wrote it: another SyncCloud
    /// running on this Mac saved over it (VT108). Nothing was written over its change.
    case changedElsewhere
}

/// The sealed file as one copy of the app last saw it: none, or its bytes' SHA-256. A save that
/// expects one refuses a file that no longer matches (``VaultError/changedElsewhere``).
public enum VaultFileState: Equatable, Sendable {
    case absent
    case sealed(Data)

    static func of(_ data: Data?) -> VaultFileState {
        data.map { .sealed(Data(SHA256.hash(data: $0))) } ?? .absent
    }
}

/// The Vault's key: 256 random bits in the login Keychain, beside the Anthropic key.
///
/// Made once and never replaced. A second key would orphan every entry sealed with the first, so
/// there is no `store` that overwrites: ``create(in:)`` adds, and refuses when one is there.
public enum VaultKeychain {
    private static let service = "com.synccloud.vault-key"
    private static let account = "default"

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public enum ReadOutcome: Equatable {
        case found(SymmetricKey)
        /// No key has been made on this Mac.
        case notCreated
        /// One is there and the Keychain will not release it now.
        case unreadable(OSStatus)
    }

    public static func read(from store: KeychainStore = SecItemKeychainStore()) -> ReadOutcome {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = store.copyMatching(query)
        if status == errSecItemNotFound { return .notCreated }
        guard status == errSecSuccess else {
            Logger.shared.warning("Vault: the Keychain returned status \(status) for the Vault key — it cannot be read right now (locked Keychain, denied prompt, or policy)")
            return .unreadable(status)
        }
        // Anything but 32 bytes is not a key this build made. Reported as unreadable, not as
        // missing: "missing" would invite making a new key over an item that is there.
        guard let data = result as? Data, data.count == 32 else {
            Logger.shared.warning("Vault: the stored Vault key is not 32 bytes — it cannot be used")
            return .unreadable(errSecDecode)
        }
        return .found(SymmetricKey(data: data))
    }

    /// Makes the key and keeps it, in the login Keychain like the Anthropic key (see
    /// ``AnthropicKeychain/store(_:in:)`` on why that is the file-based one). It is not
    /// synchronised, so a sealed file copied to another Mac stays sealed there unless that Mac's
    /// login Keychain was migrated with it.
    ///
    /// What this does not do: bind the key to Touch ID. That takes the data-protection Keychain and
    /// an entitlement an ad-hoc build cannot carry, so the lock is the app's (``VaultLock``), and
    /// software running as the user could ask the Keychain for this item.
    public static func create(in store: KeychainStore = SecItemKeychainStore()) -> Result<SymmetricKey, VaultError> {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let status = store.add(baseQuery().merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrLabel as String: "SyncCloud Vault key",
        ]) { _, new in new })
        guard status == errSecSuccess else {
            Logger.shared.warning("Vault: the Keychain refused to keep a new Vault key (status \(status)) — nothing was saved")
            return .failure(.keyNotSaved(status))
        }
        return .success(key)
    }

    /// Removes the key: only one ``VaultStore`` made for a save that then wrote nothing.
    static func delete(from store: KeychainStore) {
        store.delete(baseQuery())
    }
}

/// The one way a sealed file reaches the disk (VT55): the Vault's, what was read, the activity
/// list, a passphrase backup and the copies kept before each save.
///
/// The bytes go to a temporary file, created owner-only and flushed to the disk, and are then
/// swapped in whole, the folder flushed after. So a crash or a power loss mid-write leaves the
/// file before, never half of a sealed box, and the file is never readable by others under its
/// own name, not even for a moment.
/// The temporary file is in the volume's replacement folder; on a volume that has none (a
/// network share whose root is not the user's) it sits beside the file, under a name that does
/// not start with a dot: a backup folder may be in iCloud Drive.
enum SealedFile {
    /// Writes `data` to a new file created owner-only, so no other user can read it for even the
    /// moment before a chmod (``write(_:to:fileManager:)`` still sets 0600 after, in case the
    /// volume ignores the mode it was created with). Fails when the file is there already.
    static func writeOwnerOnly(_ data: Data, to url: URL, flushing: Bool = true) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            // Why, as the system said it: no permission, a read-only volume, a name too long.
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            // On the disk itself before it is swapped in, so a power loss after the swap cannot
            // leave the name over bytes never written. A volume without F_FULLFSYNC (a network
            // share) gets a plain fsync.
            if flushing, fcntl(descriptor, F_FULLFSYNC) != 0 { _ = fsync(descriptor) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// `replacing` off: a file already at `url` is never replaced, and this throws
    /// `fileWriteFileExists` instead (a passphrase backup's name taken meanwhile).
    /// `flushing` off: not forced to the disk (the activity list, written at every Show and Copy,
    /// which a power loss may take the last lines of; a record, not something to fail an act over).
    static func write(_ data: Data, to url: URL, fileManager: FileManager, replacing: Bool = true,
                      flushing: Bool = true) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A link is written through: the file it names is replaced, and the link stays.
        let target = url.resolvingSymlinksInPath()
        let temporary: URL
        let scratch = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                           appropriateFor: target, create: true)
        if let scratch {
            temporary = scratch.appendingPathComponent(target.lastPathComponent)
        } else {
            temporary = target.deletingLastPathComponent()
                .appendingPathComponent("\(target.lastPathComponent).writing-\(UUID().uuidString)")
        }
        defer {
            if let scratch { try? fileManager.removeItem(at: scratch) }
            else if fileManager.fileExists(atPath: temporary.path) { try? fileManager.removeItem(at: temporary) }
        }
        try writeOwnerOnly(data, to: temporary, flushing: flushing)
        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        } catch {
            // Written all the same: the folder is the user's own, and a file left unwritten would
            // lose the change. Said, so a disk that refuses permissions is not silent.
            Logger.shared.warning("Vault: \(url.lastPathComponent) could not be made owner-only — \(error.localizedDescription)")
        }
        if fileManager.fileExists(atPath: target.path) {
            guard replacing else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path]) }
            do {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary, backupItemName: nil,
                                                  options: .usingNewMetadataOnly)
            } catch {
                // A replace that failed partway can leave the original in the replacement folder,
                // which the `defer` would remove: it goes back first.
                if let original = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL,
                   !fileManager.fileExists(atPath: target.path) {
                    try? fileManager.moveItem(at: original, to: target)
                }
                throw error
            }
        } else {
            // A link whose file is gone is replaced, as a whole-file write always did.
            if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: temporary, to: target)
        }
        if flushing { syncFolder(of: target) }
    }

    /// The folder's entry for the file, on the disk too: the swap itself survives a power loss.
    private static func syncFolder(of file: URL) {
        let folder = open(file.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard folder >= 0 else { return }
        if fcntl(folder, F_FULLFSYNC) != 0 { _ = fsync(folder) }
        close(folder)
    }
}

/// What a sealed Vault file holds: the records this build reads, and any a later build wrote that
/// it cannot, kept as their JSON so they go back on disk as they came (VT30).
public struct VaultRecords: Equatable, Sendable {
    public var entries: [VaultEntry]
    /// Each record this build could not decode, as the JSON it was stored as. Never drawn, never
    /// changed; written back after ``entries``.
    public var newer: [Data]
    /// For a record this build reads, the fields a later build added that it does not
    /// (``VaultLegacyFormat/Entry/storedKeys``), by id, as a JSON object: merged back in when it is sealed, so
    /// an older build's save never drops them.
    public var laterFields: [UUID: Data]
    /// For a record holding something this build does not write (a later field at any depth),
    /// the record as read and its JSON as stored: sealed back as it came while it is unchanged,
    /// so a later field nested inside it (in its facts, say) is not lost to a save here.
    public var stored: [UUID: [StoredRecord]]

    public struct StoredRecord: Equatable, Sendable {
        public let entry: VaultEntry
        public let json: Data
    }

    public init(entries: [VaultEntry] = [], newer: [Data] = [], laterFields: [UUID: Data] = [:],
                stored: [UUID: [StoredRecord]] = [:]) {
        self.entries = entries
        self.newer = newer
        self.laterFields = laterFields
        self.stored = stored
    }
}

/// The Vault's bytes on disk: a marker, then every entry as JSON sealed with AES-GCM.
///
/// One sealed box for the whole list, not one per entry: the titles, the people and how many
/// numbers there are stay as private as the numbers. The marker is authenticated with the box, so
/// a file whose first bytes were swapped does not open.
public enum VaultFile {
    /// `SCVAULT` and a format digit. A build that meets a later digit says ``VaultError/unreadableFile``
    /// and writes nothing.
    static let marker = Data("SCVAULT1".utf8)

    public static func seal(_ entries: [VaultEntry], with key: SymmetricKey) throws -> Data {
        try seal(VaultRecords(entries: entries), with: key)
    }

    public static func open(_ data: Data, with key: SymmetricKey) throws -> [VaultEntry] {
        try openRecords(data, with: key).entries
    }

    /// Seals `records`: the entries as one JSON array, as every build before this one wrote them,
    /// with any newer records after them, each as it was read.
    public static func seal(_ records: VaultRecords, with key: SymmetricKey) throws -> Data {
        guard !records.newer.isEmpty || !records.laterFields.isEmpty || !records.stored.isEmpty else {
            return try seal(records.entries.map(VaultLegacyFormat.Entry.init), marker: marker, with: key)
        }
        let elements = try elements(of: records)
        var plain = Data("[".utf8)
        for (index, element) in elements.enumerated() {
            if index > 0 { plain.append(Data(",".utf8)) }
            plain.append(element)
        }
        plain.append(Data("]".utf8))
        return try sealPlain(plain, marker: marker, with: key)
    }

    /// Each record as it is sealed: unchanged ones holding what this build does not write as they
    /// were stored, the rest encoded with their later top-level fields, then a later build's
    /// records. What a passphrase backup carries too.
    static func elements(of records: VaultRecords) throws -> [Data] {
        let encoder = jsonEncoder()
        return try records.entries.map { entry -> Data in
            // Matched by the whole record, not the id alone: two records can share one (Add
            // Missing made them until 5e33b3c47).
            if let stored = records.stored[entry.id]?.first(where: { $0.entry == entry }) { return stored.json }
            return try merging(encoder.encode(VaultLegacyFormat.Entry(entry)), records.laterFields[entry.id])
        } + records.newer
    }

    /// Every record in `data`, decoded one by one when the list as a whole does not decode: one
    /// record from a later build (a kind, a place or a pin this build does not know) is kept aside
    /// rather than closing the Vault. Throws only for a file that is not a Vault file at all.
    public static func openRecords(_ data: Data, with key: SymmetricKey) throws -> VaultRecords {
        let plain = try openPlain(data, marker: marker, with: key)
        let decoder = jsonDecoder()
        guard let list = try? JSONSerialization.jsonObject(with: plain) as? [Any] else {
            throw VaultError.unreadableFile
        }
        var records = VaultRecords()
        let encoder = jsonEncoder()
        /// Notes what `entry`, read from `element`, holds that this build would not write back.
        func keep(_ entry: VaultEntry, from element: Any) {
            records.laterFields[entry.id] = laterFields(of: element, known: VaultLegacyFormat.Entry.storedKeys)
            guard let json = try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys]),
                  let ours = try? JSONSerialization.jsonObject(with: encoder.encode(VaultLegacyFormat.Entry(entry))) as? NSDictionary,
                  let theirs = element as? NSDictionary, ours != theirs else { return }
            records.stored[entry.id, default: []].append(VaultRecords.StoredRecord(entry: entry, json: inEncoderOrder(json)))
        }
        if let entries = try? decoder.decode([VaultLegacyFormat.Entry].self, from: plain).map(\.entry) {
            records.entries = entries
            for (entry, element) in zip(entries, list) { keep(entry, from: element) }
            return records
        }
        for element in list {
            guard let json = try? JSONSerialization.data(withJSONObject: element,
                                                         options: [.sortedKeys, .fragmentsAllowed]) else {
                throw VaultError.unreadableFile
            }
            if let entry = try? decoder.decode(VaultLegacyFormat.Entry.self, from: json).entry {
                records.entries.append(entry)
                keep(entry, from: element)
            } else {
                records.newer.append(json)
            }
        }
        return records
    }

    /// Records from a list of stored JSON objects, one by one: what ``openRecords(_:with:)``
    /// does once the file is open, for a backup's `entries` too.
    static func records(fromList list: [Any]) -> VaultRecords {
        var records = VaultRecords()
        let decoder = jsonDecoder(), encoder = jsonEncoder()
        for element in list {
            guard let json = try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys, .fragmentsAllowed]) else { continue }
            guard let entry = try? decoder.decode(VaultLegacyFormat.Entry.self, from: json).entry else {
                records.newer.append(json)
                continue
            }
            records.entries.append(entry)
            records.laterFields[entry.id] = laterFields(of: element, known: VaultLegacyFormat.Entry.storedKeys)
            if let ours = try? JSONSerialization.jsonObject(with: encoder.encode(VaultLegacyFormat.Entry(entry))) as? NSDictionary,
               let theirs = element as? NSDictionary, ours != theirs {
                records.stored[entry.id, default: []].append(VaultRecords.StoredRecord(entry: entry, json: inEncoderOrder(json)))
            }
        }
        return records
    }

    /// `json` with its keys in the order this app's encoder writes them (``jsonEncoder()``), so a
    /// record kept as stored goes back in the bytes it was written in: `JSONSerialization` sorts
    /// `notFields` after `note`, the encoder before it. As it is when it holds what the encoder
    /// would write otherwise.
    static func inEncoderOrder(_ json: Data) -> Data {
        guard let value = try? jsonDecoder().decode(StoredJSON.self, from: json),
              let encoded = try? jsonEncoder().encode(value) else { return json }
        return encoded
    }

    /// Any JSON value, read and written again as it was.
    private enum StoredJSON: Codable {
        case null, bool(Bool), integer(Int64), number(Double), string(String), array([StoredJSON]), object([String: StoredJSON])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let value = try? c.decode(Bool.self) { self = .bool(value) }
            else if let value = try? c.decode(Int64.self) { self = .integer(value) }
            else if let value = try? c.decode(Double.self) { self = .number(value) }
            else if let value = try? c.decode(String.self) { self = .string(value) }
            else if let value = try? c.decode([StoredJSON].self) { self = .array(value) }
            else { self = .object(try c.decode([String: StoredJSON].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let value): try c.encode(value)
            case .integer(let value): try c.encode(value)
            case .number(let value): try c.encode(value)
            case .string(let value): try c.encode(value)
            case .array(let value): try c.encode(value)
            case .object(let value): try c.encode(value)
            }
        }
    }

    /// The fields of a stored object outside `known`, as a JSON object; nil when there are none.
    static func laterFields(of element: Any, known: Set<String>) -> Data? {
        guard let object = element as? [String: Any] else { return nil }
        let later = object.filter { !known.contains($0.key) }
        guard !later.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: later, options: [.sortedKeys])
    }

    /// `encoded`, a JSON object, with `later`'s fields added where this build wrote none of its
    /// own. Unchanged without them.
    ///
    /// `whereOursIsEmpty`: `later`'s value also replaces one of this build's own that is empty (a
    /// field it could not read, which it holds as empty until the user sets it).
    static func merging(_ encoded: Data, _ later: Data?, whereOursIsEmpty: Bool = false) throws -> Data {
        guard let later,
              let extra = try JSONSerialization.jsonObject(with: later) as? [String: Any],
              var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        object.merge(extra) { own, theirs in
            guard whereOursIsEmpty else { return own }
            // A dictionary: what was stored, with what this build holds over it key by key, so
            // setting one name here does not drop the rest a later build wrote.
            if let ours = own as? [String: Any], let stored = theirs as? [String: Any] {
                return stored.merging(ours) { _, mine in mine }
            }
            return own is NSNull ? theirs : own
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Read Documents' file: the same sealing under its own marker, so neither file opens as the
    /// other.
    static let readingMarker = Data("SCVREAD1".utf8)

    static func seal<T: Encodable>(_ value: T, marker: Data, with key: SymmetricKey) throws -> Data {
        try sealPlain(try jsonEncoder().encode(value), marker: marker, with: key)
    }

    static func open<T: Decodable>(_ type: T.Type, _ data: Data, marker: Data, with key: SymmetricKey) throws -> T {
        let plain = try openPlain(data, marker: marker, with: key)
        guard let value = try? jsonDecoder().decode(T.self, from: plain) else {
            throw VaultError.unreadableFile
        }
        return value
    }

    /// The JSON inside a sealed file, for the format tests (``VaultFormatTests``).
    static func openPlain(_ data: Data, marker: Data, with key: SymmetricKey) throws -> Data {
        guard data.count > marker.count, data.prefix(marker.count) == marker,
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(marker.count)) else {
            throw VaultError.unreadableFile
        }
        guard let plain = try? AES.GCM.open(box, using: key, authenticating: marker) else {
            throw VaultError.wrongKeyOrDamaged
        }
        return plain
    }

    /// Seals JSON as it is, for ``seal(_:with:)`` and the format tests.
    static func sealPlain(_ plain: Data, marker: Data, with key: SymmetricKey) throws -> Data {
        guard let sealed = try AES.GCM.seal(plain, using: key, authenticating: marker).combined else {
            throw VaultError.notWritten
        }
        return marker + sealed
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A file's size and whether it begins with a Vault marker, for a log line about a file that
    /// did not open. Never its bytes past the marker: a stray file could hold anything.
    static func summary(of data: Data) -> String {
        let head = data.prefix(8)
        let known = [marker, readingMarker].contains(head)
        let shaped = head.count == 8 && head.starts(with: Data("SCV".utf8))
            && head.allSatisfy { (0x20...0x7e).contains($0) }
        let begins = known || shaped ? "begins \(String(decoding: head, as: UTF8.self))" : "no Vault marker"
        return "\(data.count) bytes, \(begins)"
    }
}

/// Reads and writes the sealed file with the Keychain's key.
///
/// The rule that shapes every branch: **never write over a file this Mac cannot open.** A missing
/// or refused key with a file on disk is an error to show, not an empty Vault to start filling.
public struct VaultStore {
    public let fileURL: URL
    private let keychain: KeychainStore
    private let fileManager: FileManager
    /// When a backup is made, for its name.
    private let clock: () -> Date
    /// Whether a load may migrate the v1 files to the v7.2 document (``VaultMigration``): the gate,
    /// ``VaultMigration/enabled``, unless a test says otherwise. Off, nothing new is ever written:
    /// the v1 files open and save as before, and a Vault begun here is a v1 Vault.
    public let migrating: Bool
    /// How long a write waits for another copy's hold on the Vault's lock before it is refused.
    /// Longer only in a test, whose waits a loaded Mac can stretch past five seconds.
    var lockWait: TimeInterval = 5
    /// Whether another copy of the app is running, which a migration waits for
    /// (``VaultMigration/anotherCopyRunning()``).
    let anotherCopyRunning: @Sendable () -> Bool

    /// How many sealed files from before a save are kept beside the Vault's, newest first (VT20).
    public static let backupsKept = 10
    /// Beyond those, the first backup made on each of this many most recent days with backups: one
    /// busy session of saves cannot push every older copy out (owner, 2026-11-23).
    public static let dailyBackupDays = 30

    public init(fileURL: URL, keychain: KeychainStore = SecItemKeychainStore(),
                fileManager: FileManager = .default, clock: @escaping () -> Date = Date.init,
                migrating: Bool? = nil,
                anotherCopyRunning: @escaping @Sendable () -> Bool = VaultMigration.anotherCopyRunning) {
        self.fileURL = fileURL
        self.keychain = keychain
        self.fileManager = fileManager
        self.clock = clock
        // Resolved here, not as the default argument: a default is evaluated in the caller, whose
        // cached build would keep the gate's old value (docs/flaky-tests.md, "a stale default").
        self.migrating = migrating ?? VaultMigration.enabled
        self.anotherCopyRunning = anotherCopyRunning
    }

    /// `~/Library/Application Support/SyncCloud/vault.sealed`. Not under a filing profile: the
    /// numbers are the household's, whichever folder tree is being filed.
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("SyncCloud/vault.sealed")
    }

    /// Whether a sealed file is on disk, asked without the key: the panel's first question, and
    /// one that must not raise a Keychain prompt.
    public var hasFile: Bool { fileManager.fileExists(atPath: fileURL.path) }

    /// Every entry, or `[]` when nothing has been saved yet. No key is made by reading.
    public func load() throws -> [VaultEntry] {
        try loadRecords().entries
    }

    /// Every record, those a later build wrote included, or none when nothing has been saved yet.
    /// A file that does not open is logged, with its size and marker only, and thrown.
    public func loadRecords() throws -> VaultRecords {
        try loadRecordsAndState().records
    }

    /// ``loadRecords()``, and the file as it was read, for a save to expect (VT108).
    public func loadRecordsAndState() throws -> (records: VaultRecords, onDisk: VaultFileState) {
        guard hasFile else { return (VaultRecords(), .absent) }
        guard let data = fileManager.contents(atPath: fileURL.path) else {
            Logger.shared.warning("Vault: the sealed file is there but could not be read from disk")
            throw VaultError.unreadableFile
        }
        let key: SymmetricKey
        switch VaultKeychain.read(from: keychain) {
        case .found(let found): key = found
        case .notCreated:
            Logger.shared.warning("Vault: the sealed file (\(VaultFile.summary(of: data))) has no key in this Mac's Keychain — it is left as it is")
            throw VaultError.keyMissing
        case .unreadable(let status): throw VaultError.keyUnreadable(status)
        }
        do {
            let records = try VaultFile.openRecords(data, with: key)
            if !records.newer.isEmpty {
                Logger.shared.warning("Vault: \(records.newer.count) record(s) in the sealed file need a newer SyncCloud — kept as they are")
            }
            return (records, .of(data))
        } catch let error as VaultError {
            Logger.shared.warning("Vault: the sealed file did not open (\(error), \(VaultFile.summary(of: data))) — it is left as it is")
            throw error
        }
    }

    /// Seals `entries` and swaps the file in whole, after keeping the file it replaces as a backup.
    ///
    /// A key is made only for the very first save, when there is neither key nor file. With a file
    /// on disk and no key, this throws: that file belongs to a key this Mac does not have. So does
    /// a file on disk this Mac cannot open: it is never written over.
    ///
    /// Records a later build wrote go back on disk with `entries`, untouched. A save that would
    /// remove more than one record at once throws ``VaultError/wouldDrop(_:)``: nothing in the
    /// app removes more than one, so a short list is a mistake,
    /// and one that cannot be undone, since a typed number is in no document to read again.
    ///
    /// `newer`: records a later build wrote that arrive with this save (a backup restored), kept
    /// with those already on disk.
    ///
    /// `carrying`: records as a backup stored them, whose later fields go back with the entries
    /// they belong to.
    ///
    /// `expecting`: the file as the saving copy of the app last saw it. One that no longer matches
    /// was saved by another SyncCloud meanwhile, and is not written over (VT108). Nil checks
    /// nothing: a restore writes what it was asked to.
    ///
    /// Answers the file as it now is, for the next save to expect.
    @discardableResult
    public func save(_ entries: [VaultEntry], newer: [Data] = [],
                     carrying: VaultRecords? = nil, expecting: VaultFileState? = nil) throws -> VaultFileState {
        // Gone since it was read: another copy set it aside or replaced it. Asked before a key is
        // made; the file read below is compared too, as it is the one this save writes over.
        if let expecting, expecting != .absent, !hasFile { throw changedElsewhere() }
        let (key, made) = try keyMadeForWriting()
        var records = VaultRecords(entries: entries, newer: newer)
        if let carrying {
            let ids = Set(entries.map(\.id))
            records.laterFields = carrying.laterFields.filter { ids.contains($0.key) }
            records.stored = carrying.stored.filter { ids.contains($0.key) }
        }
        var previous: Data?
        if hasFile {
            guard let data = fileManager.contents(atPath: fileURL.path) else {
                Logger.shared.warning("Vault: the sealed file is there but could not be read from disk — nothing was written")
                throw VaultError.unreadableFile
            }
            // The very bytes merged and written over below: one read, so another copy's save
            // cannot land between the check and what this save keeps.
            if let expecting, expecting != .of(data) { throw changedElsewhere() }
            let onDisk: VaultRecords
            do {
                onDisk = try VaultFile.openRecords(data, with: key)
            } catch let error as VaultError {
                Logger.shared.warning("Vault: the sealed file did not open (\(error), \(VaultFile.summary(of: data))) — nothing was written over it")
                throw error
            }
            records.newer = onDisk.newer + newer.filter { !onDisk.newer.contains($0) }
            records.laterFields.merge(onDisk.laterFields.filter { id, _ in entries.contains { $0.id == id } }) { mine, _ in mine }
            records.stored.merge(onDisk.stored) { mine, theirs in mine + theirs }
            // IDs, not records: two records sharing an id (Add Missing made them until 5e33b3c47)
            // go together when that ID is removed, and that is one removal.
            let dropped = Set(onDisk.entries.map(\.id)).subtracting(entries.map(\.id)).count
            if dropped > 1 {
                Logger.shared.warning("Vault: a save would have removed \(dropped) records at once (\(onDisk.entries.count) → \(entries.count)) — refused, nothing was written")
                throw VaultError.wouldDrop(dropped)
            }
            previous = data
        }
        let sealed: Data
        do {
            sealed = try VaultFile.seal(records, with: key)
            if let previous { try keepBackup(of: previous) }
            try SealedFile.write(sealed, to: fileURL, fileManager: fileManager)
        } catch {
            Logger.shared.warning("Vault: the sealed file could not be written — \(error.localizedDescription)")
            // A key made for this save, with nothing sealed under it, goes again, and what was
            // set aside for it comes back: a Mac whose key was lost still says so, rather than
            // holding a new key beside a file sealed with the old one.
            if let made {
                VaultKeychain.delete(from: keychain)
                // Only once the key is gone: files sealed under the lost key never go back beside
                // a new one, where the next save would write over them.
                if case .notCreated = VaultKeychain.read(from: keychain) { putBack(made) }
            }
            throw VaultError.notWritten
        }
        // Only once the new file is in: a save that keeps failing must not rotate the older
        // backups away.
        pruneBackups()
        return .of(sealed)
    }

    private func changedElsewhere() -> VaultError {
        Logger.shared.warning("Vault: the sealed file changed since it was read here — another SyncCloud saved it; nothing was written over it")
        return .changedElsewhere
    }

    // MARK: Backups

    private static let backupPrefix = "vault-backup-"
    private static let backupSuffix = ".sealed"
    /// Digits in a backup's count, which leads its name so names sort as the saves were made.
    private static let backupCountWidth = 8

    /// The sealed files kept from before each save, newest first. Each opens with the key the
    /// Vault had when it was made.
    public var backups: [URL] {
        let folder = fileURL.deletingLastPathComponent()
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { Self.isBackupName($0) }
            .sorted { (Self.backupCount($0), $0) > (Self.backupCount($1), $1) }
            .map { folder.appendingPathComponent($0) }
    }

    /// A name this store gave a backup: `vault-backup-<8-digit count>-…` or, from before counts,
    /// `vault-backup-<yyyyMMdd>T…`. Anything else under the prefix is not one, and is never pruned.
    /// The whole name, not its start: a Finder or iCloud copy (`… 2.sealed`) is not one.
    private static func isBackupName(_ name: String) -> Bool {
        name.wholeMatch(of: backupName) != nil || name.wholeMatch(of: backupNameBeforeCounts) != nil
    }
    nonisolated(unsafe) private static let backupName = /vault-backup-[0-9]{8}-[0-9]{8}T[0-9]{6}\.[0-9]{3}Z\.sealed/
    nonisolated(unsafe) private static let backupNameBeforeCounts = /vault-backup-[0-9]{8}T[0-9]{6}\.[0-9]{3}Z-[0-9]{3}\.sealed/

    /// A backup's count, which only grows: one more than the highest before it, whatever the
    /// clock says. Zero for a name from before counts (`vault-backup-<time>-NNN.sealed`, written
    /// by `deb831324`), so those sort as the oldest, among themselves by name.
    private static func backupCount(_ name: String) -> Int {
        let rest = name.dropFirst(backupPrefix.count)
        let digits = rest.prefix(backupCountWidth)
        guard digits.count == backupCountWidth, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              rest.dropFirst(backupCountWidth).first == "-" else { return 0 }
        return Int(digits) ?? 0
    }

    /// A backup's time in its name, in UTC to the millisecond: `20261121T174512.345Z`. Only for
    /// reading: the count before it is what orders them.
    private static let backupStamp = Date.ISO8601FormatStyle(
        dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted,
        timeZoneSeparator: .omitted, includingFractionalSeconds: true, timeZone: .gmt)

    /// Writes `data`, the file a save replaces, as the newest backup,
    /// `vault-backup-<count>-<time>.sealed`, owner-only. Not when the newest backup already holds
    /// these bytes: a save that failed after its backup and is tried again keeps one copy, not
    /// one per try. A backup that cannot be written stops the save: the file on disk is then still
    /// the only good copy.
    private func keepBackup(of data: Data) throws {
        let kept = backups
        if let newest = kept.first, fileManager.contents(atPath: newest.path) == data { return }
        let count = (kept.map { Self.backupCount($0.lastPathComponent) }.max() ?? 0) + 1
        let name = Self.backupPrefix + String(format: "%0\(Self.backupCountWidth)d", count) + "-"
            + clock().formatted(Self.backupStamp) + Self.backupSuffix
        try SealedFile.write(data, to: fileURL.deletingLastPathComponent().appendingPathComponent(name),
                             fileManager: fileManager)
    }

    /// Keeps the Vault's file as it stands as the newest backup, when it opens with this Mac's
    /// key: what Restore ▸ Replace does before it sets the file aside, so Go Back can return to
    /// the Vault as it was just before. Nothing when there is no file or it does not open.
    func keepBackupOfCurrent() {
        guard let data = fileManager.contents(atPath: fileURL.path),
              case .found(let key) = VaultKeychain.read(from: keychain),
              (try? VaultFile.openRecords(data, with: key)) != nil
                || (try? VaultFile.openPlain(data, marker: VaultDocument.marker, with: key)) != nil else { return }
        // Not pruned here: a Replace that then fails puts the Vault back, and must not have cost
        // the oldest backup. The save that follows prunes, once it is in.
        do {
            try keepBackup(of: data)
        } catch {
            Logger.shared.warning("Vault: the Vault could not be kept as a backup before it was replaced — \(error.localizedDescription)")
        }
    }

    /// Lets go of all but the newest ``backupsKept`` and, for each of the ``dailyBackupDays`` most
    /// recent days that have backups (by this Mac's calendar), the first backup made that day: the
    /// Vault as the day began, which a busy day's saves would otherwise push out. The days are the
    /// newest backups' days, not a window around today's date, so a clock off by years (a reset
    /// one, or one set ahead and put right) costs no backup: a wrong day is one of the thirty until
    /// thirty days of saves come after it. A backup whose time cannot be read is kept only among
    /// the newest.
    private func pruneBackups() {
        let all = backups
        guard all.count > Self.backupsKept else { return }
        let calendar = Calendar.current
        let made = all.map { Self.backupTime($0.lastPathComponent).map(calendar.startOfDay(for:)) }
        var recent: [Date] = []
        for case let day? in made where !recent.contains(day) && recent.count < Self.dailyBackupDays {
            recent.append(day)
        }
        var keep = Set(all.prefix(Self.backupsKept))
        var days: Set<Date> = []
        // Oldest first, so the first of a day is the one made as it began.
        for (backup, day) in zip(all, made).reversed() {
            if let day, recent.contains(day), days.insert(day).inserted { keep.insert(backup) }
        }
        for old in all where !keep.contains(old) { try? fileManager.removeItem(at: old) }
    }

    /// When a backup was made, from its name: `…-20261121T174512.345Z.sealed`, or the older
    /// `vault-backup-20261121T174512.345Z-001.sealed`.
    static func backupTime(_ name: String) -> Date? {
        guard name.hasPrefix(backupPrefix) else { return nil }
        let rest = name.dropFirst(backupPrefix.count)
        let stamp = backupCount(name) > 0 ? rest.dropFirst(backupCountWidth + 1).prefix(20) : rest.prefix(20)
        return try? Date(String(stamp), strategy: backupStamp)
    }

    // MARK: Read Documents' file

    /// `vault-reading.sealed`, beside the Vault's file.
    public var readingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("vault-reading.sealed")
    }

    /// What opening Read Documents' file found.
    public enum ReadingLoad: Equatable {
        /// No file: a fresh start.
        case none
        /// A file is there and cannot be opened right now (the Keychain withholds the key, or the
        /// disk the file): nothing may be sealed over it until it can be.
        case keyRefused
        case loaded(VaultReadingState)
        /// A file is there and did not open: damaged, a later build's, or sealed with a key this
        /// Mac no longer has.
        /// What was waiting the next read finds again. The name corrections and Kind lessons it
        /// held are the user's own and no read brings them back, so the file is set aside
        /// (``setAsideReading()``), never written over or removed.
        case damaged

        /// The state, when one opened.
        public var state: VaultReadingState? {
            if case .loaded(let state) = self { return state }
            return nil
        }
    }

    /// Whether the Vault's key is in the Keychain now. Never makes one.
    public var hasKey: Bool {
        if case .found = VaultKeychain.read(from: keychain) { return true }
        return false
    }

    /// Whether Read Documents' file is on disk, asked without the key.
    public var hasReadingFile: Bool { fileManager.fileExists(atPath: readingURL.path) }

    /// What Read Documents kept, or nil when there is none or it did not open.
    public func loadReading() -> VaultReadingState? { openReading().state }

    /// What Read Documents kept. A file that does not open is logged with its size and marker
    /// only, and the panel goes on without it; ``setAsideReading()`` then keeps it out of the next
    /// save's way.
    ///
    /// A file with no key to open it is ``ReadingLoad/damaged`` too, not a fresh start: a fresh
    /// start's first save would make a new key and write over it. A key the Keychain will not give
    /// right now is ``ReadingLoad/keyRefused``: it may give it later in the same run, and an empty
    /// state sealed then would write over the file.
    public func openReading() -> ReadingLoad { openReadingAndState().load }

    /// ``openReading()``, and the file as it was read, for a seal to expect (VT111).
    public func openReadingAndState() -> (load: ReadingLoad, onDisk: VaultFileState) {
        let data = fileManager.contents(atPath: readingURL.path)
        return (openReading(data), .of(data))
    }

    private func openReading(_ data: Data?) -> ReadingLoad {
        guard let data else {
            guard hasReadingFile else { return .none }
            // Held, not set aside: a refused read can pass, and the next open tries again.
            Logger.shared.warning("Vault: the reading file is there but could not be read from disk — nothing is sealed over it")
            return .keyRefused
        }
        let key: SymmetricKey
        switch VaultKeychain.read(from: keychain) {
        case .found(let found): key = found
        case .unreadable: return .keyRefused
        case .notCreated:
            Logger.shared.warning("Vault: the reading file (\(VaultFile.summary(of: data))) has no key in this Mac's Keychain")
            return .damaged
        }
        do {
            let plain = try VaultFile.openPlain(data, marker: VaultFile.readingMarker, with: key)
            guard var state = try? VaultFile.jsonDecoder().decode(VaultReadingState.self, from: plain) else {
                throw VaultError.unreadableFile
            }
            let object = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
            state.laterFields = object.flatMap { VaultFile.laterFields(of: $0, known: VaultReadingState.storedKeys) }
            // The user's own fields, read key by key: each this build can read is loaded, and only
            // those it cannot (a later build's shape) are kept as stored, to be sealed back. So a
            // name set here beside one in a later shape still reads at the next open.
            var unread: [String: Any] = [:]
            if let stored = object?["names"] as? [String: Any] {
                var readable: [String: String] = [:], later: [String: Any] = [:]
                for (key, value) in stored { if let name = value as? String { readable[key] = name } else { later[key] = value } }
                state.names = readable
                if !later.isEmpty { unread["names"] = later }
            }
            if let stored = object?["nameRoles"] as? [String: Any] {
                let decoder = VaultFile.jsonDecoder()
                var readable: [String: VaultNameRoles] = [:], later: [String: Any] = [:]
                for (key, value) in stored {
                    if let json = try? JSONSerialization.data(withJSONObject: value),
                       let roles = try? decoder.decode(VaultNameRoles.self, from: json) { readable[key] = roles } else { later[key] = value }
                }
                state.nameRoles = readable.isEmpty ? nil : readable
                if !later.isEmpty { unread["nameRoles"] = later }
            }
            if let stored = object?["contacts"] as? [String: Any] {
                let decoder = VaultFile.jsonDecoder()
                var readable: [String: VaultContacts] = [:], later: [String: Any] = [:]
                for (key, value) in stored {
                    if let json = try? JSONSerialization.data(withJSONObject: value),
                       let contacts = try? decoder.decode(VaultContacts.self, from: json) { readable[key] = contacts } else { later[key] = value }
                }
                state.contacts = readable.isEmpty ? nil : readable
                if !later.isEmpty { unread["contacts"] = later }
            }
            state.unreadFields = unread.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: unread, options: [.sortedKeys])
            return .loaded(state)
        } catch {
            Logger.shared.warning("Vault: the reading file did not open (\(error), \(VaultFile.summary(of: data)))")
            return .damaged
        }
    }

    /// Renames a reading file that did not open (``ReadingLoad/damaged``) to
    /// `vault-reading.sealed.unreadable-<stamp>`, a name of its own per episode
    /// (``UnreadableSetAside``), so the next save does not write over it. Never deletes it. Nil
    /// when there was nothing to move or the move failed: then the caller must not seal.
    @discardableResult
    public func setAsideReading() -> URL? {
        guard fileManager.fileExists(atPath: readingURL.path) else { return nil }
        let aside = UnreadableSetAside.destination(for: readingURL, at: clock(), fileManager: fileManager)
        do {
            try fileManager.moveItem(at: readingURL, to: aside)
        } catch {
            Logger.shared.warning("Vault: the reading file that did not open could not be set aside — \(error.localizedDescription)")
            return nil
        }
        Logger.shared.info("Vault: the reading file that did not open was set aside as \(aside.lastPathComponent)")
        return aside
    }

    /// Seals Read Documents' state. Makes the key on a Mac that has neither key nor Vault file,
    /// as a first read before any number is added needs.
    /// What a later build stored in it (``VaultReadingState/laterFields``) goes back with it.
    ///
    /// `expecting`: the file as the sealing copy of the app last saw it. One that no longer matches
    /// was sealed by another SyncCloud meanwhile, and is not written over (VT111): the caller
    /// merges what that one holds and seals again. Nil checks nothing: a restore writes what it
    /// was asked to.
    ///
    /// Answers the file as it now is, for the next seal to expect.
    @discardableResult
    public func saveReading(_ state: VaultReadingState, expecting: VaultFileState? = nil) throws -> VaultFileState {
        let plain = try VaultFile.merging(VaultFile.merging(VaultFile.jsonEncoder().encode(state), state.laterFields),
                                          state.unreadFields, whereOursIsEmpty: true)
        let sealed = try VaultFile.sealPlain(plain, marker: VaultFile.readingMarker, with: try keyForWriting())
        // Asked last, just before the write: the window another copy's seal can land in is the
        // write itself.
        if let expecting {
            let now = fileManager.contents(atPath: readingURL.path)
            // There and unreadable is not a change; the write below says whether it can go.
            if !(now == nil && hasReadingFile), VaultFileState.of(now) != expecting {
                Logger.shared.warning("Vault: the reading file changed since it was read here — another SyncCloud sealed it; nothing was written over it")
                throw VaultError.changedElsewhere
            }
        }
        do {
            try SealedFile.write(sealed, to: readingURL, fileManager: fileManager)
        } catch {
            Logger.shared.warning("Vault: the reading file could not be written — \(error.localizedDescription)")
            throw VaultError.notWritten
        }
        return .of(sealed)
    }

    /// The key, made here only when there is neither key nor file. With a file on disk and no
    /// key, this throws: that file belongs to a key this Mac does not have.
    ///
    /// Files a lost key sealed that are not the Vault's own (what was read, the activity list,
    /// the backups kept before each save) are set aside before a new key is made: under it they
    /// would be written over or pruned, and they are kept for the day their key turns up.
    private func keyForWriting() throws -> SymmetricKey { try keyMadeForWriting().key }

    /// ``keyForWriting()``, and, when it made the key just now, the files it set aside for it.
    private func keyMadeForWriting() throws -> (key: SymmetricKey, made: [Aside]?) {
        switch VaultKeychain.read(from: keychain) {
        case .found(let found): return (found, nil)
        case .unreadable(let status): throw VaultError.keyUnreadable(status)
        case .notCreated:
            guard !hasFile else { throw VaultError.keyMissing }
            let leftovers = [readingURL, activityURL, cacheURL] + backups
            var moved: [Aside] = []
            if leftovers.contains(where: { fileManager.fileExists(atPath: $0.path) }) {
                guard let aside = moveAside(leftovers, at: clock()) else { throw VaultError.notWritten }
                moved = aside
                Logger.shared.warning("Vault: \(moved.count) sealed file(s) with no key in this Mac's Keychain were set aside before a new key was made")
            }
            switch VaultKeychain.create(in: keychain) {
            case .success(let key): return (key, moved)
            case .failure(let error):
                // No new key, so nothing to keep them from: back where they were. Unless another
                // caller made one meanwhile: then they stay aside, out of its way.
                if case .found = VaultKeychain.read(from: keychain) {} else { putBack(moved) }
                throw error
            }
        }
    }

    /// `vault-activity.sealed`, beside the Vault's file (``VaultActivityStore``).
    public var activityURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("vault-activity.sealed")
    }

    // MARK: Setting aside

    /// A file set aside: where it was, and where it is now.
    struct Aside: Equatable {
        let from: URL
        let to: URL
    }

    /// Set It Aside and Start New, for a Vault this Mac cannot open: renames the Vault's file,
    /// what was read, the reading cache, and the backups kept before each save aside
    /// (`vault.sealed.set-aside-<stamp>`). Nothing is deleted, so it is all kept, history and all,
    /// for the day it can be opened; the backups may be the only readable copies of a damaged
    /// file, and the new Vault's saves would prune them. The activity list stays: one this Mac
    /// cannot open is set aside by its next entry. True when no sealed file is left in the way.
    @discardableResult
    public func setAside(at date: Date = Date()) -> Bool {
        moveAside([fileURL, readingURL, cacheURL] + backups, at: date) != nil
    }

    /// What Restore ▸ Replace moves: the Vault's file, what was read and its cache. The backups and the
    /// activity list stay, still this Mac's under the same key, and Go Back reaches past the
    /// Replace (``keepBackupOfCurrent()`` keeps the Vault as it was just before); under a lost
    /// key, ``keyForWriting()`` sets them aside before it makes a new one. Nil when a file could
    /// not be moved; what did move is put back first.
    func moveAsideForReplace(at date: Date) -> [Aside]? {
        moveAside([fileURL, readingURL, cacheURL], at: date)
    }

    /// Renames each of `urls` that is there to `<name>.set-aside-<stamp>`; all or none.
    func moveAside(_ urls: [URL], at date: Date) -> [Aside]? {
        let stamp = Int(date.timeIntervalSince1970)
        var moved: [Aside] = []
        for url in urls where fileManager.fileExists(atPath: url.path) {
            var aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).set-aside-\(stamp)")
            var copy = 1
            while fileManager.fileExists(atPath: aside.path) {
                copy += 1
                aside = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).set-aside-\(stamp)-\(copy)")
            }
            do {
                try fileManager.moveItem(at: url, to: aside)
                moved.append(Aside(from: url, to: aside))
            } catch {
                Logger.shared.warning("Vault: a sealed file could not be set aside — \(error.localizedDescription)")
                putBack(moved)
                return nil
            }
        }
        return moved
    }

    /// Puts files set aside back where they were. A file written there meanwhile (half of a save
    /// that failed) is replaced: what was set aside is the Vault.
    func putBack(_ moved: [Aside]) {
        for aside in moved {
            do {
                if fileManager.fileExists(atPath: aside.from.path) { try fileManager.removeItem(at: aside.from) }
                try fileManager.moveItem(at: aside.to, to: aside.from)
            } catch {
                Logger.shared.warning("Vault: a sealed file set aside could not be put back — \(error.localizedDescription)")
            }
        }
    }

    /// A number's fingerprint under this Mac's Vault key: HMAC-SHA256 of its letters and digits.
    ///
    /// What the Vault keeps outside the sealed file to remember a number without holding it, such
    /// as one set aside from To Confirm. A plain hash would not do: a passport number has few
    /// enough possibilities to try them all, and without the key there is nothing to test a guess
    /// against. Nil when the key cannot be had. `makingKey` makes the key on a Mac that has
    /// neither key nor file, as remembering a number needs; checking one never makes it.
    public func fingerprint(_ value: String, makingKey: Bool = false) -> String? {
        let key: SymmetricKey
        if makingKey {
            guard let made = try? keyForWriting() else { return nil }
            key = made
        } else {
            guard case .found(let found) = VaultKeychain.read(from: keychain) else { return nil }
            key = found
        }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(VaultReading.normalized(value).utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The v7.2 document (VT6)

extension VaultStore {
    /// `vault-cache.sealed`, beside the Vault's file: what reading can find again (``VaultCache``).
    public var cacheURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("vault-cache.sealed")
    }

    /// `vault.lock`, beside the Vault's file: the advisory lock a document save takes around its
    /// check of the file and its swap, so two copies of the app cannot both pass the check.
    public var lockURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("vault.lock")
    }

    /// Which Vault file is on disk, by its marker, asked without the key.
    public enum FileFormat: Equatable, Sendable {
        case none
        /// `SCVAULT1`: the array of entries every build before 7.2 wrote.
        case v1
        /// `SCVAULT2`: the v7.2 document.
        case document
        /// Neither: damaged, or not a Vault file. Opened as v1 is, which says it does not open.
        case unknown
    }

    public var fileFormat: FileFormat {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else { return hasFile ? .unknown : .none }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8)) ?? Data()
        if head == VaultLegacyFormat.vaultMarker { return .v1 }
        if head == VaultDocument.marker { return .document }
        return .unknown
    }

    /// Whether this store keeps the Vault as a document: one is on disk, or, with the migration
    /// on, nothing is yet. With it off, a Vault begun here is a v1 Vault, as before 7.2.
    /// Whether the moved keys in `defaults` (``VaultMigration/movedKeys``) are this Vault's to take
    /// in and remove. The app's own preferences belong to the Vault in Application Support alone: a
    /// store over any other file, such as a test's inside the app's test host, which runs with the
    /// owner's preferences, never reads them for a migration and never removes them.
    public func ownsMovedKeys(in defaults: UserDefaults) -> Bool {
        guard defaults === UserDefaults.standard else { return true }
        guard let real = Self.defaultURL(fileManager: fileManager) else { return false }
        return fileURL.standardizedFileURL.path == real.standardizedFileURL.path
    }

    public var keepsDocument: Bool {
        switch fileFormat {
        case .document: return true
        // A v1 reading file and no Vault file is still a v1 Vault: one the migration refused
        // opens as one, never as an empty document that would leave the file behind.
        case .none: return migrating && !hasReadingFile
        case .v1, .unknown: return false
        }
    }

    /// Whether a load should migrate (``migrate(defaults:people:folders:)``): the migration is on,
    /// and the Vault's file is v1, or it is missing while the reading file or a moved UserDefaults
    /// key is there.
    public func needsMigration(defaults: UserDefaults) -> Bool {
        guard migrating, ownsMovedKeys(in: defaults) else { return false }
        switch fileFormat {
        case .v1: return true
        case .none: return hasReadingFile || VaultMigration.movedKeys.contains { defaults.object(forKey: $0) != nil }
        case .document, .unknown: return false
        }
    }

    // MARK: Reading

    /// What opening the document gave: it, what reading can find again (nil when there is none, or
    /// it did not open and was set aside), and the file as read, for a save to expect.
    public struct DocumentLoad: Equatable, Sendable {
        public var document: VaultDocument
        public var cache: VaultCache?
        public var onDisk: VaultFileState
        /// A later build's format: nothing may be written (``VaultDocumentOpened/readOnly``).
        public var readOnly: Bool
        /// Records a later build wrote that this one cannot read.
        public var unread: Int
    }

    /// The document, or nil when there is no Vault file. Throws as ``loadRecords()`` does for a file
    /// that does not open, and ``VaultError/unreadableFile`` for one that is not a document.
    ///
    /// `settingCacheAside` off (a backup or restore, which reads the document only) leaves a cache
    /// that does not open where it is, for the panel's next open to deal with.
    public func loadDocument(settingCacheAside: Bool = true) throws -> DocumentLoad? {
        guard hasFile else { return nil }
        guard let data = fileManager.contents(atPath: fileURL.path) else {
            Logger.shared.warning("Vault: the sealed file is there but could not be read from disk")
            throw VaultError.unreadableFile
        }
        let key = try readKey(for: data)
        let opened: VaultDocumentOpened
        do {
            opened = try VaultDocument.open(plain: VaultFile.openPlain(data, marker: VaultDocument.marker, with: key))
        } catch let error as VaultError {
            Logger.shared.warning("Vault: the Vault document did not open (\(error), \(VaultFile.summary(of: data))) — it is left as it is")
            throw error
        }
        if opened.document.setAside.keyID != VaultDocument.keyID(for: key) {
            Logger.shared.warning("Vault: the Vault document's set-aside numbers were made under another key; they are kept as they are")
        }
        return DocumentLoad(document: opened.document, cache: openCache(with: key, settingAside: settingCacheAside && !opened.readOnly),
                            onDisk: .of(data), readOnly: opened.readOnly, unread: opened.unread)
    }

    /// Which key this Mac's Vault is sealed under (``VaultDocument/keyID(for:)``), without the key:
    /// nil when the Keychain has none or withholds it. Never makes one.
    public var keyID: String? {
        guard case .found(let key) = VaultKeychain.read(from: keychain) else { return nil }
        return VaultDocument.keyID(for: key)
    }

    /// The key, for a file on disk: one this Mac does not have is ``VaultError/keyMissing``.
    private func readKey(for data: Data) throws -> SymmetricKey {
        switch VaultKeychain.read(from: keychain) {
        case .found(let found): return found
        case .notCreated:
            Logger.shared.warning("Vault: the sealed file (\(VaultFile.summary(of: data))) has no key in this Mac's Keychain — it is left as it is")
            throw VaultError.keyMissing
        case .unreadable(let status): throw VaultError.keyUnreadable(status)
        }
    }

    /// The cache, when it opens with `key` and is this build's. One that does not is set aside
    /// (`vault-cache.sealed.unreadable-<stamp>`) and started fresh, unless `settingAside` is off
    /// (a later build's Vault, over which nothing is written).
    func openCache(with key: SymmetricKey, settingAside: Bool) -> VaultCache? {
        guard let data = fileManager.contents(atPath: cacheURL.path) else { return nil }
        if let plain = try? VaultFile.openPlain(data, marker: VaultCache.marker, with: key),
           let cache = try? VaultFile.jsonDecoder().decode(VaultCache.self, from: plain), cache.format == VaultCache.format {
            return cache
        }
        Logger.shared.warning("Vault: the reading cache did not open (\(VaultFile.summary(of: data))); it starts fresh")
        if settingAside {
            let aside = UnreadableSetAside.destination(for: cacheURL, at: clock(), fileManager: fileManager)
            do { try fileManager.moveItem(at: cacheURL, to: aside) } catch {
                // Not in the way of anything: the next cache write replaces it.
                Logger.shared.warning("Vault: the reading cache that did not open could not be set aside — \(error.localizedDescription)")
            }
        }
        return nil
    }

    // MARK: Writing

    /// Seals `document` and swaps it in whole, after keeping the file it replaces as a backup when
    /// its saved records or the user's own data changed (``VaultDocument/sameSavedData(as:)``).
    ///
    /// As ``save(_:newer:carrying:expecting:)``: a key is made only when there is neither key nor
    /// file; a file this Mac cannot open, or a later build's document, is never written over; a save
    /// that would remove more than one saved record throws ``VaultError/wouldDrop(_:)``;
    /// `expecting` refuses a file another copy saved meanwhile (``VaultError/changedElsewhere``).
    /// The check and the swap happen under the advisory lock on ``lockURL``.
    ///
    /// The document is stamped as this build's, now, under this key (``VaultDocument/keyID(for:)``).
    /// Answers the file as it now is, and the document as written.
    ///
    /// `replacingAt`, for Restore ▸ Replace: the Vault's files are set aside (``moveAsideForReplace(at:)``)
    /// under the same lock, and put back if the save is refused, so another copy's save cannot land
    /// between the two and be taken for this one's (the final review).
    @discardableResult
    public func saveDocument(_ document: VaultDocument, expecting: VaultFileState?, replacingAt: Date? = nil) throws
        -> (onDisk: VaultFileState, document: VaultDocument) {
        if let expecting, expecting != .absent, !hasFile { throw changedElsewhere() }
        /// The check and the swap, under the lock.
        func swap(_ key: SymmetricKey) throws -> (onDisk: VaultFileState, document: VaultDocument) {
            var stamped = document
            stamped.format = VaultDocument.format
            stamped.savedBy = VaultDocument.thisBuild
            stamped.savedAt = clock()
            stamped.setAside.keyID = VaultDocument.keyID(for: key)
            var previous: Data?
            var backup = false
            if hasFile {
                guard let data = fileManager.contents(atPath: fileURL.path) else {
                    Logger.shared.warning("Vault: the sealed file is there but could not be read from disk — nothing was written")
                    throw VaultError.unreadableFile
                }
                if let expecting, expecting != .of(data) { throw changedElsewhere() }
                let onDisk: VaultDocumentOpened
                do {
                    onDisk = try VaultDocument.open(plain: VaultFile.openPlain(data, marker: VaultDocument.marker, with: key))
                } catch let error as VaultError {
                    Logger.shared.warning("Vault: the Vault document did not open (\(error), \(VaultFile.summary(of: data))) — nothing was written over it")
                    throw error
                }
                guard !onDisk.readOnly else {
                    Logger.shared.warning("Vault: the Vault was saved by a newer SyncCloud — nothing was written over it")
                    throw VaultError.unreadableFile
                }
                let dropped = onDisk.document.savedIDs.subtracting(stamped.savedIDs).count
                if dropped > 1 {
                    Logger.shared.warning("Vault: a save would have removed \(dropped) records at once (\(onDisk.document.savedIDs.count) → \(stamped.savedIDs.count)) — refused, nothing was written")
                    throw VaultError.wouldDrop(dropped)
                }
                previous = data
                backup = !onDisk.document.sameSavedData(as: stamped)
            }
            let sealed = try VaultFile.sealPlain(VaultFile.jsonEncoder().encode(stamped), marker: VaultDocument.marker, with: key)
            do {
                if backup, let previous { try keepBackup(of: previous) }
                try SealedFile.write(sealed, to: fileURL, fileManager: fileManager)
            } catch {
                Logger.shared.warning("Vault: the Vault document could not be written — \(error.localizedDescription)")
                throw VaultError.notWritten
            }
            if backup { pruneBackups() }
            return (.of(sealed), stamped)
        }

        return try withVaultLock {
            // Set aside first, so a Vault this Mac cannot open is replaced under a key made anew.
            var moved: [Aside] = []
            if let replacingAt {
                guard let aside = moveAsideForReplace(at: replacingAt) else { throw VaultError.notWritten }
                moved = aside
            }
            do {
                let (key, made) = try keyMadeForWriting()
                do { return try swap(key) } catch {
                    // As a v1 save: a key made for this save, with nothing sealed under it, goes again.
                    if let made {
                        VaultKeychain.delete(from: keychain)
                        if case .notCreated = VaultKeychain.read(from: keychain) { putBack(made) }
                    }
                    throw error
                }
            } catch {
                putBack(moved)
                throw error
            }
        }
    }

    /// The Vault's file as it is on disk now, to compare with what a model last read or wrote.
    func documentState() -> VaultFileState {
        .of(try? Data(contentsOf: fileURL))
    }

    /// The reading cache as it is on disk now: another copy's cache-only seal changes it alone.
    func cacheState() -> VaultFileState {
        .of(try? Data(contentsOf: cacheURL))
    }

    /// Seals what reading can find again. Never makes a key, and expects nothing: the cache is
    /// rebuilt by reading, so a copy's write over another's costs a read, never the user's data.
    public func saveCache(_ cache: VaultCache) throws {
        guard case .found(let key) = VaultKeychain.read(from: keychain) else { throw VaultError.notWritten }
        let sealed = try VaultFile.sealPlain(VaultFile.jsonEncoder().encode(cache), marker: VaultCache.marker, with: key)
        do {
            try SealedFile.write(sealed, to: cacheURL, fileManager: fileManager)
        } catch {
            Logger.shared.warning("Vault: the reading cache could not be written — \(error.localizedDescription)")
            throw VaultError.notWritten
        }
    }

    /// Runs `body` holding the advisory lock on ``lockURL``: another copy's document save waits
    /// for it, up to five seconds, then this one is refused as not written.
    func withVaultLock<T>(_ body: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            Logger.shared.warning("Vault: the Vault's lock file could not be opened — nothing was written")
            throw VaultError.notWritten
        }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(lockWait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                Logger.shared.warning("Vault: another SyncCloud held the Vault's lock too long — nothing was written")
                throw VaultError.notWritten
            }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    // MARK: Migrating (gated)

    /// What a migration came to.
    public enum MigrationOutcome: Equatable, Sendable {
        /// Off, or nothing to migrate.
        case notNeeded
        case migrated(VaultMigration.Report)
        /// Stopped with nothing changed: the v1 files are as they were.
        case refused(VaultMigration.Refusal)
    }

    /// The v1 files and the moved UserDefaults keys become the document, in the spec's order, each
    /// step safe to stop after:
    ///
    /// 1. the v1 Vault file is copied to `vault.sealed.v1-premigration-<stamp>`, a name outside the
    ///    backups' rotation that is never pruned, and kept as the newest backup;
    /// 2. the document is written over it, expecting its very bytes, under the Vault's lock;
    /// 3. the cache is written (a failure costs a read, nothing more);
    /// 4. the reading file is renamed `vault-reading.sealed.migrated-<stamp>`;
    /// 5. the moved keys are removed from `defaults`.
    ///
    /// Only with the migration on (``migrating``) and the key in the Keychain, and never while
    /// another copy of the app runs: it would go on writing the v1 files. Anything that does not
    /// decode, or does not check, stops it before step 1 (``VaultMigration/Refusal``). Counts are
    /// logged; never a number or a name.
    public func migrate(defaults: UserDefaults, people: [Person] = [], folders: [String] = []) -> MigrationOutcome {
        guard needsMigration(defaults: defaults) else { return .notNeeded }
        guard case .found(let key) = VaultKeychain.read(from: keychain) else { return refused(.unopened("the Vault’s key")) }
        guard !anotherCopyRunning() else { return refused(.anotherCopyRunning) }
        do {
            return try withVaultLock { () -> MigrationOutcome in
                // Read again under the lock: what is migrated is what is written over.
                guard needsMigration(defaults: defaults) else { return .notNeeded }
                let vaultData = fileFormat == .v1 ? fileManager.contents(atPath: fileURL.path) : nil
                if fileFormat == .v1, vaultData == nil { return refused(.unopened("the Vault’s file")) }
                let readingData = fileManager.contents(atPath: readingURL.path)
                if hasReadingFile, readingData == nil { return refused(.unopened("the reading file")) }
                var legacy = VaultMigration.Legacy()
                if let vaultData {
                    guard let plain = try? VaultFile.openPlain(vaultData, marker: VaultLegacyFormat.vaultMarker, with: key) else {
                        return refused(.unopened("the Vault’s file"))
                    }
                    (legacy.vaultPlain, legacy.vaultDigest) = (plain, VaultMigration.digest(vaultData))
                }
                if let readingData {
                    guard let plain = try? VaultFile.openPlain(readingData, marker: VaultLegacyFormat.readingMarker, with: key) else {
                        return refused(.unopened("the reading file"))
                    }
                    (legacy.readingPlain, legacy.readingDigest) = (plain, VaultMigration.digest(readingData))
                }
                (legacy.setAside, legacy.generation, legacy.customKinds) = VaultMigration.Legacy.values(in: defaults)
                let now = clock()
                let migrated: (document: VaultDocument, cache: VaultCache, report: VaultMigration.Report)
                do {
                    migrated = try VaultMigration.migrate(legacy, keyID: VaultDocument.keyID(for: key), people: people,
                                                          folders: folders, at: now)
                } catch let refusal as VaultMigration.Refusal {
                    return refused(refusal)
                }
                let stamp = Int(now.timeIntervalSince1970)
                // 1. A copy of its own, and the newest backup. Refused after it, the copy goes
                // again: the v1 file it copies is as it was, and a migration refused at every open
                // would otherwise leave one more full copy each time (the final review).
                let premigration = unusedURL("vault.sealed.v1-premigration-\(stamp)")
                var written = false
                defer { if !written, vaultData != nil { try? fileManager.removeItem(at: premigration) } }
                if let vaultData {
                    do {
                        try SealedFile.write(vaultData, to: premigration,
                                             fileManager: fileManager, replacing: false)
                        try keepBackup(of: vaultData)
                    } catch {
                        Logger.shared.warning("Vault: the v1 Vault could not be copied before migrating — \(error.localizedDescription); nothing was migrated")
                        return .refused(.unopened("the copy before migrating"))
                    }
                }
                // 2. The document, over the very bytes read.
                var document = migrated.document
                document.setAside.keyID = VaultDocument.keyID(for: key)
                document.savedBy = VaultDocument.thisBuild
                let sealed = try VaultFile.sealPlain(VaultFile.jsonEncoder().encode(document), marker: VaultDocument.marker, with: key)
                guard VaultFileState.of(fileManager.contents(atPath: fileURL.path)) == VaultFileState.of(vaultData) else {
                    return refused(.unopened("the Vault’s file, which changed while it was read"))
                }
                do {
                    try SealedFile.write(sealed, to: fileURL, fileManager: fileManager)
                } catch {
                    Logger.shared.warning("Vault: the migrated Vault could not be written — \(error.localizedDescription); the v1 Vault is as it was")
                    return .refused(.unopened("the write"))
                }
                written = true
                // 3. What reading finds again.
                try? saveCache(migrated.cache)
                // 4 and 5.
                finishMigration(of: document, defaults: defaults)
                Logger.shared.info("Vault: migrated to the v7.2 document: \(migrated.report)")
                return .migrated(migrated.report)
            }
        } catch {
            return refused(.unopened("the Vault’s lock, or sealing the document"))
        }
    }

    private func refused(_ refusal: VaultMigration.Refusal) -> MigrationOutcome {
        Logger.shared.warning("Vault: the v1 Vault was not migrated, \(refusal); the v1 files are as they were")
        return .refused(refusal)
    }

    /// Steps 4 and 5, which each open of a migrated document finishes: the reading file the
    /// document was made from is renamed `.migrated-<stamp>`, one that is not (it appeared since)
    /// is set aside unmerged, and the moved keys that hold only what the document already does are
    /// removed. Fingerprints in `defaults` the document lacks are left for the caller to take in
    /// (``setAsideLeftInDefaults(by:defaults:)``), then remove.
    public func finishMigration(of document: VaultDocument, defaults: UserDefaults) {
        guard migrating, ownsMovedKeys(in: defaults), let from = document.migratedFrom else { return }
        let stamp = Int(clock().timeIntervalSince1970)
        if let data = fileManager.contents(atPath: readingURL.path) {
            if VaultMigration.digest(data) == from.reading {
                do { try fileManager.moveItem(at: readingURL, to: unusedURL("vault-reading.sealed.migrated-\(stamp)")) } catch {
                    Logger.shared.warning("Vault: the migrated reading file could not be renamed — \(error.localizedDescription); the next open tries again")
                }
            } else if moveAside([readingURL], at: clock()) != nil {
                Logger.shared.warning("Vault: a reading file the document was not made from was set aside unmerged")
            }
        }
        // The kinds and the generation the document holds; fingerprints only once all are in it.
        if let stored = defaults.object(forKey: VaultKinds.key) as? Data,
           let kinds = try? JSONDecoder().decode([VaultCustomKind].self, from: stored),
           kinds.filter({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) == document.kinds {
            defaults.removeObject(forKey: VaultKinds.key)
        }
        if let generation = defaults.object(forKey: VaultSetAside.generationKey) as? Int, generation == document.setAside.generation {
            defaults.removeObject(forKey: VaultSetAside.generationKey)
        }
        if setAsideLeftInDefaults(by: document, defaults: defaults).isEmpty, defaults.object(forKey: VaultSetAside.key) != nil {
            defaults.removeObject(forKey: VaultSetAside.key)
        }
    }

    /// Set-aside fingerprints in `defaults` the document does not hold yet: left by a migration
    /// stopped before step 5, or added by an older path since. The caller takes them into the
    /// document and, once it is written, removes the key.
    public func setAsideLeftInDefaults(by document: VaultDocument, defaults: UserDefaults) -> [String] {
        guard migrating, ownsMovedKeys(in: defaults) else { return [] }
        let held = Set(document.setAside.fingerprints)
        return (defaults.stringArray(forKey: VaultSetAside.key) ?? []).filter { !held.contains($0) }
    }

    /// `name` beside the Vault's file, or `name-2`, `name-3`… when it is taken.
    private func unusedURL(_ name: String) -> URL {
        let folder = fileURL.deletingLastPathComponent()
        var url = folder.appendingPathComponent(name)
        var copy = 1
        while (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
            copy += 1
            url = folder.appendingPathComponent("\(name)-\(copy)")
        }
        return url
    }
}
