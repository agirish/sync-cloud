import AppKit
import SwiftUI
import Testing
@testable import Design

/// Proves the hover tint lands on the glyph, by rendering it and reading the pixels. A hover for
/// the system-chrome buttons can look correct in source and be invisible in the app. These
/// specimens are plain `Image`s with no glass, so unlike the chrome they render offscreen, and
/// "does anything change colour" is answered here instead of in a screenshot.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct HoverTintRenderTests {

    private let tint = Color(red: 0, green: 0, blue: 1)

    /// Renders a specimen at a fixed size and returns its pixels.
    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        try #require(offscreenBitmap(AnyView(view.frame(width: 40, height: 40)),
                                      size: CGSize(width: 40, height: 40), appearance: nil, sRGB: false))
    }

    /// How blue the specimen is overall. The tint is pure blue, so this rises only if it landed.
    private func blueness(_ rep: NSBitmapImageRep) -> Double {
        var total = 0.0
        var counted = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.1 else { continue }
                guard let rgb = c.usingColorSpace(.sRGB) else { continue }
                total += rgb.blueComponent - (rgb.redComponent + rgb.greenComponent) / 2
                counted += 1
            }
        }
        return counted == 0 ? 0 : total / Double(counted)
    }

    private func specimen(_ phase: HoverAffordancePhase) -> some View {
        Image(systemName: "chevron.left")
            .hoverTint(tint)
            .environment(\.hoverAffordancePhase, phase)
    }

    /// The tint lands when engaged. `.pressed` counts as engaged for the label: a glyph that
    /// snapped back to its resting colour on click would read as the control losing focus.
    @Test(arguments: [HoverAffordancePhase.hover, .pressed])
    func tintReachesTheGlyphWhenEngaged(_ phase: HoverAffordancePhase) throws {
        let rest = try blueness(render(specimen(.rest)))
        let engaged = try blueness(render(specimen(phase)))
        #expect(engaged > rest + 0.05, "the glyph did not go blue at \(phase) — rest \(rest), \(phase) \(engaged)")
    }

    @Test func restingAppearanceIsLeftExactlyAlone() throws {
        // Why this is `hoverTint`, not `hoverInk`: it must drop onto a control whose resting
        // colour comes from a system button style without restating, and so overriding, it.
        let bare = try blueness(render(Image(systemName: "chevron.left")))
        let atRest = try blueness(render(specimen(.rest)))
        #expect(abs(atRest - bare) <= 0.001,
                "hoverTint changed the glyph at rest; it must apply nothing until engaged")
    }
}
