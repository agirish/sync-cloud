import Testing
import AppKit
import SwiftUI
@testable import Design

/// Pins the on-accent label pairing (round-5 fix): the round-4 attempt used
/// `alternateSelectedControlTextColor`, which AppKit returns as white under EVERY accent, so
/// white-on-Yellow (~1.6:1) shipped unchanged. The pairing is now derived from the accent's own
/// luminance; these tests pin the decision function against the actual system accent values.
@Suite struct AccentLabelColorTests {

    @Test func lightAccentsGetDarkText() {
        // macOS Yellow accent (systemYellow ≈ 1.0, 0.8, 0.0): white on it is ~1.6:1.
        #expect(AccentLabel.prefersDarkText(red: 1.0, green: 0.8, blue: 0.0))
        // macOS Green accent (systemGreen ≈ 0.16, 0.80, 0.25): white on it is ~2.1:1.
        #expect(AccentLabel.prefersDarkText(red: 0.16, green: 0.80, blue: 0.25))
    }

    @Test func darkAccentsKeepWhiteText() {
        // Blue (default accent), Purple, Red: white text well above 3:1.
        #expect(!AccentLabel.prefersDarkText(red: 0.0, green: 0.48, blue: 1.0))
        #expect(!AccentLabel.prefersDarkText(red: 0.69, green: 0.32, blue: 0.87))
        #expect(!AccentLabel.prefersDarkText(red: 1.0, green: 0.23, blue: 0.19))
    }

    @Test func luminanceMatchesKnownAnchors() {
        // Pure white/black anchor the WCAG formula; drift here means the linearization broke.
        #expect(abs(AccentLabel.relativeLuminance(red: 1, green: 1, blue: 1) - 1.0) < 0.001)
        #expect(AccentLabel.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
    }

    @MainActor
    @Test func currentAccentResolvesWithoutCrashing() {
        // Whatever accent the test host runs under, the dynamic resolution must produce a
        // decision (exercises the usingColorSpace conversion path).
        _ = AccentLabel.currentPrefersDarkText
        _ = SwiftUI.Color.onAccentLabel
    }

    @Test func fillLabelSplitsOnTheFillsOwnLuminance() {
        // The two branches of `onFillLabel`, pinned on the hues that sit either side of the 0.30
        // cutoff: amber (L ≈ 0.42) takes near-black, indigo (L ≈ 0.19) keeps white.
        #expect(SwiftUI.Color.onFillLabel(LiquidGlassHue.amber.accentColor) == Color.black.opacity(0.85))
        #expect(SwiftUI.Color.onFillLabel(LiquidGlassHue.indigo.accentColor) == .white)
    }

    /// The invariant the Settings swatch checkmark violated: it painted a hardcoded white on every
    /// hue, which is ~2.1:1 on amber and ~2.5:1 on cyan. Every hue's label must clear the WCAG
    /// large-text 3:1 minimum against the swatch fill it is drawn on — the composited contrast,
    /// since the near-black branch is 85% opaque and the fill shows through it.
    @Test func everyGlassHueLabelClearsLargeTextContrast() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = srgb(hue.accentColor)
            let label = srgb(SwiftUI.Color.onFillLabel(hue.accentColor))
            let ratio = contrast(luminance(of: composite(label, over: fill)), luminance(of: fill))
            #expect(ratio >= 3.0, "\(hue) label is only \(ratio):1 on its own swatch")
        }
    }

    /// The dimmed twin of the invariant above, for secondary runs on an accent fill (the Log
    /// window's selected-chip count): the label dimmed to `AccentLabel.dimmedOnFillOpacity` must
    /// STILL clear 3:1 on every hue. Graphite is the binding pair — white on it sits ~0.5 above
    /// the floor at full strength, the old ad-hoc 0.85 dim fell to ~2.97:1, and 0.9 is the
    /// strongest dimming that stays legal (~3.14:1). Pinned per-hue so a future hue addition
    /// (or a "harmless" bump of the constant) can't slide back under the floor unnoticed.
    @Test func everyGlassHueDimmedLabelClearsLargeTextContrast() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = srgb(hue.accentColor)
            let dimmed = SwiftUI.Color.onFillLabel(hue.accentColor)
                .opacity(AccentLabel.dimmedOnFillOpacity)
            let label = srgb(dimmed)
            let ratio = contrast(luminance(of: composite(label, over: fill)), luminance(of: fill))
            #expect(ratio >= 3.0, "\(hue) dimmed label is only \(ratio):1 on its own fill")
        }
    }

    // MARK: - Contrast helpers

    private func srgb(_ color: Color) -> NSColor {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            Issue.record("\(color) has no sRGB representation")
            return .white
        }
        return converted
    }

    /// Alpha-composites `label` onto an opaque `fill`, which is what the eye actually sees: the
    /// near-black branch is `.opacity(0.85)`, so the fill lifts it before contrast is measured.
    private func composite(_ label: NSColor, over fill: NSColor) -> NSColor {
        let a = label.alphaComponent
        func blend(_ l: CGFloat, _ f: CGFloat) -> CGFloat { l * a + f * (1 - a) }
        return NSColor(
            srgbRed: blend(label.redComponent, fill.redComponent),
            green: blend(label.greenComponent, fill.greenComponent),
            blue: blend(label.blueComponent, fill.blueComponent),
            alpha: 1
        )
    }

    private func luminance(of color: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    private func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let (hi, lo) = (max(a, b), min(a, b))
        return (hi + 0.05) / (lo + 0.05)
    }
}
