import Design
import Events
import Foundation
import Security
import Sync
import UserNotifications

// The side effects of a few Settings controls, kept outside their views so anything that changes
// the same setting without mounting the view (an Ask Claude card) calls them too, and the setting
// can't be stored without its side effect.

/// "Notify when operations finish in the background" needs macOS's permission to post.
public enum BackgroundNotificationPermission {

    /// Asks macOS for permission, as turning the switch on does. Reports whether it was denied:
    /// the one state where the switch is on but no notification can ever come.
    public static func request(report: @escaping @MainActor (_ denied: Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in report(!granted) }
        }
    }

    /// Reads the real authorization. Only `denied` counts: `notDetermined` means the request is
    /// still ahead, and provisional and authorized both deliver.
    public static func readDenied(report: @escaping @MainActor (_ denied: Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
            let denied = notificationSettings.authorizationStatus == .denied
            Task { @MainActor in report(denied) }
        }
    }
}

/// Advanced ▸ Log level. The stored key alone takes effect only at the next launch
/// (`SyncCloudApp` reads it once); the running logger has to be told as well.
public enum LogLevelSetting {

    /// Tells the running logger, as the picker does when its value changes. An unknown value means
    /// Debug, the picker's default.
    public static func applyRunning(raw: String) {
        Logger.shared.minimumLevel = LogLevel(rawValue: raw) ?? .debug
    }

    /// Stores the level and tells the running logger: what choosing it in Settings does.
    /// `applyRunning` is a seam, so a test needn't change the process-wide logger.
    public static func set(_ level: LogLevel, in defaults: UserDefaults,
                           applyRunning: (String) -> Void = LogLevelSetting.applyRunning(raw:)) {
        defaults.set(level.rawValue, forKey: Logger.minimumLevelDefaultsKey)
        applyRunning(level.rawValue)
    }
}

/// Intelligence ▸ Claude API key ▸ Remove.
public enum APIKeyRemoval {

    /// Deletes the key and confirms it went. A Keychain delete can be refused like a write (locked
    /// keychain, denied prompt, MDM policy), and a row reading "No key yet" would then claim a
    /// secret is gone when it is not. `isConfigured`, not `hasKey`: the check must not ask for the
    /// secret.
    /// - Returns: Why the key is still stored, or nil when it is gone.
    public static func remove(from store: KeychainStore = SecItemKeychainStore()) -> String? {
        let status = AnthropicKeychain.delete(from: store)
        guard AnthropicKeychain.isConfigured(in: store) else { return nil }
        return "The Keychain refused to delete the key (status \(status)). It is still stored. Unlock your login keychain and try again."
    }
}

/// Intelligence ▸ Claude API key ▸ Save, from an Ask Claude card: the same write Settings' row
/// makes, and the same check that it landed.
public enum APIKeySaving {

    /// Stores `key` in the Keychain, replacing any saved one in place (a refused write leaves the
    /// old key). `isConfigured`, not `hasKey`: confirming the write must not ask for the secret.
    /// - Returns: Why it wasn't saved, or nil when it was.
    public static func save(_ key: String, in store: KeychainStore = SecItemKeychainStore()) -> String? {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Paste the key first." }
        let status = AnthropicKeychain.store(key, in: store)
        guard status == errSecSuccess, AnthropicKeychain.isConfigured(in: store) else {
            return "Couldn’t save the key: macOS refused it (status \(status)). The old key stays."
        }
        return nil
    }
}

/// Readability ▸ Column widths. Asks first when "All columns" would release columns sized on
/// their own: their widths are erased, and choosing "Each column" again does not bring them back.
/// With none, there is nothing to lose and it doesn't ask. `ReadabilitySettingsTab`'s rule, here so
/// a control outside the tab applies it too.
public enum ColumnResizeChoice {

    /// What to store, decided before anything is: write the result only when it is non-nil. Even
    /// a write of the same value on Cancel is a defaults change other windows react to.
    /// - Returns: The mode and widths to store, or nil when declined.
    public static func choose(_ raw: String, overrides: ColumnWidthOverrides,
                              confirm: () -> Bool) -> (mode: String, overrides: ColumnWidthOverrides)? {
        guard raw == ColumnResizeMode.allColumns.rawValue, !overrides.widths.isEmpty else {
            return (raw, overrides)
        }
        return confirm() ? (raw, ColumnWidthOverrides()) : nil
    }
}
