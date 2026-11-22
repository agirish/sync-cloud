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
    public var kind: Kind {
        didSet { laterKind = nil }
    }
    /// The words a later build stored for ``Kind/other``, written back as they came so the first
    /// append here does not turn them into "other" (VT30).
    private var laterKind: String?
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

    private enum CodingKeys: String, CodingKey { case id, at, kind, what, whose }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        at = try c.decode(Date.self, forKey: .at)
        let raw = try c.decode(String.self, forKey: .kind)
        kind = Kind(rawValue: raw) ?? .other
        laterKind = Kind(rawValue: raw) == nil ? raw : nil
        what = try c.decode(String.self, forKey: .what)
        whose = try c.decodeIfPresent(String.self, forKey: .whose)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(at, forKey: .at)
        try c.encode(laterKind ?? kind.rawValue, forKey: .kind)
        try c.encode(what, forKey: .what)
        try c.encodeIfPresent(whose, forKey: .whose)
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
    private let fileManager: FileManager

    static let marker = Data("SCVACTV1".utf8)
    public static let limit = 500
    public static let keptFor: TimeInterval = 90 * 86_400

    public init(fileURL: URL, keychain: KeychainStore = SecItemKeychainStore(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.keychain = keychain
        self.fileManager = fileManager
    }

    /// `vault-activity.sealed`, beside the Vault's file.
    public static func beside(_ store: VaultStore, keychain: KeychainStore = SecItemKeychainStore(),
                              fileManager: FileManager = .default) -> VaultActivityStore {
        VaultActivityStore(fileURL: store.activityURL, keychain: keychain, fileManager: fileManager)
    }

    private var key: SymmetricKey? {
        if case .found(let key) = VaultKeychain.read(from: keychain) { return key }
        return nil
    }

    /// Every kept event, newest first; none when there is no file, no key, or a file this build
    /// cannot read.
    public func load() -> [VaultActivityEvent] {
        guard let data = fileManager.contents(atPath: fileURL.path), let key,
              let events = try? VaultFile.open([VaultActivityEvent].self, data, marker: Self.marker, with: key) else { return [] }
        return events
    }

    /// Adds `events` to the front and seals the list, trimmed to its bounds. Never makes the
    /// Vault's key: with none there is no Vault to have activity in. A refused write is logged
    /// and let go; the list is a record, not something to fail an act over.
    public func append(_ events: [VaultActivityEvent], now: Date) {
        guard !events.isEmpty, let key else { return }
        // A list there that does not open (damaged, a later build's, another key's) is set aside
        // under a name of its own, never sealed over.
        if let data = fileManager.contents(atPath: fileURL.path),
           (try? VaultFile.open([VaultActivityEvent].self, data, marker: Self.marker, with: key)) == nil {
            let aside = UnreadableSetAside.destination(for: fileURL, at: now, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: fileURL, to: aside)
                Logger.shared.warning("Vault: the activity list did not open (\(VaultFile.summary(of: data))) and was set aside as \(aside.lastPathComponent)")
            } catch {
                Logger.shared.warning("Vault: the activity list did not open (\(VaultFile.summary(of: data))) and could not be set aside — nothing was added to it")
                return
            }
        }
        let kept = (events.sorted { $0.at > $1.at } + load())
            .filter { now.timeIntervalSince($0.at) < Self.keptFor }
            .prefix(Self.limit)
        do {
            let sealed = try VaultFile.seal(Array(kept), marker: Self.marker, with: key)
            try SealedFile.write(sealed, to: fileURL, fileManager: fileManager)
        } catch {
            Logger.shared.warning("Vault: the activity list could not be sealed — \(error.localizedDescription)")
        }
    }

    /// Clear: the list goes, for good.
    public func clear() {
        try? fileManager.removeItem(at: fileURL)
    }
}
