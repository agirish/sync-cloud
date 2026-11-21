import Foundation

/// How far an ID shown or copied travels beyond the panel (Settings ▸ Vault): how long a copy
/// stays on the clipboard, and whether the window is kept out of screen sharing while an ID is
/// drawn in full.
public enum VaultSharingSettings {
    public static let clipboardSecondsKey = "vaultClipboardSeconds"
    public static let hidesFromCaptureKey = "vaultHidesFromScreenSharing"

    /// The choices for how long a copied ID stays on the clipboard, in seconds.
    public static let clipboardChoices = [30, 60, 120, 300]
    public static let defaultClipboardSeconds = 60

    /// The saved choice; anything else stored there reads as the default.
    public static func clipboardSeconds(in defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.integer(forKey: clipboardSecondsKey)
        return clipboardChoices.contains(saved) ? saved : defaultClipboardSeconds
    }

    /// "30 seconds", "1 minute", "5 minutes".
    public static func label(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
    }

    /// Whether the window is left out of what other apps can capture while an ID is drawn in
    /// full. On unless turned off.
    public static func hidesFromCapture(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hidesFromCaptureKey) as? Bool ?? true
    }
}
