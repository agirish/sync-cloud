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

    @Test func testEveryFamilyKeepsItsDotVisibleInBothAppearances() {
        // 3:1, the floor for non-text indicators. The obvious "system orange" fails it on a light
        // amber fill, which is why the light dots are darker than they look.
        for family in SemanticCapsuleFamily.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let style = SemanticCapsuleStyle.of(family, scheme)
                let ratio = contrast(style.dot, style.fill)
                #expect(ratio >= 3.0, "\(family)/\(scheme) dot is \(ratio):1 on its own fill")
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

    @Test func testTheDotIsTheMostColorfulMemberOfItsFamily() {
        // The smallest element gets the strongest hue, having the least area to show it. Measured
        // as chroma (max − min), not HSV saturation: the near-black brown dark fill has a higher
        // HSV saturation than the bright orange dot, though the eye sees the opposite.
        func chroma(_ color: Color) -> CGFloat {
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
            let channels = [c.redComponent, c.greenComponent, c.blueComponent]
            guard let high = channels.max(), let low = channels.min() else { return 0 }
            return high - low
        }
        for scheme in [ColorScheme.light, .dark] {
            let style = SemanticCapsuleStyle.of(.attention, scheme)
            #expect(chroma(style.dot) > chroma(style.fill))
            #expect(chroma(style.dot) >= chroma(style.content))
        }
    }

    /// The `onAccent` path's dot is legible by its ring, which is the fill's paired label colour, so
    /// this asserts the pairing other accent-filled controls rely on also does this job. Runs over
    /// every named hue: the pill follows the hue, so one whose ring vanished would leave the dot
    /// with no boundary.
    @MainActor
    @Test func testTheRingedDotStaysBoundedOnEveryAccentHue() throws {
        for hue in LiquidGlassHue.allCases where hue != .none {
            // `.none` is the system accent, a dynamic color with no fixed value to measure.
            // `accentFillColor` matches the call site; the raw accent is a pairing the app never
            // draws.
            let style = SemanticCapsuleStyle.onAccent(fill: hue.accentFillColor, label: hue.onAccentLabelColor)
            let ring = try #require(style.dotRing, "\(hue) accent capsule shipped an unringed dot")
            let ratio = contrast(ring, style.fill)
            #expect(ratio >= 3.0, "\(hue) dot ring is \(ratio):1 on its own accent fill")
        }
    }

    /// Why the ring exists: no terracotta colour clears 3:1 on the Green accent fill (not the
    /// on-accent value, the family's darker dot, or a pale peach). White would, but carries no
    /// attention signal, so the ring is what makes a warm dot possible. If a re-tune lets a warm dot
    /// stand alone this fails and the ring becomes removable; until then, removing it drops the dot
    /// below the floor.
    @MainActor
    @Test func testNoWarmDotColorCouldClearTheFloorOnTheGreenAccentFill() {
        let fill = LiquidGlassHue.green.accentFillColor
        for candidate in [SemanticCapsuleStyle.attentionDotOnAccent,
                          SemanticCapsuleStyle.of(.attention, .light).dot,
                          Color(red: 0.95, green: 0.77, blue: 0.66)] {   // pale peach
            #expect(contrast(candidate, fill) < 3.0)
        }
        #expect(contrast(.white, fill) >= 3.0)
    }

    /// The structural half of the rule `StatPill` branches on: a ring iff the fill is an accent.
    /// A flat family that grew one would draw a boundary its dot doesn't need; an accent capsule
    /// that lost one would drop below the floor the test above measures.
    @MainActor
    @Test func testOnlyTheAccentCapsuleCarriesARing() {
        for family in SemanticCapsuleFamily.allCases {
            for scheme in [ColorScheme.light, .dark] {
                #expect(SemanticCapsuleStyle.of(family, scheme).dotRing == nil)
            }
        }
        #expect(SemanticCapsuleStyle.onAccent(fill: .green, label: .black).dotRing != nil)
    }

    @Test func testFamiliesAreDistinguishableFromEachOther() {
        // Attention must not read as neutral at a glance, in either appearance.
        for scheme in [ColorScheme.light, .dark] {
            let attention = SemanticCapsuleStyle.of(.attention, scheme)
            let neutral = SemanticCapsuleStyle.of(.neutral, scheme)
            #expect(attention.fill != neutral.fill)
            #expect(attention.dot != neutral.dot)
        }
    }
}
