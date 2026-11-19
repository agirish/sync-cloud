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
        try seal(entries, marker: marker, with: key)
    }

    public static func open(_ data: Data, with key: SymmetricKey) throws -> [VaultEntry] {
        try open([VaultEntry].self, data, marker: marker, with: key)
    }

    /// Read Documents' file: the same sealing under its own marker, so neither file opens as the
    /// other.
    static let readingMarker = Data("SCVREAD1".utf8)

    static func seal<T: Encodable>(_ value: T, marker: Data, with key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plain = try encoder.encode(value)
        guard let sealed = try AES.GCM.seal(plain, using: key, authenticating: marker).combined else {
            throw VaultError.notWritten
        }
        return marker + sealed
    }

    static func open<T: Decodable>(_ type: T.Type, _ data: Data, marker: Data, with key: SymmetricKey) throws -> T {
        guard data.count > marker.count, data.prefix(marker.count) == marker,
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(marker.count)) else {
            throw VaultError.unreadableFile
        }
        guard let plain = try? AES.GCM.open(box, using: key, authenticating: marker) else {
            throw VaultError.wrongKeyOrDamaged
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(T.self, from: plain) else {
            throw VaultError.unreadableFile
        }
        return value
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

    public init(fileURL: URL, keychain: KeychainStore = SecItemKeychainStore(),
                fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.keychain = keychain
        self.fileManager = fileManager
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
        guard hasFile else { return [] }
        guard let data = fileManager.contents(atPath: fileURL.path) else { throw VaultError.unreadableFile }
        switch VaultKeychain.read(from: keychain) {
        case .found(let key): return try VaultFile.open(data, with: key)
        case .notCreated: throw VaultError.keyMissing
        case .unreadable(let status): throw VaultError.keyUnreadable(status)
        }
    }

    /// Seals `entries` and swaps the file in whole.
    ///
    /// A key is made only for the very first save, when there is neither key nor file. With a file
    /// on disk and no key, this throws: that file belongs to a key this Mac does not have.
    public func save(_ entries: [VaultEntry]) throws {
        let sealed = try VaultFile.seal(entries, with: try keyForWriting())
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            // `.atomic`: a crash mid-write leaves the last good file, never half of a sealed box.
            try sealed.write(to: fileURL, options: .atomic)
            // Owner-only, like the Keychain item it pairs with.
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Logger.shared.warning("Vault: the sealed file could not be written — \(error.localizedDescription)")
            throw VaultError.notWritten
        }
    }

    /// `vault-reading.sealed`, beside the Vault's file.
    public var readingURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("vault-reading.sealed")
    }

    /// What Read Documents kept, or nil when there is nothing to open: no file, no key, or a file
    /// this build cannot read. Nil is a fresh start, never an error to show; nothing in it was the
    /// user's own until confirmed.
    public func loadReading() -> VaultReadingState? {
        guard let data = fileManager.contents(atPath: readingURL.path),
              case .found(let key) = VaultKeychain.read(from: keychain) else { return nil }
        return try? VaultFile.open(VaultReadingState.self, data, marker: VaultFile.readingMarker, with: key)
    }

    /// Seals Read Documents' state. Makes the key on a Mac that has neither key nor Vault file,
    /// as a first read before any number is added needs.
    public func saveReading(_ state: VaultReadingState) throws {
        let sealed = try VaultFile.seal(state, marker: VaultFile.readingMarker, with: try keyForWriting())
        do {
            try fileManager.createDirectory(at: readingURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try sealed.write(to: readingURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readingURL.path)
        } catch {
            Logger.shared.warning("Vault: the reading file could not be written — \(error.localizedDescription)")
            throw VaultError.notWritten
        }
    }

    /// The key, made here only when there is neither key nor file. With a file on disk and no
    /// key, this throws: that file belongs to a key this Mac does not have.
    private func keyForWriting() throws -> SymmetricKey {
        switch VaultKeychain.read(from: keychain) {
        case .found(let found): return found
        case .unreadable(let status): throw VaultError.keyUnreadable(status)
        case .notCreated:
            guard !hasFile else { throw VaultError.keyMissing }
            return try VaultKeychain.create(in: keychain).get()
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
