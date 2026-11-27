import Events
import Foundation
import LocalAuthentication
import Security

/// Where the Vault's key is kept behind Touch ID: the data-protection keychain, its item readable
/// only with a fingerprint (VT31). A seam, so ``VaultKeyHolder`` is tested without it.
public protocol VaultProtectedKeys: AnyObject {
    /// The key's bytes, read with `context` (a Touch ID proof just given), or with no prompt at
    /// all when it is nil: `errSecInteractionNotAllowed` then means it is there, behind Touch ID.
    /// `errSecMissingEntitlement` means this build cannot reach that keychain at all.
    func read(with context: LAContext?) -> (status: OSStatus, data: Data?)
    /// Keeps `data` as the key, behind Touch ID.
    func add(_ data: Data) -> OSStatus
    @discardableResult
    func delete() -> OSStatus
}

/// The Vault's key, kept behind Touch ID where this build can (VT31), and held in memory from the
/// proof that read it until the Vault lets go of its numbers (VT10).
///
/// A ``KeychainStore`` every Vault store goes through: every other item (the backup's passphrase)
/// passes to the login keychain as before. The key itself:
/// - read: the one held; else the Touch ID-guarded one, with the last proof's context, never a
///   prompt of its own; else, not moved yet, the login keychain's, which a proof then moves.
/// - the move, once: added behind Touch ID, read back with the proof and compared byte for byte,
///   and only then taken out of the login keychain. Anything else leaves the login key in use.
/// - a build that cannot reach the data-protection keychain (CI, tests, an install without its
///   profile) keeps to the login keychain, unless the key has moved: then it says the key cannot
///   be read, never that there is none, so no new key is made over the Vault.
public final class VaultKeyHolder: KeychainStore, @unchecked Sendable {
    /// The app's: the login keychain and the data-protection one, its mark in the app's defaults.
    public static let shared = VaultKeyHolder(inner: SecItemKeychainStore(), protected: SecItemProtectedKeys(),
                                              defaults: .standard)

    /// Set once the key has moved behind Touch ID: from then on a build that cannot reach it says
    /// so, rather than taking the login keychain's empty answer for no key at all.
    public static let movedKey = "vaultKeyBehindTouchID"

    private let inner: KeychainStore
    private let protected: VaultProtectedKeys?
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var held: Data?
    private var context: LAContext?

    public init(inner: KeychainStore, protected: VaultProtectedKeys?, defaults: UserDefaults) {
        self.inner = inner
        self.protected = protected
        self.defaults = defaults
    }

    /// A Touch ID proof just given: the next read of the key uses it, so it asks no second time.
    public func authorise(with context: LAContext) {
        lock.withLock { self.context = context }
    }

    /// The Vault let go of its numbers: so does this, and the proof with them.
    public func release() {
        lock.withLock {
            held = nil
            context = nil
        }
    }

    /// Whether the key is in memory now, for a test.
    public var isHeld: Bool { lock.withLock { held != nil } }

    /// Whether the key is behind Touch ID now.
    public var isBehindTouchID: Bool { defaults.bool(forKey: Self.movedKey) }

    private static func isVaultKey(_ query: [String: Any]) -> Bool {
        query[kSecAttrService as String] as? String == VaultKeychain.service
    }

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        guard Self.isVaultKey(query) else { return inner.copyMatching(query) }
        let wantsData = query[kSecReturnData as String] as? Bool == true
        return lock.withLock {
            func answer(_ data: Data) -> (OSStatus, AnyObject?) { (errSecSuccess, wantsData ? data as NSData : nil) }
            if let held { return answer(held) }
            guard let protected else { return inner.copyMatching(query) }
            let (status, data) = protected.read(with: context)
            switch status {
            case errSecSuccess:
                guard let data else { return (errSecDecode, nil) }
                held = data
                return answer(data)
            case errSecItemNotFound:
                // Not moved yet: the login keychain's, moved behind Touch ID once a proof stands.
                var login = query
                login[kSecReturnData as String] = true
                let (found, result) = inner.copyMatching(login)
                guard found == errSecSuccess, let key = result as? Data else { return (found, wantsData ? result : nil) }
                if context != nil, move(key, with: protected) { held = key }
                return answer(key)
            case errSecMissingEntitlement:
                if isBehindTouchID {
                    Logger.shared.warning("Vault: this copy of SyncCloud cannot reach the Vault's key, which is kept behind Touch ID — install it with its profile")
                    return (errSecMissingEntitlement, nil)
                }
                return inner.copyMatching(query)
            default:
                // Behind Touch ID with no proof yet (interaction not allowed), or a proof refused.
                return (status, nil)
            }
        }
    }

    /// The one move, under the lock: added, read back the same, then out of the login keychain.
    private func move(_ key: Data, with protected: VaultProtectedKeys) -> Bool {
        let added = protected.add(key)
        guard added == errSecSuccess || added == errSecDuplicateItem else {
            Logger.shared.warning("Vault: the Vault's key could not be kept behind Touch ID (status \(added)); the login keychain's stays in use")
            return false
        }
        let (read, back) = protected.read(with: context)
        guard read == errSecSuccess, back == key else {
            Logger.shared.warning("Vault: the key kept behind Touch ID did not read back as the Vault's (status \(read)); the login keychain's stays in use")
            if added == errSecSuccess { protected.delete() }
            return false
        }
        let removed = inner.delete(VaultKeychain.query())
        defaults.set(true, forKey: Self.movedKey)
        Logger.shared.info("Vault: the Vault's key is now kept behind Touch ID"
                           + (removed == errSecSuccess ? ", and gone from the login keychain" : "; the login keychain's copy could not be removed (status \(removed))"))
        return true
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        guard Self.isVaultKey(attributes), let protected, let data = attributes[kSecValueData as String] as? Data else {
            return inner.add(attributes)
        }
        return lock.withLock {
            // A new Vault's key goes behind Touch ID at once, where this build can reach it.
            let status = protected.add(data)
            if status == errSecMissingEntitlement { return inner.add(attributes) }
            if status == errSecSuccess { defaults.set(true, forKey: Self.movedKey) }
            return status
        }
    }

    @discardableResult
    public func delete(_ query: [String: Any]) -> OSStatus {
        guard Self.isVaultKey(query) else { return inner.delete(query) }
        return lock.withLock {
            // Only a key made for a save that then wrote nothing: wherever it was made.
            held = nil
            let fromProtected = protected?.delete() ?? errSecItemNotFound
            let fromLogin = inner.delete(query)
            return fromProtected == errSecSuccess ? fromProtected : fromLogin
        }
    }

    @discardableResult
    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        inner.update(query, attributes: attributes)
    }
}

/// The data-protection keychain's item for the Vault's key: readable only with Touch ID (any
/// enrolled finger: a new one is said, not refused, by the owner's call, 2026-11-26), on this Mac
/// only, while it is unlocked.
public final class SecItemProtectedKeys: VaultProtectedKeys {
    public init() {}

    private func base() -> [String: Any] {
        var query = VaultKeychain.query()
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    public func read(with context: LAContext?) -> (status: OSStatus, data: Data?) {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context ?? quiet
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    public func add(_ data: Data) -> OSStatus {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           .biometryAny, &error) else { return errSecParam }
        var attributes = base()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessControl as String] = access
        attributes[kSecAttrLabel as String] = "SyncCloud Vault key"
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    @discardableResult
    public func delete() -> OSStatus {
        SecItemDelete(base() as CFDictionary)
    }
}
