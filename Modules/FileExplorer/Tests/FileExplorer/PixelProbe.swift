import AppKit

/// Colour readings off a rendered bitmap, for the tests that pin WHICH colour a control paints.
///
/// **Components are read as `colorAt` hands them back, never `.usingColorSpace(.sRGB)`'d**: from an
/// sRGB window's cache the colour comes tagged calibrated with the sRGB numbers in it, and
/// "converting" it moves every reading (Green's raw accent read back 0.03–0.07 off).
/// Every rect and box here is in the bitmap's PIXELS, top-left origin, as `colorAt` indexes them.
enum PixelProbe {

    /// `rect` of `view`, drawn the way the screen would and returned as a bitmap.
    @MainActor
    static func render(_ view: NSView, _ rect: CGRect) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// The largest per-channel difference between two colours.
    static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent),
            abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent))
    }

    static func describe(_ c: NSColor) -> String {
        String(format: "(%.3f, %.3f, %.3f)", c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// The commonest colour among the pixels `where` admits, at 8-bit precision.
    static func dominant(in rep: NSBitmapImageRep, where admit: (NSColor) -> Bool = { _ in true }) -> NSColor? {
        var counts: [Int: (Int, NSColor)] = [:]
        forEach(rep, nil) { _, _, c in
            guard admit(c) else { return }
            let key = Int((c.redComponent * 255).rounded()) << 16
                | Int((c.greenComponent * 255).rounded()) << 8 | Int((c.blueComponent * 255).rounded())
            counts[key, default: (0, c)].0 += 1
        }
        return counts.values.max { $0.0 < $1.0 }?.1
    }

    /// The smallest pixel box holding every pixel `where` admits.
    static func bounds(in rep: NSBitmapImageRep, where admit: (NSColor) -> Bool) -> CGRect? {
        var box: CGRect?
        forEach(rep, nil) { x, y, c in
            guard admit(c) else { return }
            let pixel = CGRect(x: x, y: y, width: 1, height: 1)
            box = box.map { $0.union(pixel) } ?? pixel
        }
        return box
    }

    /// How many pixels in `rect` (the whole bitmap when nil) `where` admits.
    static func count(in rep: NSBitmapImageRep, _ rect: CGRect? = nil, where admit: (NSColor) -> Bool) -> Int {
        var n = 0
        forEach(rep, rect) { _, _, c in if admit(c) { n += 1 } }
        return n
    }

    private static func forEach(_ rep: NSBitmapImageRep, _ rect: CGRect?, _ body: (Int, Int, NSColor) -> Void) {
        let area = rect ?? CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        let xs = max(0, Int(area.minX.rounded(.up)))..<min(rep.pixelsWide, Int(area.maxX.rounded(.down)))
        let ys = max(0, Int(area.minY.rounded(.up)))..<min(rep.pixelsHigh, Int(area.maxY.rounded(.down)))
        guard !xs.isEmpty, !ys.isEmpty else { return }
        for y in ys {
            for x in xs {
                if let c = rep.colorAt(x: x, y: y) { body(x, y, c) }
            }
        }
    }
}

extension NSColor {
    /// A white label's pixels: every channel near full.
    var isNearWhite: Bool { min(redComponent, greenComponent, blueComponent) > 0.9 }
    /// Dark ink's pixels: no channel lifted. Deepened Green's brightest channel is ~0.52.
    var isDark: Bool { max(redComponent, greenComponent, blueComponent) < 0.25 }
}
