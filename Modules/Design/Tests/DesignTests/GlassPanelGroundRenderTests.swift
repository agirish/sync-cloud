import Testing
import AppKit
import SwiftUI
@testable import Design

/// The ground under a floating panel's text (`glassPanelGround`): the window's tinted dark ground in
/// dark at Frosted and Clear (HZ), and exactly the old `controlBackgroundColor` everywhere else.
///
/// The ground is rendered on its own, over black: the glass it sits on in a real panel draws
/// nothing into an offscreen capture, and black keeps a ground that paints nothing from passing
/// for a dark one.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct GlassPanelGroundRenderTests {

    private static let size = CGSize(width: 240, height: 300)

    private func render(_ view: some View, dark: Bool) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color.black))
        host.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func ground(_ level: GlassLevel, hue: LiquidGlassHue = .purple, tint: Double = 0.12,
                        dark: Bool) throws -> NSBitmapImageRep {
        try render(Color.clear.glassPanelGround(level: level, hue: hue, tint: tint,
                                                opacity: level.groundedBackingOpacity, cornerRadius: 12),
                   dark: dark)
    }

    /// What every level painted before HZ, verbatim.
    private func controlBackground(_ level: GlassLevel, dark: Bool) throws -> NSBitmapImageRep {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return try render(Color.clear.background(shape.fill(Color(nsColor: .controlBackgroundColor)
            .opacity(level.groundedBackingOpacity))), dark: dark)
    }

    /// The colour mid-panel, where a panel's text sits.
    private func middle(_ rep: NSBitmapImageRep) throws -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    private func samePixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh
            && a.tiffRepresentation == b.tiffRepresentation
    }

    @Test(arguments: [GlassLevel.frosted, .clear])
    func darkGlassTakesTheWindowsTintedGround(level: GlassLevel) throws {
        let purple = try middle(ground(level, dark: true))
        let neutral = try middle(controlBackground(level, dark: true))
        // Purple's diagonal and glow lean it blue-violet; the old charcoal is grey.
        #expect(purple.b - purple.g > 0.03, "dark \(level) on Purple painted \(purple)")
        #expect(abs(neutral.b - neutral.g) < 0.01, "the neutral reference is \(neutral)")
    }

    @Test(arguments: [GlassLevel.frosted, .clear])
    func darkGlassWithNoAccentIsTheDeepBase(level: GlassLevel) throws {
        // None paints no hue, so what is left is the window's near-black, faintly-cool base —
        // darker than the charcoal it replaces, and cool rather than grey.
        let none = try middle(ground(level, hue: .none, dark: true))
        let neutral = try middle(controlBackground(level, dark: true))
        #expect(none.g < neutral.g, "None's dark \(level) ground \(none) is not below charcoal \(neutral)")
        #expect(none.b > none.r, "None's dark \(level) ground \(none) is not the cool base")
    }

    @Test func theGroundFollowsTheTint() throws {
        let low = try middle(ground(.frosted, tint: 0, dark: true))
        let high = try middle(ground(.frosted, tint: 1, dark: true))
        #expect(high.b - high.g > low.b - low.g + 0.02, "Tint 0 \(low), Tint 1 \(high)")
    }

    @Test(arguments: GlassLevel.allCases)
    func lightIsTheControlBackgroundItAlwaysWas(level: GlassLevel) throws {
        #expect(samePixels(try ground(level, dark: false), try controlBackground(level, dark: false)))
    }

    @Test func darkSolidIsTheControlBackgroundItAlwaysWas() throws {
        #expect(samePixels(try ground(.solid, dark: true), try controlBackground(.solid, dark: true)))
    }

    @Test func darkGlassIsNotTheControlBackground() throws {
        // The premise of the light and Solid checks: the comparison can tell the two grounds apart.
        #expect(!samePixels(try ground(.frosted, dark: true), try controlBackground(.frosted, dark: true)))
    }
}
