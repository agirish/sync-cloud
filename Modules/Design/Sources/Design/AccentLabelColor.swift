import SwiftUI
import AppKit

/// Label contrast on a solid fill, computed from the fill's own luminance: dark text on light
/// fills, white on the rest. `NSColor.alternateSelectedControlTextColor` can't do this: it is
/// white under every accent, paired with the system's darkened selection fill. Accent fills
/// deepen instead (`AccentFill`) and always take white.
public enum AccentLabel {

    /// Whether a fill with the given sRGB components needs dark text: true when white text on it
    /// would fall below ~3:1 contrast (WCAG large-text minimum). White-on-fill contrast is
    /// (1.0 + 0.05) / (L + 0.05), which crosses 3:1 at L = 0.30.
    public static func prefersDarkText(red: CGFloat, green: CGFloat, blue: CGFloat) -> Bool {
        relativeLuminance(red: red, green: green, blue: blue) > 0.30
    }

    /// The strongest dimming an on-fill label (`onFillLabel(_:)` / `onAccentLabelColor`) can take
    /// and still clear WCAG's large-text 3:1 over every glass hue. White on Graphite binds: 0.9
    /// lands at ~3.14:1, 0.85 falls under. Secondary runs on an accent fill must dim with this
    /// constant, never a local literal;
    /// `AccentLabelColorTests.everyGlassHueDimmedLabelClearsLargeTextContrast` checks every hue.
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
    /// Text/glyph colour for content on an arbitrary solid `fill`, by its luminance: near-black on
    /// light fills, white on dark ones. Ignores light/dark mode, since the fill is the background.
    /// The one on-fill glyph path; nothing should hand-roll this pairing.
    ///
    /// `fill` must be static. A dynamic one (`Color.accentColor`, a semantic `NSColor`) resolves
    /// once at call time and won't follow an appearance change.
    static func onFillLabel(_ fill: Color) -> Color {
        guard let rgb = NSColor(fill).usingColorSpace(.sRGB) else { return .white }
        return AccentLabel.prefersDarkText(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            ? Color.black.opacity(0.85)
            : .white
    }
}
