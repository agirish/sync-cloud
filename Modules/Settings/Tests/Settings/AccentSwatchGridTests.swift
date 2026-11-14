import AppKit
import Design
import SwiftUI
import Testing
@testable import Settings

/// The Ask Claude card's accent swatches: twelve in two rows of six, each slot painting its own
/// hue, narrow enough for a 240 pt card. Measured in painted pixels, as `AccentPreviewTests` does.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct AccentSwatchGridTests {

    private func render(_ grid: AccentSwatchGrid) -> (NSBitmapImageRep, CGSize) {
        let view = grid.environment(\.colorScheme, .light)
        let size = NSHostingView(rootView: view).fittingSize
        return (offscreenBitmap(view, size: size)!, size)
    }

    /// The pixel at a point, re-tagged sRGB rather than converted (see `AccentPreviewTests.paint`).
    private func paint(_ rep: NSBitmapImageRep, _ point: CGPoint, in size: CGSize) -> NSColor? {
        let sx = CGFloat(rep.pixelsWide) / size.width
        let sy = CGFloat(rep.pixelsHigh) / size.height
        guard let px = rep.colorAt(x: Int(point.x * sx), y: Int(point.y * sy)) else { return nil }
        return NSColor(srgbRed: px.redComponent, green: px.greenComponent, blue: px.blueComponent, alpha: px.alphaComponent)
    }

    private func distance(_ a: NSColor, _ b: Color) -> CGFloat {
        var resolved: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { resolved = NSColor(b).usingColorSpace(.sRGB) }
        guard let x = a.usingColorSpace(.sRGB), let y = resolved else { return .infinity }
        return max(abs(x.redComponent - y.redComponent),
                   max(abs(x.greenComponent - y.greenComponent), abs(x.blueComponent - y.blueComponent)))
    }

    @Test func twelveSwatchesFitTwoRowsOfSix() {
        let (_, size) = render(AccentSwatchGrid(selected: nil, onSelect: { _ in }))
        // 6 × 32 + 5 × 4; Settings' one row of twelve is about 440.
        #expect(size.width == 212)
        #expect(size.height == 2 * AccentSwatchGrid.slot + AccentSwatchGrid.spacing)
    }

    /// Each slot's centre paints its own hue, in catalog order, six to a row. Nothing selected,
    /// so no checkmark sits on a centre. `.none` paints a neutral disc, not a hue, and is skipped.
    @Test func eachSlotPaintsItsOwnHue() {
        let (rep, size) = render(AccentSwatchGrid(selected: nil, onSelect: { _ in }))
        let step = AccentSwatchGrid.slot + AccentSwatchGrid.spacing
        for (i, hue) in LiquidGlassHue.allCases.enumerated() where hue != .none {
            let centre = CGPoint(x: CGFloat(i % 6) * step + AccentSwatchGrid.slot / 2,
                                 y: CGFloat(i / 6) * step + AccentSwatchGrid.slot / 2)
            let painted = paint(rep, centre, in: size)
            #expect(painted.map { distance($0, hue.accentColor) < 0.03 } == true,
                    "\(hue) slot paints \(String(describing: painted))")
        }
    }

    /// Marking Claude's suggestion draws a ring inside its slot, and moves nothing.
    @Test func aSuggestionMovesNoSwatch() {
        let (_, plain) = render(AccentSwatchGrid(selected: .blue, onSelect: { _ in }))
        let (_, marked) = render(AccentSwatchGrid(selected: .blue, suggested: .purple, onSelect: { _ in }))
        #expect(plain == marked)
    }
}
