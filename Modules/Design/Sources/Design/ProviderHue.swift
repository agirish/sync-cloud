import SwiftUI

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

    /// The full-strength brand hue, for tinting a provider's name text or glyph.
    /// Brand blues are nudged apart so iCloud and Dropbox stay distinguishable:
    /// iCloud sits at a lighter sky blue (#3B9CFF) vs Dropbox's saturated #0061FF.
    public var tint: Color {
        switch self {
        case .iCloud: return Color(red: 0.231, green: 0.612, blue: 1.0)      // #3B9CFF
        case .dropbox: return Color(red: 0.0, green: 0.380, blue: 1.0)       // #0061FF
        case .googleDrive: return Color(red: 0.118, green: 0.639, blue: 0.384) // #1EA362
        case .oneDrive: return Color(red: 0.012, green: 0.392, blue: 0.722)  // #0364B8
        case .box: return Color(red: 0.141, green: 0.525, blue: 0.988)       // #2486FC
        case .neutral: return .accentColor
        }
    }

    /// Low-opacity companion for background washes, mirroring the app's soft-tint chips
    /// (StatusBadge uses the same 0.12 fill under full-strength foregrounds).
    public var soft: Color {
        tint.opacity(0.12)
    }
}
