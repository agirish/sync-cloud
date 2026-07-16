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

    @Test func currentAccentResolvesWithoutCrashing() {
        // Whatever accent the test host runs under, the dynamic resolution must produce a
        // decision (exercises the usingColorSpace conversion path).
        _ = AccentLabel.currentPrefersDarkText
        _ = SwiftUI.Color.onAccentLabel
    }
}
