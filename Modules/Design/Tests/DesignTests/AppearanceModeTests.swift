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

    // MARK: -

    /// An isolated defaults suite, so these never read or write the developer's real preferences.
    private static func emptyDefaults() -> UserDefaults {
        let suite = "AppearanceModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
