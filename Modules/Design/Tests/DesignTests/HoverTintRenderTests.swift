import AppKit
import SwiftUI
import XCTest
@testable import Design

/// Proves the hover tint actually lands on the glyph, by rendering it and reading the pixels.
///
/// Every previous attempt at a hover for the system-chrome buttons was reasoned about rather than
/// rendered — a halo, then a saturation filter — and each was invisible in the running app while
/// looking perfectly correct in the source. These specimens are plain `Image`s with no glass
/// anywhere near them, so unlike the chrome itself they *do* render offscreen, and the question
/// "does anything actually change colour" becomes answerable here instead of in a screenshot.
final class HoverTintRenderTests: XCTestCase {

    private let tint = Color(red: 0, green: 0, blue: 1)

    /// Renders a specimen at a fixed size and returns its pixels.
    @MainActor
    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 40, height: 40)))
        host.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// How blue the specimen is overall — the tint is pure blue, so this rises only if it landed.
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
        // `.pressed` is engaged as far as the label is concerned: a glyph that snapped back to
        // its resting colour the instant you clicked would read as the control losing focus.
        let rest = try blueness(render(specimen(.rest)))
        let pressed = try blueness(render(specimen(.pressed)))
        XCTAssertGreaterThan(pressed, rest + 0.05,
                             "the glyph dropped its tint while pressed")
    }

    @MainActor
    func testRestingAppearanceIsLeftExactlyAlone() throws {
        // The whole reason this is `hoverTint` and not `hoverInk`: it must be droppable onto a
        // control whose resting colour comes from a system button style, without restating — and
        // so overriding — that colour.
        let bare = try blueness(render(Image(systemName: "chevron.left")))
        let atRest = try blueness(render(specimen(.rest)))
        XCTAssertEqual(atRest, bare, accuracy: 0.001,
                       "hoverTint changed the glyph at rest; it must apply nothing until engaged")
    }
}
