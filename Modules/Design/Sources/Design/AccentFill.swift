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
        Color(nsColor: NSColor(name: nil) { appearance in
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = NSColor(color).usingColorSpace(.sRGB)
            }
            guard let srgb = resolved else { return NSColor(color) }
            return deepened(srgb)
        })
    }

    /// The scalar step, on already-resolved sRGB components. Exposed to the tests so they can assert
    /// the contrast this type promises against real numbers instead of a rendered pixel.
    public static func deepened(_ srgb: NSColor) -> NSColor {
        let (r, g, b) = (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
        let luminance = AccentLabel.relativeLuminance(red: r, green: g, blue: b)
        guard luminance > targetLuminance else { return srgb }
        let k = targetLuminance / luminance
        func scaled(_ component: CGFloat) -> CGFloat { encode(linear(component) * k) }
        return NSColor(srgbRed: scaled(r), green: scaled(g), blue: scaled(b), alpha: srgb.alphaComponent)
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
