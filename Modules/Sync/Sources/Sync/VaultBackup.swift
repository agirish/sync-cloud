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
}

/// What a backup holds: the saved IDs, and when it was made. Not what was read and is still
/// waiting to be confirmed: that is found again by reading the documents.
public struct VaultBackupContents: Codable, Equatable, Sendable {
    public var version: Int
    public var madeAt: Date
    public var entries: [VaultEntry]

    public init(version: Int = 1, madeAt: Date, entries: [VaultEntry]) {
        self.version = version
        self.madeAt = madeAt
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case version, madeAt, entries }

    /// A record a later build wrote (a kind, a place or a pin this one does not know) is passed
    /// over, so a backup still restores every record it can read rather than none (VT30).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        madeAt = try c.decode(Date.self, forKey: .madeAt)
        var list = try c.nestedUnkeyedContainer(forKey: .entries)
        var entries: [VaultEntry] = []
        var skipped = 0
        while !list.isAtEnd {
            if let entry = try? list.decode(VaultEntry.self) {
                entries.append(entry)
            } else {
                // A failed element leaves the container where it was; step past it.
                _ = try list.decode(LaterRecord.self)
                skipped += 1
            }
        }
        self.entries = entries
        laterRecords = skipped
    }

    /// How many records in the backup need a newer SyncCloud. Not encoded: a backup is written
    /// from what this build holds.
    public private(set) var laterRecords = 0

    private struct LaterRecord: Decodable {}
}

/// A backup's bytes: the Vault's IDs sealed under a key made from a passphrase, so the file opens
/// on any Mac that is given the passphrase and on none that is not.
///
/// The Vault's own file is sealed with a random key in this Mac's Keychain, which is why it
/// cannot be read anywhere else, and why a lost Mac or a reset keychain loses it. A backup trades
/// that for a secret the owner carries: `SCVBACK1`, the work factor, a random salt, then the
/// IDs sealed with AES-256-GCM under PBKDF2-HMAC-SHA256 of the passphrase. The header is
/// authenticated with the box, so a lowered work factor or a swapped salt does not open.
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
              let plain = try? VaultFile.jsonEncoder().encode(contents),
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
        guard let contents = try? VaultFile.jsonDecoder().decode(VaultBackupContents.self, from: plain) else {
            throw VaultBackupError.notABackup
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

    public init(store: VaultStore, keychain: KeychainStore = SecItemKeychainStore(),
                authenticator: VaultAuthenticating = VaultDeviceOwnerProof(), defaults: UserDefaults = .standard,
                fileManager: FileManager = .default, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.keychain = keychain
        self.authenticator = authenticator
        self.defaults = defaults
        self.fileManager = fileManager
        self.clock = clock
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
        guard isWeekly, hasPassphrase else { return false }
        guard let last = lastBackup else { return true }
        return clock().timeIntervalSince(last) >= 7 * 86_400
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
    public func setPassphrase(_ passphrase: String) throws {
        guard passphrase.count >= VaultBackupFile.leastPassphraseLength else { throw VaultBackupError.passphraseTooShort }
        keychain.delete(query())
        var item = query()
        item[kSecValueData as String] = Data(passphrase.utf8)
        item[kSecAttrLabel as String] = "SyncCloud Vault backup passphrase"
        guard keychain.add(item) == errSecSuccess else {
            Logger.shared.warning("Vault: the Keychain refused to keep the backup passphrase")
            throw VaultBackupError.notWritten
        }
    }

    // MARK: Backing up

    static func fileName(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .current, from: date)
        return String(format: "Vault Backup %04d-%02d-%02d.%@", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1,
                      VaultBackupFile.fileExtension)
    }

    /// Seals `entries` under the kept passphrase and writes them to the backup folder, replacing
    /// a backup made earlier the same day. No proof is asked here: the caller holds the IDs
    /// already, which took one.
    @discardableResult
    public func write(_ entries: [VaultEntry]) throws -> URL {
        guard let passphrase = passphrase() else { throw VaultBackupError.noPassphrase }
        let now = clock()
        let sealed = try VaultBackupFile.seal(VaultBackupContents(madeAt: now, entries: entries), passphrase: passphrase)
        let url = folder.appendingPathComponent(Self.fileName(now))
        do {
            try SealedFile.write(sealed, to: url, fileManager: fileManager)
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

    /// Back Up Now: proves it is the owner, reads the Vault, and writes a backup.
    public func backUpNow() async -> Result<URL, VaultBackupError> {
        guard hasPassphrase else { return .failure(.noPassphrase) }
        guard case .allowed = await authenticator.prove(reason: "back up your Vault") else { return .failure(.notProved) }
        guard let entries = try? store.load() else { return .failure(.vaultUnreadable) }
        do { return .success(try write(entries)) } catch let error as VaultBackupError { return .failure(error) } catch {
            return .failure(.notWritten)
        }
    }

    // MARK: Restoring

    /// Opens a backup file with `passphrase`; with none given, with the kept one.
    public func read(_ url: URL, passphrase: String? = nil) -> Result<VaultBackupContents, VaultBackupError> {
        guard let data = fileManager.contents(atPath: url.path) else { return .failure(.notABackup) }
        guard let passphrase = passphrase ?? self.passphrase() else { return .failure(.noPassphrase) }
        do {
            let contents = try VaultBackupFile.open(data, passphrase: passphrase)
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
        guard let held = try? store.load() else { return nil }
        let have = Set(held.map { VaultReading.normalized($0.value) })
        return contents.entries.filter { !have.contains(VaultReading.normalized($0.value)) }.count
    }

    /// Puts a backup back, after a proof. Returns how many IDs the Vault holds afterwards.
    ///
    /// Replace never deletes: the Vault's file and what was read are renamed aside first
    /// (``VaultStore/setAside(at:)``), which is also what lets a Vault this Mac cannot open be
    /// replaced at all.
    public func restore(_ contents: VaultBackupContents, mode: VaultRestoreMode) async -> Result<Int, VaultBackupError> {
        guard case .allowed = await authenticator.prove(reason: "restore your Vault from a backup") else {
            return .failure(.notProved)
        }
        let entries: [VaultEntry]
        switch mode {
        case .addMissing:
            guard let held = try? store.load() else { return .failure(.vaultUnreadable) }
            let have = Set(held.map { VaultReading.normalized($0.value) })
            // A backup made before a number was corrected holds the old number under the same
            // id. It comes back as an ID of its own: two records with one id would be removed
            // together and edited as one.
            var ids = Set(held.map(\.id))
            let missing = contents.entries.filter { !have.contains(VaultReading.normalized($0.value)) }
                .map { ids.insert($0.id).inserted ? $0 : $0.reissued() }
            entries = held + missing
        case .replace:
            entries = contents.entries
        }
        // Replace sets what is here aside first, and puts it back if the new Vault cannot be
        // written (a refused Keychain, a full disk): never a Mac left with no Vault in place.
        var moved: [VaultStore.Aside] = []
        if mode == .replace {
            guard let aside = store.moveAside(at: clock(), fileManager: fileManager) else { return .failure(.notWritten) }
            moved = aside
        }
        do {
            try store.save(entries)
        } catch {
            store.putBack(moved, fileManager: fileManager)
            return .failure(.notWritten)
        }
        Logger.shared.info("Vault: restored from a backup (\(mode == .replace ? "replaced" : "added what was missing")), \(entries.count) ID(s) now")
        note(.restored, mode == .replace ? "Replaced the Vault from a backup of \(contents.entries.count) ID(s)"
                                         : "Added what was missing from a backup of \(contents.entries.count) ID(s)")
        NotificationCenter.default.post(name: Self.didRestore, object: nil, userInfo: [Self.restoredPathKey: store.fileURL.path])
        return .success(entries.count)
    }
}

extension VaultStore {
    /// A file set aside: where it was, and where it is now.
    struct Aside: Equatable {
        let from: URL
        let to: URL
    }

    /// Renames the Vault's file, what was read, and the copies kept before each save (VT20)
    /// aside: `vault.sealed.set-aside-<stamp>`. The copies go with the file they are the history
    /// of: they open only with its key, and left in place they would be pruned by the new
    /// Vault's saves.
    /// Nothing is deleted, so a Vault this Mac cannot open is kept for the day its key turns up,
    /// and a new one can be started or restored in its place. True when no sealed file is left
    /// in the way.
    @discardableResult
    public func setAside(at date: Date = Date(), fileManager: FileManager = .default) -> Bool {
        moveAside(at: date, fileManager: fileManager) != nil
    }

    /// ``setAside(at:fileManager:)``, answering what it moved so a caller that then fails can put
    /// it back. Nil when a file could not be moved; what did move is put back first, so a
    /// refusal leaves everything where it was.
    func moveAside(at date: Date, fileManager: FileManager) -> [Aside]? {
        let stamp = Int(date.timeIntervalSince1970)
        var moved: [Aside] = []
        for url in [fileURL, readingURL] + backups where fileManager.fileExists(atPath: url.path) {
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
                putBack(moved, fileManager: fileManager)
                return nil
            }
        }
        return moved
    }

    /// Puts files set aside back where they were. A file written there meanwhile (half of a save
    /// that failed) is replaced: what was set aside is the Vault.
    func putBack(_ moved: [Aside], fileManager: FileManager) {
        for aside in moved {
            do {
                if fileManager.fileExists(atPath: aside.from.path) { try fileManager.removeItem(at: aside.from) }
                try fileManager.moveItem(at: aside.to, to: aside.from)
            } catch {
                Logger.shared.warning("Vault: a sealed file set aside could not be put back — \(error.localizedDescription)")
            }
        }
    }
}
