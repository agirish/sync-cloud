import Testing
import SwiftUI
import AppKit
@testable import Design

/// The preset row rendered, with the assertions an ink count can honestly make about it — and a
/// PNG per state when `SIZE_PRESET_PROBE_DIR` is set, so a person can look.
///
/// Geometry does not see what a person sees: a row can lay out at exactly the right size with the
/// selected tile indistinguishable from the rest, or with two tiles that a user has to tell apart
/// rendering identically, and every measurement still passes.
@Suite struct SizePresetRenderProbe {

    @MainActor
    private func render(_ view: some View, width: CGFloat, height: CGFloat, to name: String) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.frame(width: width).padding(8))
        host.frame = NSRect(x: 0, y: 0, width: width + 16, height: height)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["SIZE_PRESET_PROBE_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private struct Row: View {
        @State var fontSize: FontSize
        @State var density: ListDensity
        var style: SizePresetRow.Style = .named
        var body: some View { SizePresetRow(fontSize: $fontSize, density: $density, style: style) }
    }

    /// The selected tile looks selected, and it moves when the selection does.
    ///
    /// Drawn rather than asserted from the flag: the tile's whole selected treatment is an accent
    /// fill, an accent border and accent text, none of which a layout test can see.
    @MainActor
    @Test func theSelectionIsVisibleAndFollowsTheSettings() {
        let first = render(Row(fontSize: .small, density: .compact).appFontSize(.medium),
                           width: 420, height: 60, to: "row-selected-first")
        let last = render(Row(fontSize: .extraLarge, density: .comfortable).appFontSize(.medium),
                          width: 420, height: 60, to: "row-selected-last")

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
                             width: 420, height: 70, to: "row-\(size.percent)")
            #expect(Self.inkCount(rep) > 0, "the row drew nothing at \(size.percent)%")
            widths.append(host.fittingSize.width)
        }
        #expect(widths.first! < widths.last!,
                "the row measured \(widths) across the range — it is not following the text size")
    }

    /// The specimen style is genuinely narrower than the named one — the whole reason it exists.
    ///
    /// **The words are what do not fit**, and this is the property Design can own: the exact width
    /// the setup card offers belongs to `MacApp` and is measured there
    /// (`theSetupTextSizeRowFitsTheCardAtEveryTextSize`). What can be asserted here is that
    /// choosing `.specimen` actually buys width at every text size. If it ever stops doing so, the
    /// style is costing a second code path for nothing and the setup form should use the words.
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

    /// Returns **-1 when it could not compare at all** rather than 0. A guard answering the same
    /// number as "these are identical" makes a broken harness read as a real finding.
    private static func differingPixels(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
        guard let a, let b else { return -1 }
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        var count = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent),
                                max(abs(p.greenComponent - q.greenComponent),
                                    max(abs(p.blueComponent - q.blueComponent),
                                        // Alpha is not optional: text and borders drawn at partial
                                        // alpha over a transparent ground carry no RGB difference
                                        // at all in the stored bitmap.
                                        abs(p.alphaComponent - q.alphaComponent))))
                if delta > 0.03 { count += 1 }
            }
        }
        return count
    }
}
