import AppKit
import SwiftUI
import Testing
@testable import Design

/// `AccentFill.deepened(_:)` — the transform that lets every filled control wear a white label.
/// Measured, not asserted from the doc comment: the whole reason the app can fix its on-fill label at
/// white is that this function guarantees the fill can carry it.
@Suite struct AccentFillTests {

    /// Resolved in `appearance`, or with none named. The hues are fixed sRGB, the same in either
    /// appearance, so most tests name none; `.red` is a system colour with a dark value of its own
    /// and is resolved in each appearance by name (`docs/flaky-tests.md`, "A dynamic colour resolved
    /// in whatever appearance the app had that moment").
    private func srgb(_ color: Color, in appearance: NSAppearance.Name? = nil) -> NSColor {
        var converted: NSColor?
        if let appearance {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                converted = NSColor(color).usingColorSpace(.sRGB)
            }
        } else {
            converted = NSColor(color).usingColorSpace(.sRGB)
        }
        guard let converted else {
            Issue.record("\(color) has no sRGB representation")
            return .white
        }
        return converted
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    private func whiteContrast(_ fill: NSColor) -> CGFloat { 1.05 / (luminance(fill) + 0.05) }

    /// The transform only ever darkens. A hue that already carries white is returned untouched, so
    /// this is a no-op on roughly half the palette rather than a flattening of all twelve toward one
    /// luminance — Indigo (L ≈ 0.157) must come back byte-identical.
    @Test func deepeningNeverLightensAndLeavesDarkHuesAlone() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let raw = srgb(hue.accentColor), deep = srgb(hue.accentFillColor)
            #expect(luminance(deep) <= luminance(raw) + 0.0001, "\(hue) got lighter")
        }
        #expect(luminance(srgb(LiquidGlassHue.indigo.accentColor)) < AccentFill.targetLuminance)
        #expect(srgb(LiquidGlassHue.indigo.accentFillColor).redComponent
                == srgb(LiquidGlassHue.indigo.accentColor).redComponent)
        // ...and one that genuinely moves, so the test above can't pass by the function doing nothing.
        #expect(luminance(srgb(LiquidGlassHue.amber.accentFillColor))
                < luminance(srgb(LiquidGlassHue.amber.accentColor)) - 0.1)
    }

    /// Deepening reads as the same colour turned down: scaled in linear light, which keeps the
    /// chromaticity intact. Multiplying the sRGB components instead shifts hue and must fail this.
    @Test func deepeningPreservesChromaticity() {
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        for hue in LiquidGlassHue.allCases where hue != .none {
            let raw = srgb(hue.accentColor), deep = srgb(hue.accentFillColor)
            let rawSum = linear(raw.redComponent) + linear(raw.greenComponent) + linear(raw.blueComponent)
            let deepSum = linear(deep.redComponent) + linear(deep.greenComponent) + linear(deep.blueComponent)
            guard rawSum > 0, deepSum > 0 else { continue }
            for (a, b) in [(raw.redComponent, deep.redComponent),
                           (raw.greenComponent, deep.greenComponent),
                           (raw.blueComponent, deep.blueComponent)] {
                // Each component's share of the total light, before and after.
                #expect(abs(linear(a) / rawSum - linear(b) / deepSum) < 0.005,
                        "\(hue) shifted hue when deepened")
            }
        }
    }

    /// The deepened value lands ON the ceiling rather than somewhere below it: scaling luminance by
    /// `target / L` is exact arithmetic, not a search that stops early, so an over-darkened fill
    /// would mean the transform is wrong even though the contrast assertion above still passed.
    @Test func deepeningLandsExactlyOnTheCeiling() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let raw = srgb(hue.accentColor)
            guard luminance(raw) > AccentFill.targetLuminance else { continue }
            let deep = luminance(srgb(hue.accentFillColor))
            #expect(abs(deep - AccentFill.targetLuminance) < 0.002,
                    "\(hue) deepened to L=\(deep), not the \(AccentFill.targetLuminance) ceiling")
        }
    }

    /// The destructive red goes through the same call as the accents (`actionBarButton`), so its
    /// white label has to survive the trip too. Raw red carries white at only about 3.5:1, so the
    /// deepening does the work, and in both appearances: `.red` has a dark value of its own, which
    /// `deepened` must re-resolve rather than fix at call time.
    @Test func destructiveRedCarriesWhiteOnceDeepened() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            #expect(whiteContrast(srgb(.red, in: appearance)) < 4.5,
                    "raw red carries white in \(appearance.rawValue); this no longer tests the deepening")
            let deep = whiteContrast(srgb(AccentFill.deepened(.red), in: appearance))
            #expect(deep >= 4.5, "deepened red carries white at only \(deep):1 in \(appearance.rawValue)")
        }
    }
}
