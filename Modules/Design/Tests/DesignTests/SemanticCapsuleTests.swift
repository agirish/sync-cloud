import AppKit
import SwiftUI
import Testing
@testable import Design

/// Contrast for `SemanticCapsuleStyle`, computed from the colors themselves rather than read off a
/// comment. Every family is measured against its own fill, which is the only backdrop a flat
/// semantic capsule ever has — and the reason it can be hue-independent in the first place.
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
        // 3:1 — the floor for non-text indicators. This is the one the obvious "system orange"
        // fails on a light amber fill, which is why the light dots are darker than they look.
        for family in SemanticCapsuleFamily.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let style = SemanticCapsuleStyle.of(family, scheme)
                let ratio = contrast(style.dot, style.fill)
                #expect(ratio >= 3.0, "\(family)/\(scheme) dot is \(ratio):1 on its own fill")
            }
        }
    }

    @Test func testTheDotIsTheMostColorfulMemberOfItsFamily() {
        // The stated rule for the role: the smallest element gets the strongest hue, because it
        // has the least area in which to communicate it.
        //
        // Measured as CHROMA (max − min), not HSV saturation (max − min / max). The distinction is
        // not pedantic here: the dark fill rgb(0.24, 0.15, 0.03) is a near-black brown whose HSV
        // saturation is 0.87 — higher than the bright orange dot's 0.86 — so an HSV test claims the
        // background out-shouts the dot. Chroma says what the eye does: 0.21 against 0.86.
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

    /// The `onAccent` path's dot is legible by its RING, not by its own colour — and the ring is
    /// the fill's paired label colour, so this is really asserting that the pairing every other
    /// accent-filled control relies on also does this job. Runs over all twelve hues: the pill is
    /// hue-dependent now, so a hue whose ring vanished would strand the dot with no boundary at all.
    @MainActor
    @Test func testTheRingedDotStaysBoundedOnEveryAccentHue() throws {
        for hue in LiquidGlassHue.allCases where hue != .none {
            // `.none` is the *system* accent — a dynamic color with no fixed value to measure.
            let style = SemanticCapsuleStyle.onAccent(fill: hue.accentColor, label: hue.onAccentLabelColor)
            let ring = try #require(style.dotRing, "\(hue) accent capsule shipped an unringed dot")
            let ratio = contrast(ring, style.fill)
            #expect(ratio >= 3.0, "\(hue) dot ring is \(ratio):1 on its own accent fill")
        }
    }

    /// Why the ring has to exist, stated as a measurement instead of a comment: on the Green accent
    /// there is NO colour a dot could be that clears 3:1 — not this terracotta, not a pale peach,
    /// not pure white. If a future accent re-tune ever makes a bare dot viable this fails, and the
    /// ring becomes removable; until then, deleting it silently drops the dot below the floor.
    @MainActor
    @Test func testNoBareDotColorCouldClearTheFloorOnTheGreenAccent() {
        let fill = LiquidGlassHue.green.accentColor
        for candidate in [SemanticCapsuleStyle.attentionDotOnAccent,
                          SemanticCapsuleStyle.of(.attention, .light).dot,
                          Color(red: 0.95, green: 0.77, blue: 0.66),   // pale peach
                          .white] {
            #expect(contrast(candidate, fill) < 3.0)
        }
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
