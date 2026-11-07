import AppKit
import SwiftUI
import XCTest
@testable import Design

/// Proves the None accent's background reads white in light, by rendering the real
/// `liquidGlassAppBackground` and reading the pixels.
///
/// Without `noneLightVeil`, at low Tint None (bare material) and Graphite (a faint neutral wash
/// floored at `tintFloor`) render within a few points of the same grey, told apart only by their
/// swatches. These tests keep the separation a measured fact rather than a constant trusted in
/// prose.
final class NoneHueWhitenessRenderTests: XCTestCase {

    /// XCTest has no `Testing` trait, so this suite opts into the
    /// `MachinePinnedReason.pixelSampling` gate by hand, like `HoverTintRenderTests`.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(MachinePinnedGate.isExcluded(.pixelSampling),
                      "machine-pinned (pixelSampling) — excluded via SYNCCLOUD_SKIP_MACHINE_PINNED")
    }

    /// Renders the app background for one hue at one appearance and returns its pixels.
    @MainActor
    private func render(hue: LiquidGlassHue, tint: Double, dark: Bool,
                        level: GlassLevel = .frosted) throws -> NSBitmapImageRep {
        try renderView(AnyView(Color.clear.liquidGlassAppBackground(level: level, hue: hue, tint: tint)),
                       dark: dark)
    }

    @MainActor
    private func renderView(_ view: AnyView, dark: Bool) throws -> NSBitmapImageRep {
        try XCTUnwrap(offscreenBitmap(view.frame(width: 80, height: 80), size: CGSize(width: 80, height: 80),
                                      appearance: dark ? .darkAqua : .aqua, sRGB: false))
    }

    /// Mean sRGB brightness over the rendered background, 0...1.
    @MainActor
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

    /// At the Tint floor, None must sit clearly on the white side of Graphite. Margins are
    /// calibrated to this pipeline, which renders far lighter than the screen: offscreen there is no
    /// desktop behind the material, so bare material lands near 0.97 and Graphite's floor wash only
    /// pulls it to ~0.956. An absolute margin like 0.10 is unreachable here, so the scale-free check
    /// is the next test; this one pins the ordering with a margin near the veil's measured effect
    /// (+0.024 over bare material's 0.968).
    @MainActor
    func testNoneIsWhiterThanGraphiteInLightAtMinTint() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false))
        let graphite = try brightness(render(hue: .graphite, tint: 0, dark: false))
        XCTAssertGreaterThan(none, graphite + 0.02,
                             "None does not separate from Graphite — none \(none), graphite \(graphite)")
    }

    /// "Whiter" alone could be met by a barely lighter grey; white means near white. Scale-free so
    /// it survives this pipeline's compressed greys: whatever distance Graphite sits from white,
    /// None must close at least 60% of it. White is a rendered `Color.white` through the same
    /// pipeline, so the bar tracks the pipeline's real ceiling rather than an assumed 1.0.
    @MainActor
    func testNoneClosesMostOfTheGapToWhite() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false))
        let graphite = try brightness(render(hue: .graphite, tint: 0, dark: false))
        let white = try brightness(renderView(AnyView(Color.white), dark: false))
        XCTAssertGreaterThan(white, graphite + 0.02, "Graphite renders as white — the gap this measures is gone")
        XCTAssertLessThan(white - none, (white - graphite) * 0.4,
                          "None reads gray, not white — none \(none), graphite \(graphite), white \(white)")
    }

    /// Clear is not exempt: a Clear/None/light window must get the white film too.
    ///
    /// None against Graphite can't be measured at Clear offscreen: they sit on different
    /// behind-window materials (None on `clearNoneLightMaterial`), and with no desktop behind an
    /// offscreen window each renders a fallback that inverts what the screen shows. So this pins
    /// what renders faithfully: over None's own backdrop and Clear's veil, the white film is drawn
    /// and lifts the window clearly toward white.
    @MainActor
    func testClearNoneDrawsItsWhiteFilmInLight() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false, level: .clear))
        let backdrop = try brightness(renderView(AnyView(Color.clear.background {
            ZStack {
                BehindWindowGlass(isEnabled: true, vibrancyAlpha: LiquidGlass.clearVibrancyAlpha,
                                  material: LiquidGlass.clearNoneLightMaterial)
                Color.white.opacity(LiquidGlass.clearLightVeil)
            }
        }), dark: false))
        XCTAssertGreaterThan(none, backdrop + 0.02,
                             "Clear None's white film isn't drawn — none \(none), backdrop \(backdrop)")
    }

    /// The veil is light-only by design: white over dark's deep near-black base would grey it. The
    /// guard in the modifier is one-directional, so its absence in dark is asserted, not assumed.
    @MainActor
    func testDarkNoneKeepsItsDeepGround() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: true))
        XCTAssertLessThan(none, 0.35,
                          "the white veil is leaking into dark — brightness \(none)")
    }
}
