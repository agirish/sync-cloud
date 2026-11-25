import Foundation

/// How the Vault's lock is set: Settings ▸ Vault.
public struct VaultLockSettings: Equatable, Sendable {
    /// When the Mac's owner is asked to prove it.
    public enum Ask: String, Sendable, CaseIterable {
        /// Once, as the Vault opens. Every number is then a click away until it locks again.
        case whenOpened
        /// For each number shown or copied, and that number only.
        case everyNumber

        public var label: String {
            switch self {
            case .whenOpened: return "As soon as Vault opens"
            case .everyNumber: return "For every number"
            }
        }
    }

    /// When an unlocked Vault locks itself. Only read under ``Ask/whenOpened``. Idle means no use
    /// at all: any click, key, scroll or pointer movement in the panel starts the count again.
    public enum Relock: String, Sendable, CaseIterable {
        case whenClosed
        /// One idle minute, and when the Vault closes. The default.
        case afterOneMinute
        /// Two idle minutes, and when the Vault closes.
        case afterTwoMinutes
        /// Five idle minutes, and when the Vault closes.
        case afterFiveMinutes
        /// Ten idle minutes, across closing and reopening.
        case afterTenMinutes

        public var label: String {
            switch self {
            case .whenClosed: return "When Vault closes"
            case .afterOneMinute: return "After 1 minute idle, or when Vault closes"
            case .afterTwoMinutes: return "After 2 minutes idle, or when Vault closes"
            case .afterFiveMinutes: return "After 5 minutes idle, or when Vault closes"
            case .afterTenMinutes: return "After 10 minutes idle, even if closed"
            }
        }

        /// The idle time allowed, or nil when only closing locks.
        var idleLimit: TimeInterval? {
            switch self {
            case .whenClosed: return nil
            case .afterOneMinute: return 60
            case .afterTwoMinutes: return 120
            case .afterFiveMinutes: return 300
            case .afterTenMinutes: return 600
            }
        }

        var locksOnClose: Bool { self != .afterTenMinutes }
    }

    // The lock is always on: Touch ID guards every number in full (owner, 2026-11-24).
    public var ask: Ask
    public var relock: Relock

    public init(ask: Ask = .whenOpened, relock: Relock = .afterOneMinute) {
        self.ask = ask
        self.relock = relock
    }

    // MARK: UserDefaults

    public static let askKey = "vaultAsk"
    public static let relockKey = "vaultRelock"

    /// The saved settings. An absent or unrecognised value reads as the default, which is the
    /// locked one each time: a damaged preference must not open the Vault.
    public init(defaults: UserDefaults) {
        self.init(
            ask: defaults.string(forKey: Self.askKey).flatMap(Ask.init(rawValue:)) ?? .whenOpened,
            relock: defaults.string(forKey: Self.relockKey).flatMap(Relock.init(rawValue:)) ?? .afterOneMinute)
    }
}

/// Whether the Vault's numbers may be shown right now.
///
/// A value, and every question takes the time as an argument, so the rules are tested without a
/// clock or a Touch ID sensor. The proof itself (``VaultAuthenticating``) happens elsewhere; this
/// only records that it did, and when it stops counting.
public struct VaultLock: Equatable, Sendable {
    public var settings: VaultLockSettings

    /// When the owner last proved it under ``VaultLockSettings/Ask/whenOpened``, or last used the
    /// unlocked Vault. Nil while locked.
    private var lastActivity: Date?
    /// The numbers shown after a per-number proof, and when they hide again: one, or every ID an
    /// editor draws in full (a card's other IDs beside the one being changed) for one proof.
    private var shown: (ids: Set<UUID>, until: Date)?

    /// How long a number stays up after a per-number proof.
    public static let showFor: TimeInterval = 30

    public init(settings: VaultLockSettings = VaultLockSettings()) {
        self.settings = settings
    }

    public static func == (lhs: VaultLock, rhs: VaultLock) -> Bool {
        lhs.settings == rhs.settings && lhs.lastActivity == rhs.lastActivity
            && lhs.shown?.ids == rhs.shown?.ids && lhs.shown?.until == rhs.shown?.until
    }

    /// Whether every number is available without asking: it was opened and has not run out.
    public func isOpen(at now: Date) -> Bool {
        guard settings.ask == .whenOpened, let lastActivity else { return false }
        guard let limit = settings.relock.idleLimit else { return true }
        return now.timeIntervalSince(lastActivity) < limit
    }

    /// Whether the panel is to show nothing at all: it asks as the Vault opens, and nobody has
    /// proved it since (or the proof has run out). Locked means locked: not a
    /// name, a date or an ending is drawn then, and nothing is read from disk for the panel.
    ///
    /// Never under "For every ID", which has no unlocking of the whole: there the list is what
    /// a number is chosen from, so it shows, each number behind its own proof.
    public func hidesEverything(at now: Date) -> Bool {
        settings.ask == .whenOpened && !isOpen(at: now)
    }

    /// The numbers shown under "every number", while their time lasts.
    public func shownIDs(at now: Date) -> Set<UUID> {
        guard let shown, now < shown.until else { return [] }
        return shown.ids
    }

    /// The number shown under "every number", while its time lasts: the one, when one is.
    public func shownID(at now: Date) -> UUID? {
        let ids = shownIDs(at: now)
        return ids.count == 1 ? ids.first : nil
    }

    /// Whether `id`'s number may be drawn in full.
    public func canShow(_ id: UUID, at now: Date) -> Bool {
        if isOpen(at: now) { return true }
        guard let shown, shown.ids.contains(id) else { return false }
        return now < shown.until
    }

    /// Whether showing or copying `id` needs a proof first; with no `id`, whether opening does.
    /// A proof for one number covers reading and copying that number while it is up.
    public func needsProof(for id: UUID?, at now: Date) -> Bool {
        guard let id else { return !isOpen(at: now) }
        return !canShow(id, at: now)
    }

    /// Seconds until an open Vault locks from idleness, or nil when no timer is running.
    public func secondsLeft(at now: Date) -> Int? {
        guard settings.ask == .whenOpened, let lastActivity, let limit = settings.relock.idleLimit else { return nil }
        let left = limit - now.timeIntervalSince(lastActivity)
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// The owner proved it. `id` is the number the proof was for, under "every number".
    public mutating func proved(for id: UUID? = nil, at now: Date) {
        proved(for: id.map { [$0] } ?? [], at: now)
    }

    /// The owner proved it for every one of `ids` at once, under "every number": they show
    /// together, and hide together. Any number shown before hides, as after any other proof.
    public mutating func proved(for ids: Set<UUID>, at now: Date) {
        switch settings.ask {
        case .whenOpened:
            lastActivity = now
        case .everyNumber:
            if !ids.isEmpty { shown = (ids, now.addingTimeInterval(Self.showFor)) }
        }
    }

    /// The unlocked Vault was used: a number shown or copied, a row chosen. Restarts the idle
    /// timer. Nothing while locked; using a locked Vault does not open it.
    public mutating func used(at now: Date) {
        guard isOpen(at: now), lastActivity != nil else { return }
        lastActivity = now
    }

    /// The number shown under "every number" is being worked on: typed in the editor, or read
    /// out line by line in Large Type. Its thirty seconds start again, so it is not taken away
    /// mid-edit. Nothing once those seconds have run out; it never shows a number again.
    public mutating func keepShown(at now: Date) {
        guard let shown, now < shown.until else { return }
        self.shown = (shown.ids, max(shown.until, now.addingTimeInterval(Self.showFor)))
    }

    /// The panel closed.
    public mutating func closed() {
        shown = nil
        if settings.relock.locksOnClose { lastActivity = nil }
    }

    /// Lock Now, the Mac going to sleep, or a setting that tightened.
    public mutating func lock() {
        lastActivity = nil
        shown = nil
    }

    /// Drops what has run out, so a later, looser setting cannot revive an old proof.
    public mutating func expire(at now: Date) {
        if let shown, now >= shown.until { self.shown = nil }
        if lastActivity != nil, !isOpen(at: now) { lastActivity = nil }
    }
}

/// What a proof of ownership came to.
public enum VaultProof: Equatable, Sendable {
    case allowed
    /// The owner dismissed the prompt.
    case cancelled
    /// This Mac cannot ask: Touch ID is not set up (``VaultTouchID/notSetUp(_:)``). The message
    /// says what to do.
    case unavailable(String)
    case failed(String)
}

/// Whether this Mac has Touch ID to prove it with.
public enum VaultTouchID: Equatable, Sendable {
    case ready
    /// Set up, and out of reach for now: the lid closed, or locked after too many tries. The Vault
    /// stays locked until it can ask.
    case outOfReach
    /// Not set up: no fingerprint, no login password, or no sensor. The Vault is not used at all
    /// until it is (owner, 2026-11-24); the message says what to do.
    case notSetUp(String)
}

/// Asks the Mac’s owner to prove it with Touch ID, and only Touch ID. The app’s
/// conformance is LocalAuthentication; tests answer for themselves.
public protocol VaultAuthenticating: Sendable {
    /// `reason` completes "SyncCloud is trying to …".
    func prove(reason: String) async -> VaultProof
    /// Whether this Mac has Touch ID, asked without a prompt. Required: a proof that leaves it out
    /// must not pass for one with Touch ID set up.
    var touchID: VaultTouchID { get }
}

