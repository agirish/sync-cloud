import CryptoKit
import Events
import Foundation

/// One thing done in the Vault: what, when, and to which ID by its name and owner. Never a
/// number: an event is what a person would say happened ("copied Anna's passport"), not what
/// was on the clipboard.
public struct VaultActivityEvent: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case unlocked, proofRefused, shown, copied, added, confirmed, edited, removed, setAside, corrected, merged, takenOff
        case refreshed, discovered, backedUp, restored
        /// A choice made about an ID or a name (VT23), its words whole: "Moved Passport to Archive".
        /// A build before it lists it by those words too (``other``).
        case changed
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
        case .changed: return [what, whose].compactMap { $0 }.joined(separator: " · ")
        case .shown: verb = "Showed"
        case .copied: verb = "Copied"
        case .added: verb = "Added"
        case .confirmed: verb = "Added from a document"
        case .edited: verb = "Edited"
        case .removed: verb = "Removed"
        case .setAside: verb = "Set aside as not an ID"
        case .corrected: verb = "Corrected"
        case .merged: verb = "Merged a reading into"
        case .takenOff: verb = "Took a file off"
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
/// sealed; and it is not the Vault, so a damaged or outdated one is set aside and started again. It is
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
    /// Its key read as `store` reads its own, unless `keychain` says otherwise.
    public static func beside(_ store: VaultStore, keychain: KeychainStore? = nil,
                              fileManager: FileManager = .default) -> VaultActivityStore {
        VaultActivityStore(fileURL: store.activityURL, keychain: keychain ?? store.keychainStore, fileManager: fileManager)
    }

    private var key: SymmetricKey? {
        if case .found(let key) = VaultKeychain.read(from: keychain) { return key }
        return nil
    }

    /// Every kept event this build can read, newest first; none when there is no file, no key,
    /// or a file that does not open. Given `now`, without the events older than ``keptFor``, which
    /// only the next ``append(_:now:)`` takes off the disk: a Vault left alone for months shows
    /// none of them meanwhile (the final review).
    public func load(now: Date? = nil) -> [VaultActivityEvent] {
        guard let data = fileManager.contents(atPath: fileURL.path), let key else { return [] }
        let events = (try? Self.open(data, with: key))?.compactMap(\.event) ?? []
        guard let now else { return events }
        return events.filter { now.timeIntervalSince($0.at) < Self.keptFor }
    }

    /// One stored event: this build's, read; a later build's, kept as its JSON, with its date when
    /// this build can read one.
    struct Stored {
        let event: VaultActivityEvent?
        let json: Data
        let at: Date?
    }

    /// The list's events, one by one: one a later build wrote that this build cannot read (a
    /// changed field) is kept as its JSON, not taken for a list that does not open (VT30).
    /// In the order stored, which is the list's: newest first, as each entry was added.
    static func open(_ data: Data, with key: SymmetricKey) throws -> [Stored] {
        let plain = try VaultFile.openPlain(data, marker: marker, with: key)
        guard let list = try? JSONSerialization.jsonObject(with: plain) as? [Any] else { throw VaultError.unreadableFile }
        let decoder = VaultFile.jsonDecoder()
        struct Dated: Decodable { let at: Date }
        return try list.map { element in
            guard let json = try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys, .fragmentsAllowed]) else {
                throw VaultError.unreadableFile
            }
            if let event = try? decoder.decode(VaultActivityEvent.self, from: json) { return Stored(event: event, json: json, at: event.at) }
            return Stored(event: nil, json: json, at: (try? decoder.decode(Dated.self, from: json))?.at)
        }
    }

    /// Adds `events` to the front and seals the list, trimmed to its bounds. Never makes the
    /// Vault's key: with none there is no Vault to have activity in. A refused write is logged
    /// and let go; the list is a record, not something to fail an act over.
    public func append(_ events: [VaultActivityEvent], now: Date) {
        guard !events.isEmpty else { return }
        let key: SymmetricKey
        switch VaultKeychain.read(from: keychain) {
        case .found(let found): key = found
        // Every answer that means "a touch would read it" (the third review: two of them dropped).
        case .unreadable(let status) where [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status):
            // The key behind Touch ID with no proof yet (VT31): held here until the next one, or
            // the next line that can be sealed; lost if the app quits first (owner, 2026-11-26).
            Self.waitingLock.withLock { Self.waiting[fileURL.path, default: []] += events }
            return
        default: return
        }
        let waited = Self.waitingLock.withLock { Self.waiting.removeValue(forKey: fileURL.path) ?? [] }
        let events = events + waited
        // Not sealed after all: what waited waits on, never dropped (the third review).
        func keepWaiting() { if !waited.isEmpty { Self.waitingLock.withLock { Self.waiting[fileURL.path, default: []] += waited } } }
        // A list there that does not open (damaged, a later build's, another key's) is set aside
        // under a name of its own, never sealed over. Opened once, for both questions.
        var held: [Stored] = []
        if fileManager.fileExists(atPath: fileURL.path), fileManager.contents(atPath: fileURL.path) == nil {
            Logger.shared.warning("Vault: the activity list is there but could not be read from disk — nothing was added to it")
            keepWaiting()
            return
        }
        if let data = fileManager.contents(atPath: fileURL.path) {
            if let opened = try? Self.open(data, with: key) {
                held = opened
            } else {
                let aside = UnreadableSetAside.destination(for: fileURL, at: now, fileManager: fileManager)
                do {
                    try fileManager.moveItem(at: fileURL, to: aside)
                    Logger.shared.warning("Vault: the activity list did not open (\(VaultFile.summary(of: data))) and was set aside as \(aside.lastPathComponent)")
                } catch {
                    Logger.shared.warning("Vault: the activity list did not open (\(VaultFile.summary(of: data))) and could not be set aside — nothing was added to it")
                    keepWaiting()
                    return
                }
            }
        }
        // The new events first, newest first, then the list as it was stored, a later build's in
        // their places, within the bounds: none older than ninety days (one whose date this build
        // cannot read is kept until the newest `limit` leave it out), the newest `limit`.
        let encoder = VaultFile.jsonEncoder()
        do {
            let fresh = try events.sorted { $0.at > $1.at }.map { Stored(event: $0, json: try encoder.encode($0), at: $0.at) }
            let elements = (fresh + held)
                .filter { stored in stored.at.map { now.timeIntervalSince($0) < Self.keptFor } ?? true }
                .prefix(Self.limit)
                // As stored: a later build's fields on an event this build reads stay too.
                .map(\.json)
            let sealed = try VaultFile.sealPlain(Data("[".utf8) + elements.joined(separator: Data(",".utf8)) + Data("]".utf8),
                                                 marker: Self.marker, with: key)
            try SealedFile.write(sealed, to: fileURL, fileManager: fileManager, flushing: false)
        } catch {
            Logger.shared.warning("Vault: the activity list could not be sealed — \(error.localizedDescription)")
        }
    }

    /// Lines written while the key could not be read, by list (``append(_:now:)``).
    private nonisolated(unsafe) static var waiting: [String: [VaultActivityEvent]] = [:]
    private static let waitingLock = NSLock()

    /// A proof was just given: the lines that waited for one are sealed now.
    public func sealWaiting(now: Date) {
        let pending = Self.waitingLock.withLock { Self.waiting.removeValue(forKey: fileURL.path) ?? [] }
        append(pending, now: now)
    }

    /// How many lines wait for a proof, for a test.
    var waitingCount: Int { Self.waitingLock.withLock { Self.waiting[fileURL.path]?.count ?? 0 } }

    /// Clear: the list goes, for good, but for one line saying it was cleared, so a list wiped
    /// after an unknown fingerprint opened the Vault is never silent about it (the third review).
    public func clear(now: Date = Date()) {
        try? fileManager.removeItem(at: fileURL)
        append([VaultActivityEvent(at: now, kind: .other, what: "Cleared the activity list")], now: now)
    }
}
