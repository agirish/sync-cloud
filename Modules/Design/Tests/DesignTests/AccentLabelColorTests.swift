import Testing
import AppKit
import SwiftUI
@testable import Design

/// Pins the on-accent label pairing, derived from the accent's own luminance:
/// `alternateSelectedControlTextColor` is white under every accent, so it would put white on
/// Yellow (~1.6:1). These tests pin the decision function against the system accent values.
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

    @Test func theOnFillPairingSurvivesAnUnconvertibleColor() throws {
        // `onFillLabel` converts to sRGB before measuring; a colour that can't convert (a pattern)
        // must fall back to white rather than trapping.
        let pattern = Color(nsColor: NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1))))
        try #require(NSColor(pattern).usingColorSpace(.sRGB) == nil, "the pattern converts: the fallback is not reached")
        #expect(SwiftUI.Color.onFillLabel(pattern) == .white)
    }

    @Test func fillLabelSplitsOnTheFillsOwnLuminance() {
        // The two branches of `onFillLabel`, pinned on the hues that sit either side of the 0.30
        // cutoff: amber (L ≈ 0.42) takes near-black, indigo (L ≈ 0.19) keeps white.
        #expect(SwiftUI.Color.onFillLabel(LiquidGlassHue.amber.accentColor) == Color.black.opacity(0.85))
        #expect(SwiftUI.Color.onFillLabel(LiquidGlassHue.indigo.accentColor) == .white)
    }

    /// Every hue's label must clear the WCAG large-text 3:1 minimum against the swatch fill it is
    /// drawn on (a hardcoded white is ~2.1:1 on amber, ~2.5:1 on cyan). Measured composited, since
    /// the near-black branch is 85% opaque and the fill shows through it.
    @Test func everyGlassHueLabelClearsLargeTextContrast() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = srgb(hue.accentColor)
            let label = srgb(SwiftUI.Color.onFillLabel(hue.accentColor))
            let ratio = contrast(luminance(of: composite(label, over: fill)), luminance(of: fill))
            #expect(ratio >= 3.0, "\(hue) label is only \(ratio):1 on its own swatch")
        }
    }

    /// The same invariant through the pair every accent-filled chip, pill and button uses:
    /// `accentFillColor` under `onAccentLabelColor`. Held to body-text 4.5:1, since with the fill
    /// deepened the label is a flat white.
    @Test func everyHueOnAccentFillCarriesItsLabelAtBodyTextContrast() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = srgb(hue.accentFillColor)
            let label = srgb(hue.onAccentLabelColor)
            let ratio = contrast(luminance(of: composite(label, over: fill)), luminance(of: fill))
            #expect(ratio >= 4.5, "\(hue) on-accent label is only \(ratio):1 on its deepened fill")
        }
    }

    /// Why the fill has to be deepened. White on the raw accent is under the 3:1 floor on most of
    /// the palette (~2.1:1 on cyan, ~2.2:1 on amber), so a white label needs `accentFillColor`, not
    /// `accentColor` with `.foregroundStyle(.white)`.
    @Test func hardcodedWhiteOnAccentFailsOnMostHues() {
        let failing = LiquidGlassHue.allCases.filter { hue in
            guard hue != .none else { return false }
            let fill = srgb(hue.accentColor)
            return contrast(luminance(of: composite(srgb(.white), over: fill)), luminance(of: fill)) < 3.0
        }
        // Six of the eleven real hues: cyan, teal, green, amber, coral, rose.
        let realHues = LiquidGlassHue.allCases.filter { $0 != .none }
        #expect(failing.contains(.amber))
        #expect(failing.contains(.cyan))
        #expect(failing.count * 2 > realHues.count,
                "flat white cleared 3:1 on most hues — the palette changed, revisit the pairing rule")
    }

    /// The dimmed twin, for secondary runs on an accent fill: the label at
    /// `AccentLabel.dimmedOnFillOpacity` still clears 3:1 on every hue. The palette dims to about
    /// 4:1, and the 0.9 constant keeps that slack as margin.
    @Test func everyGlassHueDimmedLabelClearsLargeTextContrast() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = srgb(hue.accentFillColor)
            let dimmed = hue.onAccentLabelColor.opacity(AccentLabel.dimmedOnFillOpacity)
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
