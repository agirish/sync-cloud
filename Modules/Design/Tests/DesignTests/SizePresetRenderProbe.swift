import Testing
import SwiftUI
import AppKit
@testable import Design

/// A throwaway probe that writes the preset row to PNGs so a person can look at them.
///
/// Geometry and ink counts do not see what a person sees — a row can lay out at the right size
/// with every tile drawing the same specimen, or with the selected tile indistinguishable from
/// the rest, and every measurement still passes. This renders the row in the states that matter
/// and asserts the ones that can be asserted.
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

    /// Every tile draws a *different* picture, which is the whole premise of a specimen tile.
    ///
    /// The failure this exists for is silent: a specimen that ignored its preset would render five
    /// identical faces, the row would still lay out correctly, and every geometry test would pass.
    @MainActor
    @Test func everyTileDrawsADifferentSpecimen() {
        var inkPerTile: [Int] = []
        for preset in SizePreset.all {
            let rep = render(SizePresetSpecimen(preset: preset, isSelected: false),
                             width: 60, height: 40, to: "specimen-\(preset.id)")
            let ink = Self.inkCount(rep)
            #expect(ink > 0, "\(preset.id) drew nothing at all")
            inkPerTile.append(ink)
        }
        #expect(Set(inkPerTile).count > 1,
                "every tile drew the same picture — the specimen ignores its preset")

        // **The pair that has to be distinguishable is the two 100% tiles**, which differ only in
        // row spacing — the percentage under them is identical, so if these render the same the
        // row is asking the user to choose between two things that look alike.
        let compactHundred = render(SizePresetSpecimen(preset: SizePreset.all[1], isSelected: false),
                                    width: 60, height: 40, to: "pair-100-compact")
        let comfortableHundred = render(SizePresetSpecimen(preset: SizePreset.all[2], isSelected: false),
                                        width: 60, height: 40, to: "pair-100-comfortable")
        // Counting DIFFERING pixels, not comparing two ink totals: two different pictures can
        // easily ink to within a percent of each other while looking nothing alike.
        let differing = Self.differingPixels(compactHundred, comfortableHundred)
        #expect(differing >= 0,
                "the two tiles could not be compared at all — the probe is broken, not the control")
        #expect(differing > 40,
                """
                The two 100% tiles differ in only \(differing) sampled pixels — they are the pair \
                a user has to tell apart with no help from the label.
                """)
    }

    /// The selected tile has to look selected. Drawn, not asserted from the flag.
    @MainActor
    @Test func selectionIsVisible() {
        let preset = SizePreset.default
        let off = render(SizePresetSpecimen(preset: preset, isSelected: false),
                         width: 60, height: 40, to: "specimen-unselected")
        let on = render(SizePresetSpecimen(preset: preset, isSelected: true),
                        width: 60, height: 40, to: "specimen-selected")
        let differing = Self.differingPixels(off, on)
        #expect(differing > 0, "the selected specimen renders identically to the unselected one")
    }

    /// The whole row, at both ends of the range, for a person to look at.
    @MainActor
    @Test func rowRendersAtBothEndsOfTheRange() {
        for size in [FontSize.small, .medium, .extraLarge] {
            struct Row: View {
                @State var fontSize: FontSize
                @State var density: ListDensity
                var body: some View {
                    SizePresetRow(fontSize: $fontSize, density: $density)
                }
            }
            let rep = render(Row(fontSize: size, density: .comfortable).appFontSize(size),
                             width: 300, height: 70, to: "row-\(size.percent)")
            #expect(Self.inkCount(rep) > 0, "the row drew nothing at \(size.percent)%")
        }
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

    /// Counts pixels that actually differ, rather than comparing totals — an ink total can agree
    /// to within a couple of percent while a large fraction of the image has changed.
    /// Returns **-1 when it could not compare at all** rather than 0. A guard that answers the
    /// same number as "these are identical" makes a broken harness read as a real finding, which
    /// is exactly what happened the first time this ran.
    private static func differingPixels(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
        guard let a, let b else { return -1 }
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        // **Every pixel, not every other one.** These bars are 2px tall at 100%, and a stride of
        // 2 sampled straight past them: two visibly different tiles compared as 0 differing
        // pixels. The images are 76×40, so there is nothing to save by sampling.
        var count = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(p.redComponent - q.redComponent),
                                max(abs(p.greenComponent - q.greenComponent),
                                    max(abs(p.blueComponent - q.blueComponent),
                                        // **Alpha is not optional here.** These bars are black at
                                        // ~0.27 alpha over a transparent ground, so in the stored
                                        // (premultiplied) bitmap their RGB is 0 — exactly the
                                        // background's. Comparing only RGB reported two visibly
                                        // different tiles as 0 differing pixels, which read as a
                                        // finding about the control and was a hole in this scan.
                                        abs(p.alphaComponent - q.alphaComponent))))
                if delta > 0.03 { count += 1 }
            }
        }
        return count
    }
}
