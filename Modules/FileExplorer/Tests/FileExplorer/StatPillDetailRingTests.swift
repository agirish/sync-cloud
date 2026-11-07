import AppKit
import Design
import SwiftUI
import Testing
@testable import FileExplorer

/// Measures, in painted pixels, the boundary between the count pill's age run and the accent
/// capsule behind it. The ring (`onAccentLabelColor`, ≥4.55:1 against every accent fill by
/// `AccentFill.deepened`) is what lets a semantic capsule nest inside an accent one: the inset fill
/// alone can fall to 2.68:1. The `countPillFreshnessStates` snapshot can't guard it, since its
/// tolerance absorbs a 1pt stroke. So this walks in from the bare accent field to the first changed
/// pixel and requires 3:1, the rule for a non-text boundary, whatever provides the separation.
/// Counting white pixels can't work: the light semantic fills are near-white too.
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct StatPillDetailRingTests {

    private let size = CGSize(width: 120, height: 44)

    private func subject(_ style: SemanticCapsuleStyle, ring: Color, on hue: LiquidGlassHue) -> some View {
        Text("2h ago")
            .scaledFont(PillVariant.standard.labelFont)
            .modifier(DetailRunCapsule(style: style, ring: ring))
            .frame(width: size.width, height: size.height)
            .background(hue.accentFillColor)
    }

    private func render(_ view: some View, _ appearance: NSAppearance.Name) -> NSBitmapImageRep {
        PixelDiff.render(view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light),
                         size: size, appearance: appearance)!
    }

    private func luminance(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        return AccentLabel.relativeLuminance(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let x = luminance(a), y = luminance(b)
        let (hi, lo) = x > y ? (x, y) : (y, x)
        return Double((hi + 0.05) / (lo + 0.05))
    }

    /// Walks the frame's middle row inward and returns the contrast between the accent field and
    /// the first pixel that departs from it by more than anti-aliasing noise. Nil when the row
    /// never changes, meaning nothing was drawn; the caller reports that as a failure.
    private func edgeContrast(in rep: NSBitmapImageRep) -> Double? {
        let midY = rep.pixelsHigh / 2
        guard let field = rep.colorAt(x: 1, y: midY)?.usingColorSpace(.sRGB) else { return nil }
        // 0.06 per channel: above the dithering the window's backing store introduces on a flat
        // fill, well below any real paint change.
        for x in 2..<rep.pixelsWide {
            guard let px = rep.colorAt(x: x, y: midY)?.usingColorSpace(.sRGB) else { continue }
            let departed = abs(px.redComponent - field.redComponent) > 0.06
                || abs(px.greenComponent - field.greenComponent) > 0.06
                || abs(px.blueComponent - field.blueComponent) > 0.06
            if departed { return contrast(px, field) }
        }
        return nil
    }

    /// Every family, appearance and hue: the age run's edge separates from the accent by at least
    /// the 3:1 a non-text boundary needs. Deleting the `.overlay` in `DetailRunCapsule` must fail
    /// it. Pixels, not palette arithmetic: the first departing pixel is an anti-aliased blend of
    /// fill and accent, so the painted edge can fall short (2.86:1) where the colours clear
    /// (3.74:1).
    @Test func theAgeRunsEdgeClearsThreeToOneOnEveryAccent() {
        for hue in LiquidGlassHue.allCases {
            for family in SemanticCapsuleFamily.allCases {
                for (appearance, scheme) in [(NSAppearance.Name.aqua, ColorScheme.light),
                                             (.darkAqua, .dark)] {
                    let style = SemanticCapsuleStyle.of(family, scheme)
                    let rep = render(subject(style, ring: hue.onAccentLabelColor, on: hue), appearance)
                    guard let ratio = edgeContrast(in: rep) else {
                        Issue.record("\(hue)/\(family)/\(scheme): nothing was drawn on the accent field")
                        continue
                    }
                    #expect(ratio >= 3.0, "\(hue)/\(family)/\(scheme): edge is \(ratio):1 against the accent")
                }
            }
        }
    }

    /// Guards the measurement: it must read the ring, not the fill behind it. Same geometry with
    /// the ring drawn in its capsule's own fill colour, on the pair where the fill alone fails
    /// (`.neutral` on Indigo in dark, 2.68:1): the edge must come back under 3:1, or the test above
    /// would pass with the ring deleted.
    @Test func withoutTheRingTheWorstPairFallsBelowTheFloor() {
        let style = SemanticCapsuleStyle.of(.neutral, .dark)
        let rep = render(subject(style, ring: style.fill, on: .indigo), .darkAqua)
        let ratio = try? #require(edgeContrast(in: rep))
        #expect((ratio ?? 99) < 3.0,
                "unringed neutral-on-Indigo measured \(ratio ?? -1):1 — expected it to FAIL the floor, so the ring is what carries it")
    }
}
