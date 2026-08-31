import AppKit
import Sync

/// **The one place a `SettingsDoor` is turned into a side effect.** The door itself lives on
/// `CloudProvider` (pure, so the table is testable); this is the AppKit half, shared by the two
/// surfaces that offer it — the sidebar's context menu and Settings ▸ Sources.
public enum ProviderSettingsOpener {

    /// Whether the door can be opened on this machine.
    ///
    /// Only an application door can be closed: the vendor's app may simply not be installed, and a
    /// menu item that launches nothing should be absent, not present-and-dead (the sidebar menu's
    /// standing rule). System Settings always exists.
    public static func canOpen(_ door: CloudProvider.SettingsDoor) -> Bool {
        switch door {
        case .systemSettings:
            return true
        case .application(let bundleIdentifier):
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
        }
    }

    public static func open(_ door: CloudProvider.SettingsDoor) {
        switch door {
        case .systemSettings(let url):
            NSWorkspace.shared.open(url)
        case .application(let bundleIdentifier):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                return
            }
            // Plain activation: verified to bring up the app's own window for the one vendor
            // routed here (Google Drive). `OpenConfiguration()` activates by default.
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
