import AppKit
import SwiftUI

/// Reading a Restructure surface back, rather than asserting it has a width.
///
/// **`#expect(hosting.fittingSize.width > 0)` closed seventeen render tests here and proves close
/// to nothing** — an `NSHostingView` around an empty `VStack` passes it, so every one of those
/// tests would have survived deleting the thing it was named after. What a render test can
/// honestly claim is *this state draws differently from that one*, and the cheapest way to say it
/// is the drawn pixels themselves: SwiftUI `Text` does not become an `NSTextField`, and the
/// accessibility tree is unpopulated without an assistive client (that channel is test-blind on
/// this machine), so the bitmap is the only channel that carries what was actually drawn.
enum RestructureRender {

    /// The backdrop no part of this UI uses, so "not this colour" means "something was drawn".
    /// An offscreen `NSHostingView` can rasterize fully transparent — blank offscreen renders are
    /// a known hazard here — and against a transparent ground a blank render and a drawn one are
    /// indistinguishable. Compositing over magenta removes that ambiguity.
    static let backdrop = Color(red: 1, green: 0, blue: 1)

    /// Lay a view out at a fixed size over the backdrop and rasterize it. Same size for both sides
    /// of a comparison, or the difference being measured is the frame.
    @MainActor
    static func raster(_ view: some View, width: CGFloat, height: CGFloat) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(
            ZStack { backdrop; view }.frame(width: width, height: height)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// How many pixels are not the magenta backdrop — the "something was drawn at all" measure.
    /// Zero means the surface rendered blank, which is what a card that silently drew nothing and
    /// a view that failed to rasterize offscreen both look like; either way there is nothing for
    /// a difference test to compare, so this is the floor every comparison needs first.
    static func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        guard spp >= 3 else { return 0 }
        let r0: UInt8 = 255, g0: UInt8 = 0, b0: UInt8 = 255
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = y * bpr + x * spp
                if abs(Int(data[p]) - Int(r0)) > 8 || abs(Int(data[p + 1]) - Int(g0)) > 8
                    || abs(Int(data[p + 2]) - Int(b0)) > 8 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Pixels that differ between two renders of the same surface in two states. Zero means the
    /// state made no visible difference — the mutation a `fittingSize` closer cannot see.
    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard let da = a.bitmapData, let db = b.bitmapData,
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              a.samplesPerPixel == b.samplesPerPixel else { return 0 }
        let bpr = min(a.bytesPerRow, b.bytesPerRow), spp = a.samplesPerPixel
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let p = y * bpr + x * spp
                if abs(Int(da[p]) - Int(db[p])) > 8 || abs(Int(da[p + 1]) - Int(db[p + 1])) > 8
                    || abs(Int(da[p + 2]) - Int(db[p + 2])) > 8 {
                    count += 1
                }
            }
        }
        return count
    }

    /// Pixels that read as a caution tint — **the one thing on these cards that only a warning
    /// state paints.** Comparing a whole fresh render against a whole stale one is not a test of
    /// the staleness branch: the two also carry different date sentences, so they differ whatever
    /// the branch does, and hard-coding `stale = false` at the call site left such a comparison
    /// passing. Counting the amber isolates it.
    ///
    /// Warm (red clearly above blue, green between them), which system orange is and none of the
    /// greys, the accent blue, or the text on these surfaces are.
    static func cautionPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        guard spp >= 3 else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = y * bpr + x * spp
                let r = Int(data[p]), g = Int(data[p + 1]), b = Int(data[p + 2])
                // Magenta backdrop is r high AND b high — excluded by requiring green above blue.
                if r > 160, r - b > 60, g > b, r - g > 30 { count += 1 }
            }
        }
        return count
    }
}
