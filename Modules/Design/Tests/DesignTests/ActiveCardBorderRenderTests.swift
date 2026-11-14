import AppKit
import SwiftUI
import Testing
@testable import Design

/// That the active-pane border actually paints, and in the app's accent. A focus cue that renders
/// as nothing is the failure a green geometry suite can't see. The size-neutrality half lives in
/// `ActivePaneMarkTests` beside the modifier; this is the half a layout assertion is blind to.
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
        offscreenBitmap(AnyView(view), size: Self.box, layoutPasses: 2)
    }

    /// Pixels that differ between two renders by more than sampling noise.
    private func pixelsDiffering(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        Pixel.differing(a, b, sRGB: true)
    }

    /// It paints. The border is quiet by design (45% of the accent at 1.5pt), and quiet is one edit
    /// away from absent.
    @Test func aBorderedCardPaintsSomething() throws {
        let plain = try #require(bitmap(Self.card(nil)))
        let bordered = try #require(bitmap(Self.card(LiquidGlassHue.blue.accentColor)))
        #expect(pixelsDiffering(plain, bordered) > 200,
                "the accent border painted nothing — a cue that renders as nothing is the whole failure mode here")
    }

    /// In the app's accent, which the user chooses, so it can't be a hard-coded blue. Sampled as
    /// "does the render change at all", which is sound only because the fixture is an empty card:
    /// over a whole header, accent-tinted controls would move the comparison on their own.
    @Test func theBorderTakesTheAppAccent() throws {
        let blue = try #require(bitmap(Self.card(LiquidGlassHue.blue.accentColor)))
        let amber = try #require(bitmap(Self.card(LiquidGlassHue.amber.accentColor)))
        #expect(pixelsDiffering(blue, amber) > 100,
                "two far-apart accents rendered the same border — it is painting a fixed colour")
    }

    /// The dimming is applied by the caller, so a border handed the raw accent would be too loud.
    /// Checked in pixels because `activeBorder` could return its argument unchanged and every
    /// constant assertion would still pass.
    @Test func theDimmedAccentPaintsMoreFaintlyThanTheRaw() throws {
        let raw = LiquidGlassHue.blue.accentColor
        let full = try #require(bitmap(Self.card(raw)))
        let dimmed = try #require(bitmap(Self.card(LiquidGlass.activeBorder(raw))))
        #expect(pixelsDiffering(full, dimmed) > 50,
                "the dimmed border renders identically to the full-strength accent — activeBorder is a no-op")
    }
}
