import Testing
import Foundation
import AppKit
@testable import Design

/// The theme half of the Appearance model: the stored value → `AppearanceMode` resolution, and
/// the mapping onto the AppKit appearance that `NSApp` is pinned to.
struct AppearanceModeTests {

    // MARK: - Resolution from UserDefaults

    /// A fresh install has no stored key. Following macOS is the only defensible default — it is
    /// what the app did before this control existed, so upgrading installs see no visual change.
    @MainActor
    @Test func freshInstallFollowsTheSystem() {
        let defaults = Self.emptyDefaults()
        #expect(AppAppearance.resolved(defaults) == .system)
    }

    /// A value written by a future (or corrupted) build must not brick the theme: fall back to
    /// following macOS rather than resolving to a pinned appearance the user never chose.
    @MainActor
    @Test func unrecognizedStoredValueFallsBackToSystem() {
        let defaults = Self.emptyDefaults()
        defaults.set("solarized", forKey: LiquidGlass.appearanceModeKey)
        #expect(AppAppearance.resolved(defaults) == .system)
    }

    @MainActor
    @Test func eachModeRoundTripsThroughDefaults() {
        let defaults = Self.emptyDefaults()
        for mode in AppearanceMode.allCases {
            defaults.set(mode.rawValue, forKey: LiquidGlass.appearanceModeKey)
            #expect(AppAppearance.resolved(defaults) == mode)
        }
    }

    // MARK: - The AppKit mapping

    /// The load-bearing case. `.system` must map to nil — not to `.aqua`, and not to "skip the
    /// write" — because nil is how AppKit spells *inherit the system setting*. Mapping it to
    /// `.aqua` would pin every System user to light; skipping the write would strand a user who
    /// switches Dark → System on the old override.
    @Test func systemMapsToNilSoAppKitInheritsTheSystemSetting() {
        #expect(AppearanceMode.system.nsAppearance == nil)
    }

    @Test func pinnedModesMapToTheirAppKitAppearances() {
        #expect(AppearanceMode.light.nsAppearance?.name == .aqua)
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)
    }

    /// `bestMatch` is what the codebase's adaptive colors (`ProviderHue.tint`) actually call to
    /// decide light vs dark, so pin that a pinned appearance answers the way those colors expect.
    @Test func pinnedAppearancesResolveThroughBestMatchTheWayAdaptiveColorsRead() {
        #expect(AppearanceMode.dark.nsAppearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(AppearanceMode.light.nsAppearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    // MARK: - Presentation

    /// The picker is built from `allCases`, so its order is the on-screen order: System first as
    /// the default, then light → dark.
    @Test func casesArePresentedSystemLightDark() {
        #expect(AppearanceMode.allCases == [.system, .light, .dark])
    }

    @Test func everyModeHasAnAccurateLabelAndDetail() {
        #expect(AppearanceMode.system.displayName == "System")
        #expect(AppearanceMode.light.displayName == "Light")
        #expect(AppearanceMode.dark.displayName == "Dark")
        for mode in AppearanceMode.allCases {
            #expect(!mode.detail.isEmpty)
        }
    }

    /// The theme is orthogonal to the material and shape controls — it shares no defaults key
    /// with them, so choosing Dark can't disturb a stored GlassLevel/SurfaceStyle.
    @Test func themeKeyIsDistinctFromTheOtherAppearanceKeys() {
        let keys = [
            LiquidGlass.appearanceModeKey,
            LiquidGlass.levelKey,
            LiquidGlass.surfaceStyleKey,
            LiquidGlass.hueKey,
            LiquidGlass.tintKey,
        ]
        #expect(Set(keys).count == keys.count)
    }

    // MARK: - The per-window pass

    /// The pass exists because of a shipped bug — the macOS 26 glass title-bar band kept the OLD
    /// appearance on a Dark → Light switch until relaunch, so `apply` re-asserts the value on
    /// every open window — and nothing pinned it: resolution was tested to the last raw value
    /// while the one function that touches AppKit had zero coverage. Driven through the `pin`
    /// seam with THIS test's own windows (never `NSApp.windows` — that would clobber the
    /// appearance a parallel render suite just pinned on its window); `apply`'s only other line
    /// is feeding `pin` the real app and window list, pinned by the scan below.
    ///
    /// The un-pin half matters as much as the pin: `.system` must write nil onto every window,
    /// or a once-pinned window stays stuck in its old appearance after the user returns to
    /// following the system.
    @MainActor
    @Test func pinWritesEveryWindowAndSystemUnpins() {
        let app = NSApplication.shared
        let saved = app.appearance
        defer { app.appearance = saved }
        // Parked far offscreen, per the house convention — ordered-in is not on a display.
        let windows = (0..<2).map { _ in
            let w = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: 80, height: 60),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            return w
        }
        defer { windows.forEach { $0.orderOut(nil) } }

        AppAppearance.pin(.dark, onto: app, windows: windows)
        #expect(app.appearance?.name == .darkAqua)
        #expect(windows.allSatisfy { $0.appearance?.name == .darkAqua })

        AppAppearance.pin(.light, onto: app, windows: windows)
        #expect(app.appearance?.name == .aqua)
        #expect(windows.allSatisfy { $0.appearance?.name == .aqua })

        AppAppearance.pin(.system, onto: app, windows: windows)
        #expect(app.appearance == nil)
        #expect(windows.allSatisfy { $0.appearance == nil },
                "the un-pin must reach every window, or a once-pinned window is stuck until relaunch")
    }

    /// The call-site half: `apply` must feed `pin` the real app and the real window list. One
    /// line, but it is the line whose absence was the original bug (app-only, windows skipped).
    @Test func applyFeedsPinTheRealAppAndItsWindows() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Design/AppearanceMode.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8))
        try #require(source.count > 500, "AppearanceMode.swift read truncated — the scan would be vacuous")
        #expect(source.contains("pin(mode, onto: NSApplication.shared, windows: NSApplication.shared.windows)"),
                "apply no longer hands pin the open windows — the glass title-bar bug is back for on-screen windows")
    }

    // MARK: -

    /// An isolated defaults suite, so these never read or write the developer's real preferences.
    /// A fresh UUID suite is already empty, and it removes itself — domain and plist — on release.
    private static func emptyDefaults() -> ScratchDefaults {
        ScratchDefaults("AppearanceModeTests")
    }
}
