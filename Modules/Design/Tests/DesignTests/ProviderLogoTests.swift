import AppKit
import SwiftUI
import Testing
@testable import Design

/// `ProviderLogo` is the one place a provider mark is drawn, so the property worth pinning is that
/// it adds nothing to the mark's box: the provider capsule picks its `ViewThatFits` rung by ideal
/// width, so a presentation that grew the logo would silently drop it from the header. Measured,
/// not read from source, so any change to the presentation has to clear it.
///
/// The asset is absent here (the catalog belongs to the app target), so these renders carry an
/// empty frame. That is why the size is what's asserted: it holds whether or not the mark
/// resolves, while the mark's own pixels are only checkable in the app.
@MainActor
@Suite(.serialized) struct ProviderLogoTests {

    /// Every call site's size, in both appearances, since an appearance-driven presentation could
    /// measure one way in light and another in dark.
    @Test func measuresItsDeclaredSizeInEitherAppearance() {
        for size in [CGFloat(16), 26, 28] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                #expect(laidOutSize(size: size, appearance: appearance)
                        == CGSize(width: size, height: size))
            }
        }
    }

    /// And the two appearances agree, which is what the capsule depends on: the ladder is only
    /// appearance-blind if dark and light measure identically.
    @Test func appearancesAgree() {
        for size in [CGFloat(16), 26, 28] {
            #expect(laidOutSize(size: size, appearance: .darkAqua)
                    == laidOutSize(size: size, appearance: .aqua))
        }
    }

    private func laidOutSize(size: CGFloat, appearance: NSAppearance.Name) -> CGSize {
        let host = NSHostingView(rootView: AnyView(ProviderLogo("icloud", size: size)))
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
