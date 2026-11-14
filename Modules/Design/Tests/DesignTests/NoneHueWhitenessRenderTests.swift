import AppKit
import SwiftUI
import Testing
@testable import Design

/// Proves the None accent's background reads white in light, by rendering the real
/// `liquidGlassAppBackground` and reading the pixels.
///
/// Without `noneLightVeil`, at low Tint None (bare material) and Graphite (a faint neutral wash
/// floored at `tintFloor`) render within a few points of the same grey.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct NoneHueWhitenessRenderTests {

    /// Renders the app background for one hue at one appearance and returns its pixels.
    private func render(hue: LiquidGlassHue, tint: Double, dark: Bool,
                        level: GlassLevel = .frosted) throws -> NSBitmapImageRep {
        try renderView(AnyView(Color.clear.liquidGlassAppBackground(level: level, hue: hue, tint: tint)),
                       dark: dark)
    }

    private func renderView(_ view: AnyView, dark: Bool) throws -> NSBitmapImageRep {
        try #require(offscreenBitmap(view.frame(width: 80, height: 80), size: CGSize(width: 80, height: 80),
                                      appearance: dark ? .darkAqua : .aqua, sRGB: false))
    }

    /// Mean sRGB brightness over the rendered background, 0...1.
    private func brightness(_ rep: NSBitmapImageRep) -> Double {
        var total = 0.0
        var counted = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 else { continue }
                guard let rgb = c.usingColorSpace(.sRGB) else { continue }
                total += (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
                counted += 1
            }
        }
        return counted == 0 ? 0 : total / Double(counted)
    }

    /// At the Tint floor, None sits clearly on the white side of Graphite. Offscreen there is no
    /// desktop behind the material, so bare material lands near 0.97 and Graphite ~0.956; an
    /// absolute margin like 0.10 is unreachable, so the margin is near the veil's measured +0.024.
    @Test func noneIsWhiterThanGraphiteInLightAtMinTint() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false))
        let graphite = try brightness(render(hue: .graphite, tint: 0, dark: false))
        #expect(none > graphite + 0.02,
                "None does not separate from Graphite — none \(none), graphite \(graphite)")
    }

    /// None closes at least 60% of Graphite's distance to white: scale-free, so it survives this
    /// pipeline's compressed greys. White is a rendered `Color.white`, the pipeline's real ceiling,
    /// not an assumed 1.0.
    @Test func noneClosesMostOfTheGapToWhite() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false))
        let graphite = try brightness(render(hue: .graphite, tint: 0, dark: false))
        let white = try brightness(renderView(AnyView(Color.white), dark: false))
        #expect(white > graphite + 0.02, "Graphite renders as white — the gap this measures is gone")
        #expect(white - none < (white - graphite) * 0.4,
                "None reads gray, not white — none \(none), graphite \(graphite), white \(white)")
    }

    /// A Clear/None/light window gets the white film too. None against Graphite can't be compared
    /// at Clear offscreen: they sit on different behind-window materials, and with no desktop each
    /// renders a fallback that inverts the screen. So this pins that the film lifts None's own
    /// backdrop clearly toward white.
    @Test func clearNoneDrawsItsWhiteFilmInLight() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false, level: .clear))
        let backdrop = try brightness(renderView(AnyView(Color.clear.background {
            ZStack {
                BehindWindowGlass(isEnabled: true, vibrancyAlpha: LiquidGlass.clearVibrancyAlpha,
                                  material: LiquidGlass.clearNoneLightMaterial)
                Color.white.opacity(LiquidGlass.clearLightVeil)
            }
        }), dark: false))
        #expect(none > backdrop + 0.02,
                "Clear None's white film isn't drawn — none \(none), backdrop \(backdrop)")
    }

    /// The veil is light-only by design: white over dark's deep near-black base would grey it. The
    /// guard in the modifier is one-directional, so its absence in dark is asserted, not assumed.
    @Test func darkNoneKeepsItsDeepGround() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: true))
        #expect(none < 0.35,
                "the white veil is leaking into dark — brightness \(none)")
    }
}
