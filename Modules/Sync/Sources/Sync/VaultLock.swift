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

    public var requiresAuthentication: Bool
    public var ask: Ask
    public var relock: Relock

    public init(requiresAuthentication: Bool = true, ask: Ask = .whenOpened,
                relock: Relock = .afterOneMinute) {
        self.requiresAuthentication = requiresAuthentication
        self.ask = ask
        self.relock = relock
    }

    // MARK: UserDefaults

    public static let requiresAuthenticationKey = "vaultRequiresAuthentication"
    public static let askKey = "vaultAsk"
    public static let relockKey = "vaultRelock"

    /// The saved settings. An absent or unrecognised value reads as the default, which is the
    /// locked one each time: a damaged preference must not open the Vault.
    public init(defaults: UserDefaults) {
        self.init(
            requiresAuthentication: defaults.object(forKey: Self.requiresAuthenticationKey) as? Bool ?? true,
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
    /// The one number shown after a per-number proof, and when it hides again.
    private var shown: (id: UUID, until: Date)?

    /// How long a number stays up after a per-number proof.
    public static let showFor: TimeInterval = 30

    public init(settings: VaultLockSettings = VaultLockSettings()) {
        self.settings = settings
    }

    public static func == (lhs: VaultLock, rhs: VaultLock) -> Bool {
        lhs.settings == rhs.settings && lhs.lastActivity == rhs.lastActivity
            && lhs.shown?.id == rhs.shown?.id && lhs.shown?.until == rhs.shown?.until
    }

    /// Whether every number is available without asking: the lock is off, or it was opened and
    /// has not run out.
    public func isOpen(at now: Date) -> Bool {
        guard settings.requiresAuthentication else { return true }
        guard settings.ask == .whenOpened, let lastActivity else { return false }
        guard let limit = settings.relock.idleLimit else { return true }
        return now.timeIntervalSince(lastActivity) < limit
    }

    /// Whether the panel is to show nothing at all: the lock is on, it asks as the Vault opens,
    /// and nobody has proved it since (or the proof has run out). Locked means locked: not a
    /// name, a date or an ending is drawn then, and nothing is read from disk for the panel.
    ///
    /// Never under "For every ID", which has no unlocking of the whole: there the list is what
    /// a number is chosen from, so it shows, each number behind its own proof.
    public func hidesEverything(at now: Date) -> Bool {
        settings.requiresAuthentication && settings.ask == .whenOpened && !isOpen(at: now)
    }

    /// The number shown under "every number", while its time lasts.
    public func shownID(at now: Date) -> UUID? {
        guard let shown, now < shown.until else { return nil }
        return shown.id
    }

    /// Whether `id`'s number may be drawn in full.
    public func canShow(_ id: UUID, at now: Date) -> Bool {
        if isOpen(at: now) { return true }
        guard let shown, shown.id == id else { return false }
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
        guard settings.requiresAuthentication, settings.ask == .whenOpened,
              let lastActivity, let limit = settings.relock.idleLimit else { return nil }
        let left = limit - now.timeIntervalSince(lastActivity)
        return left > 0 ? Int(left.rounded(.up)) : nil
    }

    /// The owner proved it. `id` is the number the proof was for, under "every number".
    public mutating func proved(for id: UUID? = nil, at now: Date) {
        guard settings.requiresAuthentication else { return }
        switch settings.ask {
        case .whenOpened:
            lastActivity = now
        case .everyNumber:
            if let id { shown = (id, now.addingTimeInterval(Self.showFor)) }
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
        self.shown = (shown.id, max(shown.until, now.addingTimeInterval(Self.showFor)))
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
    /// This Mac cannot ask: no password and no Touch ID. The message says what to do.
    case unavailable(String)
    case failed(String)
}

/// Asks the Mac's owner to prove it: Touch ID, Apple Watch or the login password. The app's
/// conformance is LocalAuthentication; tests answer for themselves.
public protocol VaultAuthenticating: Sendable {
    /// `reason` completes "SyncCloud is trying to …".
    func prove(reason: String) async -> VaultProof
}

/// Settings ▸ Vault's "Require Touch ID or your Mac password", when it is being unticked.
public enum VaultLockSwitch {
    /// What the prompt says after "SyncCloud is trying to".
    public static let reason = "turn off the Vault’s lock"

    /// Whether the lock may come off: only once the owner has proved it, so someone at an unlocked
    /// Mac cannot remove the lock to get at what it guards.
    ///
    /// A Mac that cannot ask (no password, no Touch ID) has nothing to prove with, and a lock
    /// nobody can open is worse than none, so there it may be turned off.
    public static func mayTurnOff(using authenticator: VaultAuthenticating) async -> Bool {
        switch await authenticator.prove(reason: reason) {
        case .allowed, .unavailable: return true
        case .cancelled, .failed: return false
        }
    }

    /// Where the seal on "the lock is off" is kept.
    public static let sealKey = "vaultLockOffSeal"

    /// Seals the lock as off, once the owner proved it: a keyed fingerprint of a fresh random
    /// secret kept in the Keychain, which only this Mac's Vault key makes. The setting itself is a
    /// plain preference, which `defaults write` can change without any proof; unsealed, an "off"
    /// is read as on (``VaultLockSettings/init(defaults:store:)``). Fresh each time, and its
    /// secret deleted when the lock goes back on, so a seal copied from an old backup of the
    /// preferences matches nothing.
    public static func sealOff(in defaults: UserDefaults, store: VaultStore?) {
        guard let seal = store?.makeLockOffSeal() else { return }
        defaults.set(seal, forKey: sealKey)
    }

    /// The lock is on again: the seal and its secret both go, so neither can be used again.
    public static func unseal(in defaults: UserDefaults, store: VaultStore? = nil) {
        defaults.removeObject(forKey: sealKey)
        store?.forgetLockOffSeal()
    }

    /// Whether "off" was set by Settings after a proof on this Mac, since the lock was last on.
    static func isSealedOff(in defaults: UserDefaults, store: VaultStore?) -> Bool {
        guard let seal = defaults.string(forKey: sealKey), let expected = store?.lockOffSeal() else { return false }
        return seal == expected
    }
}

extension VaultLockSettings {
    /// The saved settings as the Vault obeys them: an "off" that Settings did not seal after a
    /// proof is read as on, so the lock cannot be taken off from Terminal.
    public init(defaults: UserDefaults, store: VaultStore?) {
        self.init(defaults: defaults)
        if !requiresAuthentication, !VaultLockSwitch.isSealedOff(in: defaults, store: store) {
            requiresAuthentication = true
        }
    }
}
