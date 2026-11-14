import AppKit
import SwiftUI
import Testing
@testable import Design

/// Contrast for `SemanticCapsuleStyle`, computed from the colors themselves. Every family is
/// measured against its own fill, the only backdrop a flat semantic capsule has, which is why it
/// can be hue-independent.
@Suite struct SemanticCapsuleTests {

    /// WCAG contrast ratio between two colors, via `AccentLabel`'s luminance (the module's one
    /// implementation of the formula).
    private func contrast(_ a: Color, _ b: Color) -> Double {
        func luminance(_ color: Color) -> CGFloat {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
            return AccentLabel.relativeLuminance(red: srgb.redComponent,
                                                 green: srgb.greenComponent,
                                                 blue: srgb.blueComponent)
        }
        let (high, low) = {
            let x = luminance(a), y = luminance(b)
            return x > y ? (x, y) : (y, x)
        }()
        return Double((high + 0.05) / (low + 0.05))
    }

    @Test func testEveryFamilyKeepsItsLabelReadableInBothAppearances() {
        // 4.5:1 — WCAG AA for body text. These capsules carry 11pt text, so the large-text
        // exemption does not apply to them.
        for family in SemanticCapsuleFamily.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let style = SemanticCapsuleStyle.of(family, scheme)
                let ratio = contrast(style.content, style.fill)
                #expect(ratio >= 4.5, "\(family)/\(scheme) label is \(ratio):1 on its own fill")
            }
        }
    }

    /// The differences count pill nests a semantic capsule inside its accent capsule: the age run,
    /// `.attention` when the scan is stale and `.neutral` while one runs. That fill can't carry the
    /// boundary against an accent on its own, which is why `StatPill.detailStyle` rings the run.
    @Test func testAnInsetRunCannotRelyOnItsOwnFillAgainstAnAccent() {
        var worst = Double.infinity
        for family in SemanticCapsuleFamily.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let inset = SemanticCapsuleStyle.of(family, scheme)
                for hue in LiquidGlassHue.allCases {
                    worst = min(worst, contrast(inset.fill, hue.accentFillColor))
                }
            }
        }
        // Dark `.neutral` on the Indigo accent is the floor, under the 3:1 a non-text boundary
        // needs. If a palette change lifts every pair clear of 3:1 this fails, to say the ring may
        // have become optional.
        #expect(worst < 3.0, "every inset/accent pair now clears 3:1 (worst \(worst):1) — the ring in StatPill.detailStyle may no longer be load-bearing")
    }

    /// …and the ring is the guarantee instead. It is `onAccentLabelColor`, which
    /// `AccentFill.deepened` promises clears 4.55:1 on its paired fill, so it separates the inset
    /// run from the accent on every hue whatever the run's own fill is.
    @Test func testTheInsetRunsRingIsSeparatedFromEveryAccent() {
        for hue in LiquidGlassHue.allCases {
            let ratio = contrast(hue.onAccentLabelColor, hue.accentFillColor)
            #expect(ratio >= 3.0, "\(hue) ring is \(ratio):1 on its own accent fill")
        }
    }

    @Test func testFamiliesAreDistinguishableFromEachOther() {
        // Attention must not read as neutral at a glance, in either appearance.
        for scheme in [ColorScheme.light, .dark] {
            let attention = SemanticCapsuleStyle.of(.attention, scheme)
            let neutral = SemanticCapsuleStyle.of(.neutral, scheme)
            #expect(attention.fill != neutral.fill)
        }
    }
}
