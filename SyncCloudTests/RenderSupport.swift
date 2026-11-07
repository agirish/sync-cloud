import AppKit
import Design
import SwiftUI
import Testing

// MARK: - Reading back what a view drew

/// `view` as it draws now, at its backing scale.
@MainActor
func snapshot(_ view: NSView, sourceLocation: SourceLocation = #_sourceLocation) throws -> NSBitmapImageRep {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                           "the view would not render — every measurement of it is vacuous",
                           sourceLocation: sourceLocation)
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// `view` drawn in a borderless sRGB window of `scheme`, so `colorAt` reads back the colours it
/// painted. With `hue`, the hue is stored in a scratch suite the view reads through
/// `defaultAppStorage`: the test host is the app, and must not read the real setting. The caller
/// frames the view to `size` and gives it its ground.
@MainActor
func renderInSRGBWindow(_ view: some View, size: CGSize, scheme: ColorScheme,
                        hue: LiquidGlassHue? = nil) throws -> NSBitmapImageRep {
    let themed = view.environment(\.colorScheme, scheme)
    let store = TestDefaults()
    let root: AnyView
    if let hue {
        store.defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)
        root = AnyView(themed.defaultAppStorage(store.defaults))
    } else {
        root = AnyView(themed)
    }
    let host = NSHostingView(rootView: root)
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.colorSpace = .sRGB
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return try snapshot(host)
}

/// Pixels within 0.02 of `color` on every channel, read from `colorAt` as it returns them.
@MainActor
func pixels(near color: Color, in rep: NSBitmapImageRep) throws -> Int {
    let target = try #require(NSColor(color).usingColorSpace(.sRGB))
    var n = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if max(abs(c.redComponent - target.redComponent), abs(c.greenComponent - target.greenComponent),
                   abs(c.blueComponent - target.blueComponent)) < 0.02 { n += 1 }
        }
    }
    return n
}

/// How many pixels two renders differ in; `.max` when their sizes differ.
func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
    var count = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide where a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { count += 1 }
    }
    return count
}
