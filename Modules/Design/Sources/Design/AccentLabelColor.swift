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

    /// WCAG relative luminance of sRGB components (linearized, Rec. 709 weights).
    public static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The current pairing for `NSColor.controlAccentColor`. Resolved on every call — never cached
    /// at launch — so a System Settings accent change picks up the right pairing on the app's next
    /// render (the system triggers one when the accent changes).
    ///
    /// Resolved under the app's *effective* appearance, not `NSAppearance.currentDrawing()`: during
    /// a SwiftUI body evaluation the drawing appearance isn't guaranteed to be the one the fill
    /// will render under, and with the Theme control pinning the app against the system the two
    /// can genuinely differ. Graphite is the accent that makes this visible — its light and dark
    /// variants straddle the 0.30 luminance cutoff, so pairing against the wrong variant flips
    /// the label to the illegible side.
    @MainActor
    public static var currentPrefersDarkText: Bool {
        var resolved: NSColor?
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        }
        guard let accent = resolved else { return false }
        return prefersDarkText(red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent)
    }
}

public extension Color {
    /// Text/glyph color for content drawn on a `Color.accentColor` fill: near-black on light
    /// accents (Yellow), white otherwise. See `AccentLabel` for why the AppKit "system pairing"
    /// color can't do this job.
    @MainActor
    static var onAccentLabel: Color {
        AccentLabel.currentPrefersDarkText ? Color.black.opacity(0.85) : .white
    }

    /// Text/glyph color for content drawn on an arbitrary solid `fill`, by the same luminance rule
    /// `onAccentLabel` applies to the system accent: near-black on light fills (amber, cyan), white
    /// on dark ones. Appearance-independent by design — the fill is the background here, so the
    /// window's light/dark mode doesn't enter into it.
    ///
    /// `fill` must be a *static* color. A dynamic one (`Color.accentColor`, a semantic
    /// `NSColor`) collapses to whatever the current appearance resolves it to at call time and
    /// won't re-resolve when that changes — use `onAccentLabel` for the system accent instead.
    static func onFillLabel(_ fill: Color) -> Color {
        guard let rgb = NSColor(fill).usingColorSpace(.sRGB) else { return .white }
        return AccentLabel.prefersDarkText(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            ? Color.black.opacity(0.85)
            : .white
    }
}
