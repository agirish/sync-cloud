import AppKit
import SwiftUI
import XCTest
@testable import Design

/// Proves the hover tint lands on the glyph, by rendering it and reading the pixels. A hover for
/// the system-chrome buttons can look correct in source and be invisible in the app. These
/// specimens are plain `Image`s with no glass, so unlike the chrome they render offscreen, and
/// "does anything change colour" is answered here instead of in a screenshot.
final class HoverTintRenderTests: XCTestCase {

    /// XCTest has no `Testing` trait, so this suite opts into the
    /// `MachinePinnedReason.pixelSampling` gate by hand. It reads painted pixels like its
    /// `@Suite(.machinePinned(.pixelSampling))` neighbours and must skip with them.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(MachinePinnedGate.isExcluded(.pixelSampling),
                      "machine-pinned (pixelSampling) — excluded via SYNCCLOUD_SKIP_MACHINE_PINNED")
    }

    private let tint = Color(red: 0, green: 0, blue: 1)

    /// Renders a specimen at a fixed size and returns its pixels.
    @MainActor
    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        try XCTUnwrap(offscreenBitmap(AnyView(view.frame(width: 40, height: 40)),
                                      size: CGSize(width: 40, height: 40), appearance: nil, sRGB: false))
    }

    /// How blue the specimen is overall. The tint is pure blue, so this rises only if it landed.
    @MainActor
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

    @MainActor
    private func specimen(_ phase: HoverAffordancePhase) -> some View {
        Image(systemName: "chevron.left")
            .hoverTint(tint)
            .environment(\.hoverAffordancePhase, phase)
    }

    @MainActor
    func testTintReachesTheGlyphWhenEngaged() throws {
        let rest = try blueness(render(specimen(.rest)))
        let hover = try blueness(render(specimen(.hover)))
        XCTAssertGreaterThan(hover, rest + 0.05,
                             "the glyph did not go blue on hover — rest \(rest), hover \(hover)")
    }

    @MainActor
    func testPressedIsTintedToo() throws {
        // `.pressed` counts as engaged for the label: a glyph that snapped back to its resting
        // colour on click would read as the control losing focus.
        let rest = try blueness(render(specimen(.rest)))
        let pressed = try blueness(render(specimen(.pressed)))
        XCTAssertGreaterThan(pressed, rest + 0.05,
                             "the glyph dropped its tint while pressed")
    }

    @MainActor
    func testRestingAppearanceIsLeftExactlyAlone() throws {
        // Why this is `hoverTint`, not `hoverInk`: it must drop onto a control whose resting
        // colour comes from a system button style without restating, and so overriding, it.
        let bare = try blueness(render(Image(systemName: "chevron.left")))
        let atRest = try blueness(render(specimen(.rest)))
        XCTAssertEqual(atRest, bare, accuracy: 0.001,
                       "hoverTint changed the glyph at rest; it must apply nothing until engaged")
    }
}
