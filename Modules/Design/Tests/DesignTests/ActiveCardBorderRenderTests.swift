import AppKit
import SwiftUI
import Testing
@testable import Design

/// **That the active-pane border actually paints, and in the app's accent.**
///
/// Inherited from `PaneFocusRingTests`, which measured exactly this about the ring around a pane's
/// provider capsule — a second indicator of the same fact, removed on 2026-08-24 in favour of this
/// border. That suite's standing lesson comes with it: **a focus cue that renders as nothing is the
/// failure a green geometry suite cannot see**, and this feature has already shipped once with no
/// indicator at all.
///
/// The size-neutrality half lives in `ActivePaneMarkTests` beside the modifier. Here is the half a
/// layout assertion is blind to.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct ActiveCardBorderRenderTests {

    private static let box = CGSize(width: 220, height: 110)

    private static func card(_ accent: Color?) -> some View {
        Color.clear
            .frame(width: box.width - 20, height: box.height - 20)
            .surfaceCard(.solid, accentBorder: accent)
            .frame(width: box.width, height: box.height)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func bitmap(_ view: some View) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(origin: .zero, size: Self.box)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels that differ between two renders by more than sampling noise.
    private func pixelsDiffering(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
        var count = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.02
                    || abs(p.greenComponent - q.greenComponent) > 0.02
                    || abs(p.blueComponent - q.blueComponent) > 0.02 { count += 1 }
            }
        }
        return count
    }

    /// **It paints.** The border is quiet by design — 45% of the accent at 1.5pt — and "quiet" is
    /// one edit away from "absent"; the wash that shipped alongside the first version of this mark
    /// was invisible in both themes and nothing failed.
    @Test func aBorderedCardPaintsSomething() throws {
        let plain = try #require(bitmap(Self.card(nil)))
        let bordered = try #require(bitmap(Self.card(LiquidGlassHue.blue.accentColor)))
        #expect(pixelsDiffering(plain, bordered) > 200,
                "the accent border painted nothing — a cue that renders as nothing is the whole failure mode here")
    }

    /// **In the app's accent, which the user chooses**, so it cannot be a hard-coded blue.
    ///
    /// Sampled as "does the render change at all", which is sound here only because the fixture is
    /// an empty card: `PaneFocusRingTests` could not do this over a whole header, because the pane
    /// bar's controls are accent-tinted too and would move a comparison on their own.
    @Test func theBorderTakesTheAppAccent() throws {
        let blue = try #require(bitmap(Self.card(LiquidGlassHue.blue.accentColor)))
        let amber = try #require(bitmap(Self.card(LiquidGlassHue.amber.accentColor)))
        #expect(pixelsDiffering(blue, amber) > 100,
                "two far-apart accents rendered the same border — it is painting a fixed colour")
    }

    /// The dimming is applied by the caller, so a border handed the RAW accent would be the loud
    /// one that was reported. Distinguishable in pixels, which is the point: `activeBorder` could
    /// be edited to return its argument unchanged and every constant assertion would still pass.
    @Test func theDimmedAccentPaintsMoreFaintlyThanTheRaw() throws {
        let raw = LiquidGlassHue.blue.accentColor
        let full = try #require(bitmap(Self.card(raw)))
        let dimmed = try #require(bitmap(Self.card(LiquidGlass.activeBorder(raw))))
        #expect(pixelsDiffering(full, dimmed) > 50,
                "the dimmed border renders identically to the full-strength accent — activeBorder is a no-op")
    }
}
