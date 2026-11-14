import AppKit
import SwiftUI

/// Rasterizing a view offscreen and comparing two renders, for the pixel tests.
@MainActor
enum PixelDiff {

    /// Rasterizes `view` at `size` in a borderless window that is never ordered in, with the
    /// window's `appearance` and an sRGB colour space. The window matters: without one the layer
    /// gets no backing store and `cacheDisplay` returns a blank rep. Frame, background and colour
    /// scheme are the caller's, applied to `view` before it comes here.
    static func render(_ view: some View, size: CGSize,
                       appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep? {
        render(view, size: size, appearance: appearance, passes: 1)
    }

    /// `render(_:size:appearance:)`, laid out `passes` times: twice where a first layout writes
    /// state (`.onGeometryChange`) that the drawn frame must reflect.
    static func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name = .aqua,
                       passes: Int) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        for _ in 0..<passes { host.layoutSubtreeIfNeeded() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels whose largest red, green or blue difference exceeds `tolerance`, over the area both
    /// renders share and left of pixel column `beforeX`.
    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                                tolerance: CGFloat, beforeX: Int = .max) -> Int {
        var differing = 0
        for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
            for x in 0..<min(beforeX, a.pixelsWide, b.pixelsWide) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if max(abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent),
                       abs(p.blueComponent - q.blueComponent)) > tolerance { differing += 1 }
            }
        }
        return differing
    }

    /// The same count inside `box`, in pixels with its edges truncated; `.max` when the two renders
    /// differ in size.
    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                                tolerance: CGFloat, in box: NSRect) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var differing = 0
        for y in Int(box.minY)..<min(a.pixelsHigh, Int(box.maxY)) {
            for x in Int(box.minX)..<min(a.pixelsWide, Int(box.maxX)) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if PixelProbe.distance(p, q) > tolerance { differing += 1 }
            }
        }
        return differing
    }
}
