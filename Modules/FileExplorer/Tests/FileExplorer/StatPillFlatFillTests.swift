import AppKit
import Design
import SwiftUI
import Testing
@testable import FileExplorer

/// Proves a flat `semantic` capsule survives WITHOUT a trailing chevron, by rendering the pill and
/// reading the pixels it actually paints.
///
/// The collapsed differences strip shows the same count as the expanded header but has no toggle,
/// so it passes `semantic:` with no `trailingSystemImage:`. `StatPill` used to key its whole
/// composed path on the trailing symbol alone, so that combination silently fell through to the
/// pale tint wash — the count wore one colour language expanded and another collapsed, and no
/// assertion anywhere could see it, because both spellings type-check and both render *something*.
///
/// Sampling the MODAL opaque colour (the capsule fill, which outnumbers the dot/text/chevron
/// pixels) is what makes the with-chevron and without-chevron specimens directly comparable: the
/// chevron changes the pill's width and pixel mix, but not the colour of its fill.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct StatPillFlatFillTests {

    private static let hue = LiquidGlassHue.green

    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The most frequent fully-opaque colour, quantized to 1/32 per channel — i.e. the capsule fill.
    private func modalFill(_ rep: NSBitmapImageRep) -> (r: Double, g: Double, b: Double) {
        var counts: [Int: Int] = [:]
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.9,
                      let rgb = c.usingColorSpace(.sRGB) else { continue }
                let key = (Int(rgb.redComponent * 31) << 10)
                    | (Int(rgb.greenComponent * 31) << 5)
                    | Int(rgb.blueComponent * 31)
                counts[key, default: 0] += 1
            }
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return (0, 0, 0) }
        return (Double((best >> 10) & 31) / 31, Double((best >> 5) & 31) / 31, Double(best & 31) / 31)
    }

    private func distance(_ a: (r: Double, g: Double, b: Double),
                          _ b: (r: Double, g: Double, b: Double)) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    private func pill(trailing: String?, semantic: SemanticCapsuleStyle?, tint: Color) -> some View {
        StatPill(count: 21, label: "Differences", color: tint,
                 systemImage: "exclamationmark.triangle",
                 trailingSystemImage: trailing, semantic: semantic)
    }

    private var accent: SemanticCapsuleStyle {
        .onAccent(fill: Self.hue.accentFillColor, label: Self.hue.onAccentLabelColor)
    }

    @Test func testAFlatFillSurvivesWithoutATrailingChevron() throws {
        // The collapsed strip's spelling vs the expanded header's: same fill, chevron aside.
        let withoutChevron = modalFill(try render(pill(trailing: nil, semantic: accent, tint: .blue)))
        let withChevron = modalFill(try render(pill(trailing: "chevron.right", semantic: accent, tint: .blue)))
        #expect(distance(withoutChevron, withChevron) < 0.06,
                "the chevron-less pill painted \(withoutChevron), the toggle painted \(withChevron)")
    }

    @Test func testTheFlatFillIsNotTheTintWashItUsedToFallThroughTo() throws {
        // The pre-fix rendering of the collapsed strip: no semantic style reaches the surface, so
        // the pill wears `color` as a pale wash. If the fall-through ever comes back, THIS is the
        // assertion that fails — the one above would still pass if both specimens regressed.
        let flat = modalFill(try render(pill(trailing: nil, semantic: accent, tint: .blue)))
        let wash = modalFill(try render(pill(trailing: nil, semantic: nil, tint: SemanticColor.warning)))
        #expect(distance(flat, wash) > 0.20,
                "the flat accent fill \(flat) is indistinguishable from the tint wash \(wash)")
    }

    @Test func testAPlainTintedPillStillTakesTheSharedPillPath() throws {
        // Guard the other direction: the many plain lens pills must not be dragged onto the
        // composed surface by this change. Two tints that differ only in hue must still differ.
        let warning = modalFill(try render(pill(trailing: nil, semantic: nil, tint: SemanticColor.warning)))
        let info = modalFill(try render(pill(trailing: nil, semantic: nil, tint: SemanticColor.info)))
        #expect(distance(warning, info) > 0.02,
                "the plain tinted pills stopped carrying their tint: \(warning) vs \(info)")
    }
}
