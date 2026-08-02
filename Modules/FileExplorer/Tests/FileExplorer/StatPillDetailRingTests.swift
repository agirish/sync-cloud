import AppKit
import Design
import SwiftUI
import Testing
@testable import FileExplorer

/// Measures the boundary between the count pill's age run and the accent capsule behind it, in
/// PAINTED PIXELS.
///
/// This suite exists because the obvious protection does not work. The ring around the age run is
/// the whole reason a semantic capsule may be nested inside an accent one: measured, `.neutral` on
/// the Indigo accent is 2.68:1 and `.attention` on it 3.08:1, so the inset fill cannot be relied on
/// to separate itself, and the ring — `onAccentLabelColor`, guaranteed ≥4.55:1 against every accent
/// fill by `AccentFill.deepened` — is what does. But deleting the ring and re-running
/// `countPillFreshnessStates` PASSES: a 1pt stroke around two small capsules is a smaller share of
/// the frame than that snapshot's 0.99/0.98 tolerance absorbs. A reference that green-lights the
/// defect it was written to catch is worse than none, so the guarantee is measured here instead.
///
/// What is measured is the GUARANTEE, not the implementation: walk in from the edge of a bare
/// accent field until the paint changes, and require that first changed pixel to clear 3:1 against
/// the field. That is the actual rule for a non-text boundary. It does not care whether the
/// separation comes from a ring, a shadow or a differently-chosen fill — only that it is there.
///
/// Counting "white pixels" was the first attempt and is recorded here because it looked reasonable
/// and was not: the ring is white, and the LIGHT semantic fills are themselves near-white
/// (`.attention` is rgb(0.97, 0.90, 0.86)), so no tolerance separates ring from fill in light mode.
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
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme,
                                                                   appearance == .darkAqua ? .dark : .light)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep
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
    /// the first pixel that departs from it by more than anti-aliasing noise.
    ///
    /// Returns nil when the row never changes — which would mean nothing was drawn at all, and is
    /// reported as a failure by the caller rather than silently skipped.
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

    /// Every family, every appearance, every hue: the age run's edge separates from the accent it
    /// sits on by at least the 3:1 a non-text boundary needs.
    ///
    /// Mutation-tested by deleting the `.overlay` in `DetailRunCapsule`: cases fail across hues and
    /// BOTH appearances, bottoming out around 2.7:1.
    ///
    /// That is worse than the pure-colour arithmetic predicts, and the gap is the point of
    /// measuring pixels. `SemanticCapsuleTests` computes light `.attention` on the system accent at
    /// 3.74:1 from the colour values — comfortably clear — yet the painted edge measures 2.86:1,
    /// because the first pixel that departs from the field is an anti-aliased blend of fill and
    /// accent, not the fill itself. The colours clear the floor; the edge the eye actually sees
    /// does not. Nothing computed from the palette would have caught that.
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

    /// Guards the measurement: it must be reading the RING, not the fill behind it.
    ///
    /// Same geometry, but the ring is drawn in its own capsule's fill colour — still a stroke, just
    /// invisible against what it encloses. On the hue and state where the fill is known to fail
    /// (`.neutral` on Indigo in dark, 2.68:1) the edge must now come back UNDER 3:1. If it did not,
    /// the assertion above would be passing on something other than the ring and would keep passing
    /// with the ring deleted — the false green this suite exists to escape.
    @Test func withoutTheRingTheWorstPairFallsBelowTheFloor() {
        let style = SemanticCapsuleStyle.of(.neutral, .dark)
        let rep = render(subject(style, ring: style.fill, on: .indigo), .darkAqua)
        let ratio = try? #require(edgeContrast(in: rep))
        #expect((ratio ?? 99) < 3.0,
                "unringed neutral-on-Indigo measured \(ratio ?? -1):1 — expected it to FAIL the floor, so the ring is what carries it")
    }
}
