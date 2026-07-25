import SwiftUI
import AppKit

/// The label color that stays legible on a raw `Color.accentColor` fill.
///
/// Why `NSColor.alternateSelectedControlTextColor` was insufficient (the round-4 attempt): AppKit
/// returns WHITE for it under every accent — it is the companion to the system's *selection* fill
/// (`selectedContentBackgroundColor`, a darkened accent), not to the raw accent our chips and rows
/// fill with. Under the Yellow accent, white on raw accent is ~1.6:1 — unreadable. So the pairing
/// is computed here from the accent's own luminance instead: dark text on light accents (Yellow),
/// white on the rest.
public enum AccentLabel {

    /// Whether a fill with the given sRGB components needs dark text: true when white text on it
    /// would fall below ~3:1 contrast (WCAG large-text minimum). White-on-fill contrast is
    /// (1.0 + 0.05) / (L + 0.05), which crosses 3:1 at L = 0.30.
    public static func prefersDarkText(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        relativeLuminance(red: red, green: green, blue: blue) > 0.30
    }

    /// The strongest dimming an on-fill label (`onFillLabel(_:)` / `onAccentLabelColor`) can take and
    /// still clear the WCAG large-text 3:1 floor over every glass hue. The binding pair is white
    /// on Graphite (L = 0.25, the lightest fill that still keeps white text): full-strength white
    /// composites to ~3.5:1 there, 0.9 lands at ~3.14:1, and the old ad-hoc 0.85 fell to ~2.97:1 —
    /// under the floor. Secondary runs on an accent fill (the Log window's selected-chip count)
    /// must dim with THIS constant, never a local literal;
    /// `AccentLabelColorTests.everyGlassHueDimmedLabelClearsLargeTextContrast` pins the pairing
    /// against future hue additions.
    public static let dimmedOnFillOpacity: CGFloat = 0.9

    /// WCAG relative luminance of sRGB components (linearized, Rec. 709 weights).
    public static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

}

public extension Color {
    /// Text/glyph color for content drawn on an arbitrary solid `fill`, by its luminance:
    /// near-black on light fills (amber, cyan), white on dark ones. Appearance-independent by
    /// design — the fill is the background here, so the window's light/dark mode doesn't enter
    /// into it. THE on-fill glyph path; nothing should hand-roll this pairing.
    ///
    /// `fill` must be a *static* color. A dynamic one (`Color.accentColor`, a semantic `NSColor`)
    /// collapses to whatever the current appearance resolves it to at call time and won't
    /// re-resolve when that changes.
    static func onFillLabel(_ fill: Color) -> Color {
        guard let rgb = NSColor(fill).usingColorSpace(.sRGB) else { return .white }
        return AccentLabel.prefersDarkText(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            ? Color.black.opacity(0.85)
            : .white
    }
}
