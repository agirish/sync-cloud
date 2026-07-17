import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Whether the app renders light or dark — the *theme* half of Appearance, orthogonal to both
/// `GlassLevel` (material) and `SurfaceStyle` (shape). Every combination is valid: dark frosted
/// cards, light solid unified, and so on.
///
/// `.system` is the default and the macOS-native behavior: the app follows System Settings ▸
/// Appearance, including a mid-session switch and the Auto light/dark schedule. `.light` and
/// `.dark` pin the app against the system, for the common cases of wanting a dark file manager
/// on a light desktop (or the reverse) without changing the whole machine.
///
/// Stored in UserDefaults via `LiquidGlass.appearanceModeKey`.
public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    /// Follow macOS. The default — and the only case that tracks a mid-session system change.
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

    /// One-line explanation shown under the Settings picker.
    public var detail: String {
        switch self {
        case .system:
            return "Follow the macOS Appearance setting, including its automatic light/dark schedule."
        case .light:
            return "Always use the light appearance, even when macOS is set to dark."
        case .dark:
            return "Always use the dark appearance, even when macOS is set to light."
        }
    }

    #if canImport(AppKit)
    /// The appearance to pin `NSApplication` to. `nil` is not "no answer" — it is precisely how
    /// AppKit spells *inherit the system setting*, which is why `.system` must assign it rather
    /// than skip the write: switching Dark → System has to clear a previous override.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

#if canImport(AppKit)
/// Applies `AppearanceMode` to the running app.
///
/// This sets `NSApplication.appearance` rather than SwiftUI's `preferredColorScheme`, and the
/// distinction is load-bearing: `preferredColorScheme` only reaches the SwiftUI view tree of the
/// scene it is attached to. SyncCloud's theme has to cover the AppKit surfaces too — the
/// `NSAlert` collision/confirmation prompts and `NSOpenPanel` in `NativeAlerts`, the standard
/// About panel, and the separate Activity Log / Sync History / Keyboard Shortcuts windows. Those
/// inherit from `NSApp` and would otherwise stay on the system appearance, so a "Dark" app would
/// still throw a light alert.
///
/// Being an app-level property is also why no new key has to be threaded through the ~13 views
/// that each re-derive `GlassLevel` from `@AppStorage`: the appearance is set once and every
/// window, panel and alert inherits it.
@MainActor
public enum AppAppearance {
    /// The persisted mode, defaulting to `.system` for both a fresh install and an unrecognized
    /// stored value.
    public static func resolved(_ defaults: UserDefaults = .standard) -> AppearanceMode {
        AppearanceMode(rawValue: defaults.string(forKey: LiquidGlass.appearanceModeKey) ?? "") ?? .system
    }

    /// Pins (or, for `.system`, un-pins) the whole app's appearance.
    public static func apply(_ mode: AppearanceMode) {
        NSApplication.shared.appearance = mode.nsAppearance
    }

    /// Applies whatever is stored. Idempotent, so it is safe on every launch and on every change.
    public static func applyPersisted(_ defaults: UserDefaults = .standard) {
        apply(resolved(defaults))
    }
}
#endif
