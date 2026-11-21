import CryptoKit
import Events
import Foundation

/// One thing done in the Vault: what, when, and to which ID by its name and owner. Never a
/// number: an event is what a person would say happened ("copied Anna's passport"), not what
/// was on the clipboard.
public struct VaultActivityEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case unlocked, proofRefused, shown, copied, added, confirmed, edited, removed, setAside
        case refreshed, discovered, backedUp, restored
        /// A kind a later build wrote: kept and listed by its words alone.
        case other

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    public var id: UUID
    public var at: Date
    public var kind: Kind
    /// What it was done to, in words: an ID's name, a detail's label, a read's summary.
    public var what: String
    /// Whose: a person's name or "Household". Nil for what is nobody's (unlocking, a read).
    public var whose: String?

    public init(id: UUID = UUID(), at: Date, kind: Kind, what: String = "", whose: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.what = what
        self.whose = whose
    }

    /// The event as one line: "Copied Passport · Anna", "Unlocked", "Proof refused: unlock your Vault".
    public var line: String {
        let verb: String
        switch kind {
        case .unlocked: return "Unlocked"
        case .proofRefused: return what.isEmpty ? "Proof refused" : "Proof refused: \(what)"
        case .refreshed, .discovered, .backedUp, .restored, .other: return what
        case .shown: verb = "Showed"
        case .copied: verb = "Copied"
        case .added: verb = "Added"
        case .confirmed: verb = "Added from a document"
        case .edited: verb = "Edited"
        case .removed: verb = "Removed"
        case .setAside: verb = "Set aside as not a real ID"
        }
        return [verb + (what.isEmpty ? "" : " " + what), whose].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Whether the Vault keeps its activity list (Settings ▸ Vault). On unless turned off.
public enum VaultActivitySettings {
    public static let keepsKey = "vaultKeepsActivity"

    public static func keeps(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepsKey) as? Bool ?? true
    }
}

/// The Vault's activity list, sealed with the Vault's key in a file of its own.
///
/// Its own file, like what was read: which IDs were used, and when, is private too, so it is
/// sealed; and it is not the Vault, so a damaged or outdated one is simply started again. It is
/// never the app's log, which holds nothing of the Vault's. Bounded: the newest events, and none
/// older than ninety days.
public struct VaultActivityStore {
    public let fileURL: URL
    private let keychain: KeychainStore

    static let marker = Data("SCVACTV1".utf8)
    public static let limit = 500
    public static let keptFor: TimeInterval = 90 * 86_400

    public init(fileURL: URL, keychain: KeychainStore = SecItemKeychainStore()) {
        self.fileURL = fileURL
        self.keychain = keychain
    }

    /// `vault-activity.sealed`, beside the Vault's file.
    public static func beside(_ store: VaultStore, keychain: KeychainStore = SecItemKeychainStore()) -> VaultActivityStore {
        VaultActivityStore(fileURL: store.fileURL.deletingLastPathComponent().appendingPathComponent("vault-activity.sealed"),
                           keychain: keychain)
    }

    private var key: SymmetricKey? {
        if case .found(let key) = VaultKeychain.read(from: keychain) { return key }
        return nil
    }

    /// Every kept event, newest first; none when there is no file, no key, or a file this build
    /// cannot read.
    public func load() -> [VaultActivityEvent] {
        guard let data = FileManager.default.contents(atPath: fileURL.path), let key,
              let events = try? VaultFile.open([VaultActivityEvent].self, data, marker: Self.marker, with: key) else { return [] }
        return events
    }

    /// Adds `events` to the front and seals the list, trimmed to its bounds. Never makes the
    /// Vault's key: with none there is no Vault to have activity in. A refused write is logged
    /// and let go; the list is a record, not something to fail an act over.
    public func append(_ events: [VaultActivityEvent], now: Date) {
        guard !events.isEmpty, let key else { return }
        let kept = (events.sorted { $0.at > $1.at } + load())
            .filter { now.timeIntervalSince($0.at) < Self.keptFor }
            .prefix(Self.limit)
        do {
            let sealed = try VaultFile.seal(Array(kept), marker: Self.marker, with: key)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Logger.shared.warning("Vault: the activity list could not be sealed — \(error.localizedDescription)")
        }
    }

    /// Clear: the list goes, for good.
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
