import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// UX H2: each provider's brand hue, so the two panes stop blurring together. Every
/// provider-identity element (sidebar name, pane-header name, root breadcrumb) used to wear
/// the one app accent; classifying the display name here lets iCloud/Dropbox/Drive panes read
/// as themselves at a glance — and it does double duty when both panes show the *same*
/// provider (D3), because the matching hues say so instantly.
///
/// Design deliberately has no Sync dependency, so this classifies by case-insensitive
/// substring of the provider's *display name* (which users can rename) rather than by
/// `CloudProvider.ProviderType`. Unrecognized/custom providers fall back to the app accent,
/// so custom setups keep the user's chosen look.
///
/// `public` is load-bearing: this crosses module boundaries, and an internal symbol passes
/// `swift test` but breaks the xcodebuild app build.
public enum ProviderHue: String, CaseIterable, Sendable {
    case iCloud
    case dropbox
    case googleDrive
    case oneDrive
    case box
    /// Unrecognized/custom providers: follow the app accent instead of inventing a hue.
    case neutral

    /// Maps a provider display name to its hue. Substring order is load-bearing:
    /// - "iCloud Drive" contains "drive", so iCloud must win before the Drive check.
    /// - "OneDrive" contains "drive", so OneDrive must also precede the Drive check.
    /// - "Dropbox" contains "box", so Dropbox must precede the Box check.
    public static func classify(_ displayName: String) -> ProviderHue {
        let name = displayName.lowercased()
        if name.contains("icloud") { return .iCloud }
        if name.contains("dropbox") { return .dropbox }
        if name.contains("onedrive") { return .oneDrive }
        if name.contains("drive") { return .googleDrive }
        if name.contains("box") { return .box }
        return .neutral
    }

    /// One appearance's brand RGB, 0…1. Pure data so the dark-mode contrast audit (H6) can
    /// assert luminances without rendering.
    public struct RGB: Equatable, Sendable {
        public let r, g, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }

        /// WCAG relative luminance — the audit's yardstick.
        public var relativeLuminance: Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
    }

    /// The light- and dark-appearance brand hues. Light values are the on-brand hexes tuned
    /// against a light ground; dark values are lifted toward the top of each hue so tinted
    /// provider text clears WCAG AA on the app's dark surfaces — the darker brand blues
    /// (Dropbox #0061FF ≈ 3.4:1, OneDrive #0364B8, Google Drive #1EA362) failed as static text
    /// in dark mode. Blues stay pulled apart so iCloud and Dropbox never read as one colour.
    public var brand: (light: RGB, dark: RGB)? {
        switch self {
        case .iCloud:      return (RGB(0.231, 0.612, 1.0),   RGB(0.435, 0.714, 1.0))   // #3B9CFF → #6FB6FF
        case .dropbox:     return (RGB(0.0,   0.380, 1.0),   RGB(0.298, 0.553, 1.0))   // #0061FF → #4C8DFF
        case .googleDrive: return (RGB(0.118, 0.639, 0.384), RGB(0.235, 0.796, 0.525)) // #1EA362 → #3CCB86
        case .oneDrive:    return (RGB(0.012, 0.392, 0.722), RGB(0.243, 0.608, 0.878)) // #0364B8 → #3E9BE0
        case .box:         return (RGB(0.141, 0.525, 0.988), RGB(0.353, 0.627, 1.0))   // #2486FC → #5AA0FF
        case .neutral:     return nil
        }
    }

    /// The full-strength brand hue, for tinting a provider's name text or glyph. Adaptive:
    /// light mode keeps the on-brand hex; dark mode uses the lifted variant so the text passes
    /// contrast. `neutral` follows the user's chosen app accent in both appearances.
    ///
    /// Cached per case: a dynamic `NSColor` is built once (not on every render), and a stable
    /// instance also lets `soft` stay `== tint.opacity(0.12)`.
    public var tint: Color { Self.tintCache[self] ?? .accentColor }

    private static let tintCache: [ProviderHue: Color] = {
        var table: [ProviderHue: Color] = [:]
        for hue in allCases {
            guard let brand = hue.brand else { continue } // neutral → .accentColor via the getter
            #if canImport(AppKit)
            table[hue] = Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let c = isDark ? brand.dark : brand.light
                return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
            })
            #else
            table[hue] = Color(red: brand.light.r, green: brand.light.g, blue: brand.light.b)
            #endif
        }
        return table
    }()

    /// Low-opacity companion for background washes, in the same family as the app's soft-tint chips
    /// (StatusBadge wears `PillVariant.fillOpacity`, 0.14, under full-strength foregrounds — this
    /// one is deliberately a touch lighter; the comment used to claim the two were identical).
    public var soft: Color {
        tint.opacity(0.12)
    }
}
