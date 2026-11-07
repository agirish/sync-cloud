import AppKit
import Design
import SwiftUI
import Testing
@testable import FileExplorer

/// A flat `semantic` capsule survives without a trailing chevron, checked in painted pixels. The
/// collapsed differences strip shows the expanded header's count with no toggle, so it passes
/// `semantic:` with no `trailingSystemImage:`. Keying the composed path on the trailing symbol
/// alone would drop it to the pale tint wash, and both spellings type-check and render something.
/// The modal opaque colour (the capsule fill) makes the two comparable: the chevron changes the
/// pill's width and pixel mix, not its fill.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct StatPillFlatFillTests {

    private static let hue = LiquidGlassHue.green

    private func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
        let (host, window) = HostedView.host(AnyView(view), size: NSHostingView(rootView: AnyView(view)).fittingSize)
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        withExtendedLifetime(window) { host.cacheDisplay(in: host.bounds, to: rep) }
        return rep
    }

    /// The most frequent fully-opaque colour, quantized to 1/32 per channel: the capsule fill.
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
        // The collapsed strip with no semantic style reaching the surface wears `color` as a pale
        // wash. If the fall-through comes back, this assertion fails; the one above would still
        // pass if both specimens regressed.
        let flat = modalFill(try render(pill(trailing: nil, semantic: accent, tint: .blue)))
        let wash = modalFill(try render(pill(trailing: nil, semantic: nil, tint: SemanticColor.warning)))
        #expect(distance(flat, wash) > 0.20,
                "the flat accent fill \(flat) is indistinguishable from the tint wash \(wash)")
    }

    @Test func testAPlainTintedPillStillTakesTheSharedPillPath() throws {
        // The other direction: plain lens pills must stay off the composed surface, so two tints
        // that differ only in hue must still differ. Over opaque white, so the 14% wash composites
        // to an opaque colour the modal read counts; the words are label colour, the same in both
        // tints, so the tint lives only in the wash.
        let warning = modalFill(try render(pill(trailing: nil, semantic: nil, tint: SemanticColor.warning)
            .background(Color.white)))
        let info = modalFill(try render(pill(trailing: nil, semantic: nil, tint: SemanticColor.info)
            .background(Color.white)))
        #expect(distance(warning, info) > 0.02,
                "the plain tinted pills stopped carrying their tint: \(warning) vs \(info)")
    }

    /// The composed pill's words are label colour on its tint's wash. The wash is drawn inside
    /// `StatPillSurface`, out of the source scan's reach, so the words are read off a render: the
    /// darkest pixel in light and the brightest in dark must be near-neutral black or white, not
    /// the caution yellow (near L 0.6, strongly tinted).
    @Test(arguments: [false, true]) func theComposedPillsWordsAreLabelColour(dark: Bool) throws {
        let pill = pill(trailing: "chevron.right", semantic: nil, tint: SemanticColor.caution)
            .padding(6)
            .background(dark ? Color(white: 0.13) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.appFontScale, 1.6)
        let rep = try #require(PixelDiff.render(pill, size: NSHostingView(rootView: AnyView(pill)).fittingSize,
                                                appearance: dark ? .darkAqua : .aqua))
        // Raw bytes: `colorAt` tags sRGB numbers as calibrated. Two reads, because one can't decide
        // alone: the chevron and the rolling count keep a label-colour pixel whatever the words
        // wear, so the extreme pixel passes either way. So also count strongly coloured pixels:
        // words in caution yellow are chroma near 1, the hairline (the tint at 0.45) and the wash
        // under 0.6.
        var best: (l: CGFloat, chroma: CGFloat) = (dark ? 0 : 1, 0)
        var coloured = 0
        var p = [Int](repeating: 0, count: 4)
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            rep.getPixel(&p, atX: x, y: y)
            let (r, g, b) = (CGFloat(p[0]) / 255, CGFloat(p[1]) / 255, CGFloat(p[2]) / 255)
            let l = AccentLabel.relativeLuminance(red: r, green: g, blue: b)
            let chroma = max(r, g, b) - min(r, g, b)
            if dark ? l > best.l : l < best.l { best = (l, chroma) }
            if chroma > 0.7 { coloured += 1 }
        } }
        #expect(coloured < 5, "the pill's words are tinted: \(coloured) strongly coloured pixels")
        if dark {
            #expect(best.l > 0.6, "the pill's brightest ink is L \(best.l), not white")
        } else {
            #expect(best.l < 0.08, "the pill's darkest ink is L \(best.l), not black")
        }
        #expect(best.chroma < 0.12, "the pill's extreme ink is tinted: chroma \(best.chroma)")
    }
}
