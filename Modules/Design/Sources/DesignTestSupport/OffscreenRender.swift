import AppKit
import SwiftUI

/// `view` drawn at `size` in a borderless window that is never ordered in or made key, read back as
/// a bitmap: the render-and-read rig the pixel suites in every UI test target share. The window is held
/// until the capture, or the appearance and colour space stop applying.
///
/// - `appearance`: the window's, or nil to leave it unset.
/// - `sRGB`: pin the window's colour space, so raw bytes read as sRGB.
/// - `layoutPasses`: how many `layoutSubtreeIfNeeded` calls before the capture.
/// - `settle`: run the main run loop this long after the first layout, then lay out again, for
///   controls that finish drawing a turn later.
/// - `close`: close the window once captured.
@MainActor
public func offscreenBitmap<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name? = .aqua,
                              sRGB: Bool = true, layoutPasses: Int = 1, settle: TimeInterval = 0,
                              close: Bool = false) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { if close { window.close() } }
    if let appearance { window.appearance = NSAppearance(named: appearance) }
    if sRGB { window.colorSpace = .sRGB }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    if settle > 0 {
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
    }
    for _ in 1..<max(1, layoutPasses) { host.layoutSubtreeIfNeeded() }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}
