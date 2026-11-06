import Foundation

extension CloudProvider {

    /// Where a provider's own settings live, which differs per vendor:
    ///
    /// - iCloud has a System Settings pane, opened directly by its `x-apple.systempreferences` URL.
    /// - Google Drive shows its app window when re-activated, with the settings gear in it, so its
    ///   door is the app.
    /// - OneDrive and Dropbox have no door, by his choice: their native preferences or nothing,
    ///   never a web page. Both are menu-bar apps whose preferences open only from their status
    ///   item. Re-activating them shows nothing, their URL schemes have no settings command, and
    ///   neither is scriptable for it. Only Accessibility scripting of the status item could reach
    ///   them, and it isn't built.
    ///
    /// `nil` for a folder source: a plain folder has no settings anywhere.
    public enum SettingsDoor: Equatable, Sendable {
        /// A `x-apple.systempreferences:` URL — System Settings, opened to a named pane.
        case systemSettings(URL)
        /// The vendor's own app, activated. Used only where activation verifiably shows a window.
        case application(bundleIdentifier: String)
    }

    /// This source's door, or nil where there is none: a folder source, and the two vendors whose
    /// settings nothing can open (see above).
    public var settingsDoor: SettingsDoor? {
        switch type {
        case .iCloud:
            return .systemSettings(
                URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud")!)
        case .googleDrive:
            return .application(bundleIdentifier: "com.google.drivefs")
        case .oneDrive, .dropBox, .localFolder:
            return nil
        }
    }

    /// The label for `settingsDoor`, worded for what the door opens: iCloud lands on its settings
    /// pane, Google Drive on its app, where settings are one click in.
    public var settingsDoorTitle: String? {
        switch type {
        case .iCloud: return "Open iCloud Settings"
        case .googleDrive: return "Open Google Drive"
        case .oneDrive, .dropBox, .localFolder: return nil
        }
    }
}
