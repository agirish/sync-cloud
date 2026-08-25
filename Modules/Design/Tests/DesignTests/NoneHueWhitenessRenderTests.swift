import AppKit
import SwiftUI
import XCTest
@testable import Design

/// Proves the "None" accent's background actually reads white in light — by rendering the real
/// `liquidGlassAppBackground` and reading the pixels.
///
/// The complaint this answers was visual: at low Tint, None (bare material) and Graphite (a faint
/// neutral wash floored at `tintFloor`) rendered within a few points of the same gray, so the two
/// accents were told apart by their swatches and nothing else. `noneLightVeil` separates them, and
/// these tests keep the separation a measured fact rather than a constant trusted in prose.
final class NoneHueWhitenessRenderTests: XCTestCase {

    /// XCTest predates the `Testing` trait, so this suite opts into the same
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
        let host = NSHostingView(rootView: view.frame(width: 80, height: 80))
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
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

    /// The complaint itself: at the Tint floor, None must sit clearly on the white side of
    /// Graphite. Margins here are calibrated to THIS pipeline, which renders far lighter than the
    /// screen does — offscreen there is no desktop behind the material, so the bare material lands
    /// near 0.97 and Graphite's floor wash can only pull it to ~0.956. An absolute margin like
    /// 0.10 is unreachable offscreen while the on-screen separation is plainly visible, so the
    /// meaningful assertion is the scale-free one in the next test; this one pins the ordering
    /// with a margin near the veil's measured effect here (the veil moved None +0.024 from the
    /// bare material's 0.968).
    @MainActor
    func testNoneIsWhiterThanGraphiteInLightAtMinTint() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false))
        let graphite = try brightness(render(hue: .graphite, tint: 0, dark: false))
        print("[none-whiteness] light tint0 — none \(none), graphite \(graphite)")
        XCTAssertGreaterThan(none, graphite + 0.02,
                             "None does not separate from Graphite — none \(none), graphite \(graphite)")
    }

    /// "Whiter" alone could be satisfied by a barely-lighter gray; white means NEAR white. Scale-
    /// free so it survives this pipeline's compressed grays: whatever distance Graphite sits from
    /// pure white, None must close at least 60% of its own — the reference is a rendered
    /// `Color.white` through the same pipeline, so the bar tracks the pipeline's actual ceiling
    /// rather than an assumed 1.0.
    @MainActor
    func testNoneClosesMostOfTheGapToWhite() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false))
        let graphite = try brightness(render(hue: .graphite, tint: 0, dark: false))
        let white = try brightness(renderView(AnyView(Color.white), dark: false))
        print("[none-whiteness] light — none \(none), graphite \(graphite), white reference \(white)")
        XCTAssertGreaterThan(white, graphite + 0.02, "Graphite renders as white — the gap this measures is gone")
        XCTAssertLessThan(white - none, (white - graphite) * 0.4,
                          "None reads gray, not white — none \(none), graphite \(graphite), white \(white)")
    }

    /// Clear is NOT exempt — the exemption was the first cut's mistake, found on a real
    /// Clear/None/light install that stayed exactly as gray as before the veil existed. At Clear
    /// the veil sits over the vibrancy + `clearLightVeil` instead of over the material; the fact
    /// that must survive is the same one as at Frosted: None separates from Graphite.
    @MainActor
    func testClearNoneIsWhiterThanClearGraphiteInLight() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: false, level: .clear))
        let graphite = try brightness(render(hue: .graphite, tint: 0, dark: false, level: .clear))
        print("[none-whiteness] clear light tint0 — none \(none), graphite \(graphite)")
        XCTAssertGreaterThan(none, graphite + 0.02,
                             "Clear None does not separate from Clear Graphite — none \(none), graphite \(graphite)")
    }

    /// The veil is light-only by design: white over dark's deep near-black base would gray it.
    /// The guard in the modifier is one-directional, so its absence in dark is asserted, not assumed.
    @MainActor
    func testDarkNoneKeepsItsDeepGround() throws {
        let none = try brightness(render(hue: .none, tint: 0, dark: true))
        print("[none-whiteness] dark tint0 — none \(none)")
        XCTAssertLessThan(none, 0.35,
                          "the white veil is leaking into dark — brightness \(none)")
    }
}
