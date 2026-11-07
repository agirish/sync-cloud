import AppKit
import SwiftUI

/// Reading a Restructure surface back, rather than asserting it has a width.
///
/// `hosting.fittingSize.width > 0` proves next to nothing: an `NSHostingView` around an empty
/// `VStack` passes it. A render test can honestly claim *this state draws differently from that
/// one*, and the drawn pixels are the only channel for it: SwiftUI `Text` doesn't become an
/// `NSTextField`, and the accessibility tree is empty without an assistive client.
enum RestructureRender {

    /// The backdrop no part of this UI uses, so "not this colour" means "something was drawn". An
    /// offscreen `NSHostingView` can rasterize fully transparent, where a blank render and a drawn
    /// one look the same; compositing over magenta removes that ambiguity.
    static let backdrop = Color(red: 1, green: 0, blue: 1)

    /// Lays a view out at a fixed size over the backdrop and rasterizes it. Use one size for both
    /// sides of a comparison, or the difference measured is the frame.
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

    /// How many pixels are not the magenta backdrop: the "something was drawn" measure. Zero means
    /// a blank render (a card that drew nothing, or a view that failed to rasterize), leaving a
    /// difference test nothing to compare, so every comparison needs this floor first.
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
    /// state made no visible difference, which a `fittingSize` check can't see.
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

    /// Pixels that read as a caution tint, the one thing on these cards only a warning state
    /// paints. A fresh render and a stale one also carry different date sentences, so they differ
    /// whatever the staleness branch does; counting the amber isolates it.
    ///
    /// Warm (red clearly above blue, green between them): system orange is, and none of the greys,
    /// the accent blue or the text on these surfaces are.
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

    /// Pixels that read as a success tint: green-dominant, which none of the greys, the text or the
    /// accent blue on these surfaces are. The counterpart to ``cautionPixels(_:)``, for the same
    /// reason: a comparison can pass on any incidental difference, so asserting a run is marked
    /// has to name the mark.
    static func successPixels(_ rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        guard spp >= 3 else { return 0 }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = y * bpr + x * spp
                let r = Int(data[p]), g = Int(data[p + 1]), b = Int(data[p + 2])
                if g - r > 25, g - b > 25 { count += 1 }
            }
        }
        return count
    }

    /// Where the leftmost success-tinted pixel is, as a fraction of the render's width; nil when
    /// nothing green was drawn. The renames card's "After" column is its only green, so two renders
    /// at different widths say whether the columns divide the card evenly (the edge tracks the
    /// width) or fit their content (it stays). A fraction, because the rep comes back at the
    /// display's backing scale.
    static func leftmostSuccessFraction(_ rep: NSBitmapImageRep) -> Double? {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3, rep.pixelsWide > 0 else {
            return nil
        }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                let p = y * bpr + x * spp
                let r = Int(data[p]), g = Int(data[p + 1]), b = Int(data[p + 2])
                if g - r > 25, g - b > 25 { return Double(x) / Double(rep.pixelsWide) }
            }
        }
        return nil
    }
}
