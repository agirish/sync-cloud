import Foundation

extension CloudProvider {

    /// **Where a provider's own settings actually live**, which is a different place for every
    /// vendor — and for two of them is not on this Mac at all.
    ///
    /// Measured on 2026-08-31 (OneDrive 26.139, Dropbox 267.3, Google Drive 130.0, macOS 26.6):
    ///
    /// - **iCloud** has a real System Settings pane, and the `x-apple.systempreferences` URL opens
    ///   it directly. The only provider whose door lands on a native settings surface in one step.
    /// - **Google Drive** opens its app window on re-activation — verified with a window census
    ///   before and after `open -a` — and its settings gear is in that window. So its door is the
    ///   app itself.
    /// - **OneDrive** and **Dropbox** have NO door, deliberately (his direction, 2026-08-31: their
    ///   native preferences or nothing — "not web page"). Both run as menu-bar apps whose
    ///   preferences are reachable ONLY through a click on their status item. Re-activating
    ///   either shows nothing (verified with the same census, with and without their menu-bar
    ///   items present), their URL schemes expose no settings command (`odopen://settings` /
    ///   `preferences` / `account` each spawn only a small error window; `dropbox-client://` is
    ///   inert), neither is AppleScript-scriptable beyond the Standard Suite, and Dropbox's
    ///   binary answers no CLI flags. The one route left is Accessibility-driven UI scripting of
    ///   the status item itself, which needs a permission grant and is not built (yet) — until it
    ///   is, these two rows offer nothing rather than a web page he did not want.
    ///
    /// `nil` for a folder source: a plain folder has no vendor and no settings anywhere.
    public enum SettingsDoor: Equatable, Sendable {
        /// A `x-apple.systempreferences:` URL — System Settings, opened to a named pane.
        case systemSettings(URL)
        /// The vendor's own app, activated. Used only where activation verifiably shows a window.
        case application(bundleIdentifier: String)
    }

    /// This source's door, or nil where there is none — a folder source, and the two vendors
    /// whose settings nothing can open (see above).
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

    /// The menu item's / button's label for `settingsDoor` — worded for what the door actually
    /// opens, so no label promises a settings window the vendor does not expose: iCloud lands on
    /// its settings pane, Google Drive on the vendor's app, where settings are one click in.
    public var settingsDoorTitle: String? {
        switch type {
        case .iCloud: return "Open iCloud Settings"
        case .googleDrive: return "Open Google Drive"
        case .oneDrive, .dropBox, .localFolder: return nil
        }
    }
}
