import AppKit
import SwiftUI
import Testing
@testable import Design

/// `ProviderLogo` adds nothing to the mark's box: the provider capsule picks its `ViewThatFits`
/// rung by ideal width, so a presentation that grew the logo would silently drop it from the
/// header.
///
/// The asset catalog belongs to the app target, so these renders carry an empty frame; size is
/// what's asserted because it holds whether or not the mark resolves.
@MainActor
@Suite(.serialized) struct ProviderLogoTests {

    /// Every call site's size, in both appearances, since an appearance-driven presentation could
    /// measure one way in light and another in dark.
    /// A brand name and an SF Symbol (a folder source's mark) take the same outer frame.
    @Test func measuresItsDeclaredSizeInEitherAppearance() {
        for name in ["icloud", "folder.fill"] {
            for size in [CGFloat(16), 26, 28] {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    #expect(laidOutSize(name, size: size, appearance: appearance)
                            == CGSize(width: size, height: size), "\(name) at \(size)")
                }
            }
        }
    }

    private func laidOutSize(_ name: String, size: CGFloat, appearance: NSAppearance.Name) -> CGSize {
        let host = NSHostingView(rootView: AnyView(ProviderLogo(name, size: size)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
