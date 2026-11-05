import AppKit
import SwiftUI

/// Deepening a colour until a white label on it clears WCAG AA. White on the raw light hues is
/// illegible (Green 2.68:1, Amber 2.20:1, against 4.5:1), and flipping those labels to black would
/// split filled controls into two families. So the label stays white and the fill moves: every
/// solid accent surface fills with `LiquidGlassHue.accentFillColor`, the accent scaled down in
/// LINEAR light, where scaling keeps hue and saturation exactly (in sRGB it would shift hue). The
/// cost is darker fills on the light hues, which is the point.
///
/// `Color.onFillLabel(_:)` still serves fills taken from data (treemap tiles, provider hues), which
/// cannot deepen at will.
public enum AccentFill {

    /// Contrast a deepened fill is built to give a white label. 4.55 rather than a bare 4.5 so the
    /// margin survives 8-bit quantisation of the components on the way to the screen.
    public static let whiteLabelContrast: CGFloat = 4.55

    /// The luminance ceiling implied by `whiteLabelContrast`, from white-on-fill = (1.05) / (L + 0.05).
    public static let targetLuminance: CGFloat = 1.05 / whiteLabelContrast - 0.05

    /// `color` darkened just enough to carry a white label, or unchanged when it already does.
    /// Never lightens, so dark hues (Blue, Indigo) are left exactly as they are.
    ///
    /// Stays dynamic: a dynamic input (`Color.accentColor`, the `.none` hue's system accent) must
    /// re-resolve when the appearance changes, so the work runs inside an
    /// `NSColor(name:dynamicProvider:)` block, not once at call time.
    public static func deepened(_ color: Color) -> Color {
        deepened(color, to: targetLuminance)
    }

    /// The luminance a semantic colour must reach to be read as body text on the app's light
    /// sheets, a stricter bar than carrying a white label: ``targetLuminance`` used as ink on a
    /// near-white ground reaches only 4.17:1. This one clears 4.5 with margin, and
    /// `SemanticInkContrastTests` measures every semantic colour against the floor.
    public static let textLuminance: CGFloat = 0.14

    /// `color` darkened enough to be read as text on a light sheet. See ``textLuminance``.
    public static func deepenedForText(_ color: Color) -> Color {
        deepened(color, to: textLuminance)
    }

    private static func deepened(_ color: Color, to target: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(color).usingColorSpace(.sRGB)
            }
            guard let srgb = resolved else { return NSColor(color) }
            return deepened(srgb, to: target)
        })
    }

    /// The scalar step, on already-resolved sRGB components. Public so tests can check the promised
    /// contrast on numbers rather than pixels.
    public static func deepened(_ srgb: NSColor) -> NSColor { deepened(srgb, to: targetLuminance) }

    /// The same step against an explicit target, so the text bar and the fill bar are one
    /// implementation rather than two that could drift.
    public static func deepened(_ srgb: NSColor, to target: CGFloat) -> NSColor {
        let (r, g, b) = (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
        let luminance = AccentLabel.relativeLuminance(red: r, green: g, blue: b)
        guard luminance > target else { return srgb }
        let k = target / luminance
        func scaled(_ component: CGFloat) -> CGFloat { encode(linear(component) * k) }
        return NSColor(srgbRed: scaled(r), green: scaled(g), blue: scaled(b), alpha: srgb.alphaComponent)
    }

    /// The luminance a semantic colour must reach to be read as body text on the app's dark sheets,
    /// the mirror of ``textLuminance``. Glyphs can stay untouched in dark (they need only 3:1, as
    /// `ChromeInk.semantic` relies on), but text cannot: `SemanticColor.move` misses 4.5:1 on a
    /// 0.13 sheet. Derived: 4.5:1 against that sheet (linear 0.0144) needs 0.2398, plus margin.
    public static let darkTextLuminance: CGFloat = 0.26

    /// `color` lightened enough to be read as text on a dark sheet, or unchanged when it already is.
    public static func lightenedForText(_ color: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(color).usingColorSpace(.sRGB)
            }
            guard let srgb = resolved else { return NSColor(color) }
            return lightened(srgb, to: darkTextLuminance)
        })
    }

    /// The scalar step. Blends toward white rather than scaling each channel, because scaling up
    /// clips: `SemanticColor.error` is already full red, so a multiply would swing its hue. A blend
    /// keeps the colour recognisable.
    public static func lightened(_ srgb: NSColor, to target: CGFloat) -> NSColor {
        let (r, g, b) = (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
        guard AccentLabel.relativeLuminance(red: r, green: g, blue: b) < target else { return srgb }
        // 24 steps of 1/24 reaches any target this table needs; the loop stops at the first that
        // clears it, so the colour moves as little as it has to.
        for step in 1...24 {
            let t = CGFloat(step) / 24
            let (mr, mg, mb) = (r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t)
            if AccentLabel.relativeLuminance(red: mr, green: mg, blue: mb) >= target {
                return NSColor(srgbRed: mr, green: mg, blue: mb, alpha: srgb.alphaComponent)
            }
        }
        return .white
    }

    /// sRGB component → linear light. Matches `AccentLabel.relativeLuminance`'s transfer function,
    /// which is the one the contrast figures are computed with.
    private static func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    /// Linear light → sRGB component. The inverse of `linear(_:)`, so a round trip is the identity.
    private static func encode(_ light: CGFloat) -> CGFloat {
        light <= 0.03928 / 12.92 ? light * 12.92 : 1.055 * pow(light, 1 / 2.4) - 0.055
    }
}
