import SwiftUI
import AppKit

/// Whether the app renders light or dark: the theme half of Appearance, independent of
/// `GlassLevel` (material) and `SurfaceStyle` (shape), so every combination is valid.
///
/// `.system`, the default, follows System Settings ▸ Appearance, including mid-session switches
/// and the Auto schedule. `.light` and `.dark` pin the app against the system. Stored under
/// `LiquidGlass.appearanceModeKey`.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    /// Follow macOS. The default, and the only case that tracks a mid-session system change.
    case system
    /// Pin to light regardless of the system setting.
    case light
    /// Pin to dark regardless of the system setting.
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The appearance to pin `NSApplication` to. `nil` is how AppKit spells "inherit the system",
    /// so `.system` must assign it rather than skip the write, or Dark → System keeps the override.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies `AppearanceMode` to the running app.
///
/// Sets `NSApplication.appearance`, not SwiftUI's `preferredColorScheme`, which reaches only the
/// SwiftUI tree of its own scene. The theme must also cover AppKit surfaces that inherit from
/// `NSApp`: the alerts and `NSOpenPanel` in `NativeAlerts`, the About panel, and the auxiliary
/// windows. Otherwise a Dark app would still throw a light alert. Set once, every window inherits.
@MainActor
public enum AppAppearance {
    /// The persisted mode; `.system` for a fresh install or an unrecognized stored value.
    public static func resolved(_ defaults: UserDefaults = .standard) -> AppearanceMode {
        AppearanceMode(rawValue: defaults.string(forKey: LiquidGlass.appearanceModeKey) ?? "") ?? .system
    }

    /// Pins (or, for `.system`, un-pins) the whole app's appearance.
    ///
    /// The per-window pass is needed for windows already on screen: their SwiftUI content follows
    /// `NSApplication.appearance`, but the macOS 26 glass title-bar band keeps its creation-time
    /// appearance, leaving a dark strip on a light window until relaunch. Re-asserting it per
    /// window makes AppKit rebuild that band. Later windows inherit from `NSApp`.
    public static func apply(_ mode: AppearanceMode) {
        pin(mode, onto: NSApplication.shared, windows: NSApplication.shared.windows)
    }

    /// The whole of `apply`, with its targets handed in, so a test can run the per-window pass on
    /// its own windows. The production pass writes every open window, which under a parallel run
    /// would clobber the appearance a render suite pinned on its window.
    static func pin(_ mode: AppearanceMode, onto app: NSApplication, windows: [NSWindow]) {
        let appearance = mode.nsAppearance
        app.appearance = appearance
        for window in windows {
            window.appearance = appearance
        }
    }

    /// Applies whatever is stored. Idempotent, so it is safe on every launch and on every change.
    public static func applyPersisted(_ defaults: UserDefaults = .standard) {
        apply(resolved(defaults))
    }
}
