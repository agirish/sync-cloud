import Design
import Events
import Foundation
import Sync
import UserNotifications

// The work a few Settings controls used to do inside their views, moved where any control can call
// it (TE290 step 0a). Each is the view's code, unchanged; the views now call these. Anything that
// changes the same setting without mounting the view — an Ask Claude card — calls them too, so the
// setting can't be stored without its side effect.

/// "Notify when operations finish in the background" needs macOS's permission to post.
public enum BackgroundNotificationPermission {

    /// Asks macOS for permission, as turning the switch on does. Reports whether it was DENIED —
    /// the one state where the feature looks enabled but can never fire. A denied request used to
    /// vanish, leaving the switch on and the user waiting for notifications that never come.
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

    /// Deletes the key and confirms it actually went, rather than assuming. A Keychain delete can
    /// be refused exactly as a write can (locked keychain, denied prompt, an MDM policy); a row
    /// that then read "No key yet" would leave the user believing a secret is gone when it is not.
    /// `isConfigured`, not `hasKey`: confirming the item is gone must not ask for the secret.
    /// - Returns: Why the key is still stored, or nil when it is gone.
    public static func remove(from store: KeychainStore = SecItemKeychainStore()) -> String? {
        let status = AnthropicKeychain.delete(from: store)
        guard AnthropicKeychain.isConfigured(in: store) else { return nil }
        return "The Keychain refused to delete the key (status \(status)). It is still stored. Unlock your login keychain and try again."
    }
}

/// Readability ▸ Column widths. **Asks first when "All columns" would release columns sized on
/// their own** — their widths are erased, and choosing "Each column" again does not bring them
/// back. Declined, nothing changes: the mode stays where it was. With nothing sized on its own
/// there is nothing to lose, so it does not ask. The rule `ReadabilitySettingsTab` applies, here so
/// a control outside the tab applies it too.
public enum ColumnResizeChoice {

    /// - Returns: Whether the mode was written.
    @discardableResult
    public static func choose(_ raw: String, mode: inout String,
                              overrides: inout ColumnWidthOverrides,
                              confirm: () -> Bool) -> Bool {
        guard raw == ColumnResizeMode.allColumns.rawValue, !overrides.widths.isEmpty else {
            mode = raw
            return true
        }
        return RemovalPrompt.actIfConfirmed(confirm: confirm) {
            mode = raw
            overrides = ColumnWidthOverrides()
        }
    }
}
