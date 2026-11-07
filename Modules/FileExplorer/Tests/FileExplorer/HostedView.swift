import AppKit
import SwiftUI

/// A view mounted in a real window that is never ordered in: borderless and offscreen, so nothing
/// appears on the machine running the suite, and kept after `close()` so a test can hold it.
@MainActor
enum HostedView {

    /// A bare borderless window, for tests that add AppKit views to its content view themselves.
    static func window(_ rect: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// `view` as the window's content, `size` points, laid out. With `display`, also one display
    /// pass and a second layout: `NSTableView` fills its rows off a display pass, not layout alone.
    static func host<V: View>(_ view: V, size: CGSize,
                              display: Bool = false) -> (host: NSHostingView<V>, window: NSWindow) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = window(host.frame)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        if display {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
            }
            host.layoutSubtreeIfNeeded()
        }
        return (host, window)
    }

    /// ``host(_:size:display:)`` with the SwiftUI frame pinned to `size` too.
    static func framed(_ view: some View, size: CGSize,
                       display: Bool = false) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        host(AnyView(view.frame(width: size.width, height: size.height)), size: size, display: display)
    }
}
