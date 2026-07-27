import AppKit
import SwiftUI
import Testing
@testable import Design

/// `ProviderLogo` is the one place a provider mark is drawn, so the property worth pinning is that
/// it costs the mark's box nothing — the provider capsule picks its `ViewThatFits` rung by ideal
/// width, so any presentation that grew the logo would drop the logo from the header, and would do
/// it silently.
///
/// It measures rather than reads the source because the presentation is still being iterated: a
/// light plate was added and reverted (`d9e9698`), and the next attempt will land in the same view.
/// This is the guard rail that attempt has to clear.
///
/// The asset is absent here — the catalog belongs to the app target — so these renders carry an
/// empty frame. That is exactly why the size assertion is the one that matters: it holds whether or
/// not the mark resolves, while anything about the mark's own pixels is only verifiable in the app.
@MainActor
@Suite(.serialized) struct ProviderLogoTests {

    /// Every call site's size, in both appearances. Appearance is included because the reverted
    /// plate was appearance-driven — the failure mode it could have introduced was a logo that
    /// measured one way in light and another in dark.
    @Test func measuresItsDeclaredSizeInEitherAppearance() {
        for size in [CGFloat(16), 26, 28] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                #expect(laidOutSize(size: size, appearance: appearance)
                        == CGSize(width: size, height: size))
            }
        }
    }

    /// And the two appearances agree with each other, which is the form the capsule actually
    /// depends on: the ladder is only appearance-blind if dark and light measure identically.
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
