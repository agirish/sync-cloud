import AppKit
import SwiftUI
import Testing
@testable import Design

/// `ProviderLogo` gives a brand mark the light page it was drawn for, but only where the surface
/// stops supplying one. Two properties have to hold for that to be safe, and neither is visible
/// in the source: the plate must actually PAINT on a dark appearance and not on a light one, and
/// adding it must cost the view nothing — the provider capsule picks its `ViewThatFits` rung by
/// ideal width, so a logo that grew in dark would drop itself from the header on the appearance
/// that needs it most.
///
/// The asset itself is absent here (the catalog belongs to the app target), which suits the test:
/// what is left in the frame is the plate alone, so a centre sample reads the ground and nothing
/// else.
@MainActor
@Suite(.serialized) struct ProviderLogoTests {

    @Test func plateOnlyAppearsOnADarkAppearance() {
        let backdrop = Color(white: 0.30)
        let dark = centreLuminance(appearance: .darkAqua, over: backdrop)
        let light = centreLuminance(appearance: .aqua, over: backdrop)
        // The plate is white at 0.93, so it lands far above a 0.30 backdrop...
        #expect(dark > 0.80, "dark appearance must paint a light plate, measured \(dark)")
        // ...and on a light appearance nothing is painted at all, so the backdrop survives.
        #expect(abs(light - 0.30) < 0.02, "light appearance must paint no plate, measured \(light)")
    }

    /// The plate is free. Both appearances must measure exactly the declared size — that is what
    /// keeps the capsule's ladder, and therefore whether the logo is shown at all, appearance-blind.
    @Test func costsNothingInEitherAppearance() {
        for size in [CGFloat(16), 26, 28] {
            let dark = laidOutSize(size: size, appearance: .darkAqua)
            let light = laidOutSize(size: size, appearance: .aqua)
            #expect(dark == CGSize(width: size, height: size))
            #expect(light == CGSize(width: size, height: size))
        }
    }

    /// The mark insets *within* the plate rather than the plate growing around the mark — the
    /// property the previous test can only imply. Pinned directly so a later tweak to `markScale`
    /// can't quietly start expanding the view instead.
    @Test func markInsetsWithinThePlate() {
        #expect(ProviderLogo.markScale < 1.0)
        #expect(28 * ProviderLogo.markScale < 28)
    }

    // MARK: Rigs

    private func host<V: View>(_ view: V, _ appearance: NSAppearance.Name, size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func laidOutSize(size: CGFloat, appearance: NSAppearance.Name) -> CGSize {
        host(ProviderLogo("icloud", size: size), appearance, size: CGSize(width: 200, height: 200))
            .fittingSize
    }

    private func centreLuminance(appearance: NSAppearance.Name, over backdrop: Color) -> Double {
        let scene = ZStack { backdrop; ProviderLogo("icloud", size: 28) }
            .frame(width: 60, height: 60)
        let view = host(scene, appearance, size: CGSize(width: 60, height: 60))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return .nan }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / 60.0
        guard let px = rep.colorAt(x: Int(30 * scale), y: Int(30 * scale)) else { return .nan }
        return 0.2126 * Double(px.redComponent) + 0.7152 * Double(px.greenComponent)
             + 0.0722 * Double(px.blueComponent)
    }
}
