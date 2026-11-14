import Testing
import SwiftUI
import AppKit
@testable import Design

/// The preset row rendered, with the assertions an ink count can honestly make. Geometry can't see
/// a selected tile that looks like the rest, or two tiles that render identically.
@Suite struct SizePresetRenderProbe {

    @MainActor
    private func render(_ view: some View, width: CGFloat, height: CGFloat) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.frame(width: width).padding(8))
        host.frame = NSRect(x: 0, y: 0, width: width + 16, height: height)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private struct Row: View {
        @State var fontSize: FontSize
        @State var density: ListDensity
        var style: SizePresetRow.Style = .named
        var body: some View { SizePresetRow(fontSize: $fontSize, density: $density, style: style) }
    }

    /// The selected tile looks selected, and moves when the selection does. Drawn rather than read
    /// from the flag: the selected treatment is accent fill, border and text, which layout can't
    /// see.
    @MainActor
    @Test func theSelectionIsVisibleAndFollowsTheSettings() {
        let first = render(Row(fontSize: .small, density: .compact).appFontSize(.medium),
                           width: 420, height: 60)
        let last = render(Row(fontSize: .extraLarge, density: .comfortable).appFontSize(.medium),
                          width: 420, height: 60)

        let differing = Self.differingPixels(first, last)
        #expect(differing >= 0, "the two rows could not be compared — the probe is broken")
        #expect(differing > 100,
                """
                Selecting the first preset and the last renders \(differing) differing pixels — \
                the row is not showing which one is chosen.
                """)
    }

    /// The row draws something at every text size, and grows with it.
    @MainActor
    @Test func theRowRendersAcrossTheRange() {
        var widths: [CGFloat] = []
        for size in [FontSize.small, .medium, .extraLarge] {
            let host = NSHostingView(rootView:
                Row(fontSize: size, density: .comfortable).appFontSize(size))
            host.layoutSubtreeIfNeeded()
            let rep = render(Row(fontSize: size, density: .comfortable).appFontSize(size),
                             width: 420, height: 70)
            #expect(Self.inkCount(rep) > 0, "the row drew nothing at \(size.percent)%")
            widths.append(host.fittingSize.width)
        }
        #expect(widths.first! < widths.last!,
                "the row measured \(widths) across the range — it is not following the text size")
    }

    /// The specimen style is narrower than the named one at every text size, the reason it exists.
    /// The setup card's width is measured in `MacApp`
    /// (`theSetupTextSizeRowFitsTheCardAtEveryTextSize`).
    @MainActor
    @Test func theSpecimenStyleIsNarrowerThanTheNamedOne() {
        for size in FontSize.allCases {
            let specimen = Self.idealWidth(size, style: .specimen)
            let named = Self.idealWidth(size, style: .named)

            #expect(specimen > 0 && named > 0, "a style laid out to nothing at \(size.percent)%")
            #expect(specimen < named,
                    """
                    At \(size.percent)% the specimen row wants \(specimen)pt and the named row \
                    \(named)pt — the setup form's style is buying no width over the words it \
                    exists to avoid.
                    """)
        }
    }

    @MainActor
    private static func idealWidth(_ size: FontSize, style: SizePresetRow.Style) -> CGFloat {
        let host = NSHostingView(rootView:
            Row(fontSize: size, density: .comfortable, style: style).appFontSize(size))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private static func inkCount(_ rep: NSBitmapImageRep?) -> Int {
        guard let rep else { return 0 }
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.05 && color.brightnessComponent < 0.92 { count += 1 }
            }
        }
        return count
    }

    /// Alpha counts: text and borders at partial alpha over a transparent ground carry no RGB
    /// difference in the bitmap.
    private static func differingPixels(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
        Pixel.differing(a, b, tolerance: 0.03, alpha: true)
    }
}
