import AppKit
import SwiftUI
import Testing
@testable import Design

/// `AccentFill.deepened(_:)` — the transform that lets every filled control wear a white label.
/// Measured, not asserted from the doc comment: the whole reason the app can fix its on-fill label at
/// white is that this function guarantees the fill can carry it.
@Suite struct AccentFillTests {

    private func srgb(_ color: Color) -> NSColor {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            Issue.record("\(color) has no sRGB representation")
            return .white
        }
        return converted
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    private func whiteContrast(_ fill: NSColor) -> CGFloat { 1.05 / (luminance(fill) + 0.05) }

    @Test func everyDeepenedHueCarriesWhiteAtBodyTextContrast() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let ratio = whiteContrast(srgb(hue.accentFillColor))
            #expect(ratio >= 4.5, "white on deepened \(hue) is only \(ratio):1")
        }
    }

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

    /// Deepening must read as the SAME colour turned down, not as a different colour — which is why
    /// the scaling happens in linear light. Scaling all three linear components by one factor leaves
    /// their ratios, i.e. the chromaticity, exactly intact. This is the test that would fail if
    /// someone "simplified" it to multiplying the sRGB components, which shifts hue.
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
    /// white label has to survive the trip too — it starts dark enough that nothing should happen.
    @Test func destructiveRedAlreadyCarriesWhite() {
        #expect(whiteContrast(srgb(AccentFill.deepened(.red))) >= 4.5)
    }
}
