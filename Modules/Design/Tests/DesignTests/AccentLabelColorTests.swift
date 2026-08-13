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

    @Test func theOnFillPairingSurvivesAnUnconvertibleColor() {
        // `onFillLabel` converts to sRGB before measuring; a colour that can't convert must fall
        // back to white rather than trapping. (This replaces a test of the system-accent pairing
        // `Color.onAccentLabel`, removed with that API: the accent-fill model f2f72f8 settled on
        // pairs white against a DEEPENED fill for every hue, so a second, per-luminance on-accent
        // path existed only to be rediscovered and reintroduce the split.)
        #expect(SwiftUI.Color.onFillLabel(Color(nsColor: .textBackgroundColor)) != nil)
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

    /// The same invariant routed through the pair every accent-FILLED chip, pill and button uses
    /// (the workspace bar pill, the pane action buttons, the differences count pill, the Log
    /// window's selected chip): `accentFillColor` under `onAccentLabelColor`.
    ///
    /// Held to 4.5:1, not the 3:1 the old per-hue pairing settled for. That is the point of
    /// deepening the fill — the label is a flat white now, so the fill has to earn it outright
    /// rather than the pairing negotiating hue by hue, and body-text AA is what it earns.
    @Test func everyHueOnAccentFillCarriesItsLabelAtBodyTextContrast() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = srgb(hue.accentFillColor)
            let label = srgb(hue.onAccentLabelColor)
            let ratio = contrast(luminance(of: composite(label, over: fill)), luminance(of: fill))
            #expect(ratio >= 4.5, "\(hue) on-accent label is only \(ratio):1 on its deepened fill")
        }
    }

    /// Why the fill has to be deepened, stated as a test rather than a comment. White on the RAW
    /// accent is under the 3:1 floor on the MAJORITY of the palette — ~2.1:1 on cyan, ~2.2:1 on
    /// amber — so "just make the label white" is not available without moving the fill. Anyone
    /// tempted to fill with `accentColor` and write `.foregroundStyle(.white)` should land here first;
    /// `accentFillColor` is the fill that makes white legal.
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

    /// The dimmed twin of the invariant above, for secondary runs on an accent fill (the Log
    /// window's selected-chip count, the count pill's chevron): the label dimmed to
    /// `AccentLabel.dimmedOnFillOpacity` must STILL clear 3:1 on every hue.
    ///
    /// Deepening the fills moved the binding pair. It used to be white on Graphite, ~0.5 above the
    /// floor at full strength and 3.14:1 once dimmed, which is where the 0.9 constant came from.
    /// Now every fill is at or below the deepening ceiling, so the whole palette dims to ~4:1 and
    /// the constant has slack it did not have before. Kept at 0.9 rather than loosened: nothing
    /// wants a fainter secondary, and the slack is worth more as margin.
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
