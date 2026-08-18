import AppKit
import SwiftUI

/// Deepening a colour until a white label on it clears WCAG AA.
///
/// This exists because of the bind the app was in: half the twelve hues are light enough that white
/// text on the RAW accent is illegible — 2.68:1 on Green, 2.20:1 on Amber, against a 4.5:1 floor for
/// body text — so `LiquidGlassHue.onAccentLabelColor` used to answer by flipping the *label* to
/// near-black on those hues. That kept every pairing legible but made the filled controls read as
/// two different button families: white-on-Blue next to black-on-Green.
///
/// The other way out is to fix the label at white and move the *fill* instead, which is what this
/// does. Every solid accent surface fills with `LiquidGlassHue.accentFillColor` — the accent scaled
/// down in LINEAR light until its luminance can carry white — so one label colour is correct
/// everywhere by construction rather than by case analysis.
///
/// Scaling in linear space is the whole trick, and it is exact rather than approximate: luminance is
/// a linear combination of the linear components, so multiplying all three by `k` multiplies
/// luminance by exactly `k`, and the ratio between them — the chromaticity, i.e. the hue and
/// saturation you perceive — is untouched. The result reads as the same colour turned down, not as a
/// different colour. Doing the same arithmetic on the sRGB components (the obvious `r * k`) would
/// shift hue, because sRGB encoding is not linear in light.
///
/// The cost, stated plainly: filled controls on the light hues get materially darker. Green goes
/// rgb(0.20, 0.70, 0.50) → rgb(0.14, 0.53, 0.37); Amber and Cyan, which start lightest, move most.
/// That is not a side effect to be minimised — it IS the change, and the only alternative that
/// keeps white labels is shipping 2.2:1 text.
///
/// `Color.onFillLabel(_:)` and the luminance pairing behind it are still here and still correct for
/// fills this type does not own: treemap tiles, provider hues, anything taking its colour from data
/// rather than from the accent. Those are not buttons and cannot deepen their fills at will.
public enum AccentFill {

    /// Contrast a deepened fill is built to give a white label. 4.55 rather than a bare 4.5 so the
    /// margin survives 8-bit quantisation of the components on the way to the screen.
    public static let whiteLabelContrast: CGFloat = 4.55

    /// The luminance ceiling implied by `whiteLabelContrast`, from white-on-fill = (1.05) / (L + 0.05).
    public static let targetLuminance: CGFloat = 1.05 / whiteLabelContrast - 0.05

    /// `color` darkened just enough to carry a white label, or `color` unchanged when it already
    /// does. Never lightens: a hue that is already dark (Blue, Indigo) is left exactly as it is, so
    /// this is a no-op on roughly half the palette.
    ///
    /// Stays DYNAMIC. A dynamic input (`Color.accentColor`, the `.none` hue's system accent) must
    /// re-resolve when the appearance changes, so the deepening is deferred into an
    /// `NSColor(name:dynamicProvider:)` block rather than computed once at call time — the same trap
    /// `Color.onFillLabel(_:)` documents for static fills, met from the other side.
    public static func deepened(_ color: Color) -> Color {
        deepened(color, to: targetLuminance)
    }

    /// The luminance a semantic colour has to reach to be read as BODY TEXT on the app's light
    /// sheets, which is a stricter bar than carrying a white label.
    ///
    /// **Measured against the sheet, not asserted.** ``targetLuminance`` exists so a FILL can carry
    /// white at 4.5:1; used the other way round — coloured ink on a near-white ground — it lands at
    /// 4.17:1, because the two problems are not symmetric. Yellow is the case that shows it:
    /// `SemanticColor.caution` as bare `.foregroundStyle` measures **1.38:1** on a 0.96 sheet, and
    /// deepening to the fill target only reaches 4.17. This target clears 4.5 with margin.
    /// `SemanticInkContrastTests` measures every semantic colour against the floor rather than
    /// trusting this number.
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

    /// The scalar step, on already-resolved sRGB components. Exposed to the tests so they can assert
    /// the contrast this type promises against real numbers instead of a rendered pixel.
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

    /// The luminance a semantic colour has to REACH to be read as body text on the app's dark
    /// sheets — the mirror of ``textLuminance``, and needed for the same reason.
    ///
    /// **Measured, because the dark side is not automatically fine.** Leaving dark untouched is
    /// right for a GLYPH (`ChromeInk.semantic` does exactly that, and every semantic colour clears
    /// the 3:1 a glyph needs). It is not right for text: on a 0.13 sheet `SemanticColor.move`
    /// measures **3.86:1** against the 4.5 floor and `error` lands on 4.50 with nothing to spare.
    /// A member called `bodyText` that quietly misses its own bar for two of six colours is the
    /// kind of guard whose name is wider than what it does.
    /// 0.26, derived rather than picked: the app's darkest sheet is ~0.13 sRGB (linear 0.0144), and
    /// 4.5:1 against it needs a luminance of 0.2398. The margin above that is the same shape as
    /// ``textLuminance``'s on the light side.
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

    /// The scalar step. **Blends toward white rather than scaling each channel**, because scaling up
    /// clips: `SemanticColor.error` is already at full red, so a per-channel multiply raises green
    /// and blue against a red that cannot move and swings the hue. A blend keeps the colour
    /// recognisable, which is the whole reason a semantic colour is being used as ink.
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
