import Testing
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// **Swipe's divider, and Difference's region outlines, draw in the app's accent.**
///
/// Both drew in `Color.accentColor`, which in this view is the SYSTEM accent: pick Coral in the app
/// and the divider stayed whatever System Settings says. The view is now handed the hue's accent.
/// Rendered and read back, because only the pixels say which accent a 1pt line took.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct VisualPairSwipeAccentTests {

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theSwipeDividerIsTheAppAccent(scheme: ColorScheme) throws {
        let coral = try #require(NSColor(LiquidGlassHue.coral.accentColor).usingColorSpace(.sRGB))
        // 201 wide at a half swipe puts the 1pt line on x 100–101 exactly, so no pixel of it is
        // blended with the page beside it.
        let size = CGSize(width: 201, height: 120)
        let subject = VisualPairModeView(mode: .swipe, left: nil, right: nil, outcome: .rendering,
                                         leftName: "a.pdf", rightName: "b.pdf", difference: nil,
                                         accent: LiquidGlassHue.coral.accentColor,
                                         swipeFraction: .constant(0.5), onionOpacity: .constant(0.5))
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host

        // The top of the line, clear of the pages' centred spinners.
        let line = try #require(PixelProbe.render(host, CGRect(x: 100, y: 4, width: 1, height: 30)))
        let drawn = try #require(PixelProbe.dominant(in: line))
        #expect(PixelProbe.distance(drawn, coral) < 0.01,
                "Swipe's divider draws \(PixelProbe.describe(drawn)) in \(scheme), not the app's Coral \(PixelProbe.describe(coral))")
        // …and the column beside it is not the line, or the probe is reading a fill, not a divider.
        let beside = try #require(PixelProbe.render(host, CGRect(x: 96, y: 4, width: 1, height: 30)))
        let ground = try #require(PixelProbe.dominant(in: beside))
        #expect(PixelProbe.distance(ground, coral) > 0.1, "the column beside the divider is Coral too in \(scheme)")
    }
}
