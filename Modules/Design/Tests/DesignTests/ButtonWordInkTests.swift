import AppKit
import SwiftUI
import Testing
@testable import Design

/// **A button whose words wear a colour reads at 4.5:1 on its bezel, in both appearances** (RC3).
///
/// A `.bordered` or `.borderless` button draws its `.tint` as the label's text. Tinted with the raw
/// hue, those words measured 2.3:1 on the light bezel at Green — the DS4 comment's own figure.
/// `ChromeInk.buttonWords` deepens the colour to body-text depth in light and takes label colour in
/// dark. Rendered and read back: the bezel's grey is sampled, not assumed, and one button's words
/// are read off the render so the arithmetic is tied to what AppKit paints.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct ButtonWordInkTests {

    static let textFloor: CGFloat = 4.5
    static let size = CGSize(width: 160, height: 40)

    /// Every colour a button's words are tinted with: each hue's accent, and the semantic table.
    static var colours: [(String, Color)] {
        LiquidGlassHue.allCases.map { ("hue \($0.displayName)", $0.accentColor) }
            + SemanticColor.all.filter { $0.name != "neutral" }.map { ($0.name, $0.color) }
    }

    static func render(_ view: some View, dark: Bool) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        return rep
    }

    static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        var p = [Int](repeating: 0, count: 4)
        rep.getPixel(&p, atX: x, y: y)
        return NSColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    }

    /// The bezel's own grey: a `.bordered` button with an empty label, sampled at its middle.
    static func bezel(dark: Bool) throws -> NSColor {
        let button = Button {} label: { Color.clear.frame(width: 80, height: 10) }.buttonStyle(.bordered)
        let rep = try render(button, dark: dark)
        let s = CGFloat(rep.pixelsWide) / size.width
        return pixel(rep, Int(size.width / 2 * s), Int(size.height / 2 * s))
    }

    /// The ground a `.borderless` button's words sit on.
    static func ground(dark: Bool) throws -> NSColor {
        let rep = try render(Color.clear, dark: dark)
        return pixel(rep, 2, 2)
    }

    /// **Every colour, both appearances, on the bezel and on the bare ground.**
    @Test(arguments: [false, true]) func theWordsReadOnTheBezelAndTheGround(dark: Bool) throws {
        let bezel = try Self.bezel(dark: dark)
        let ground = try Self.ground(dark: dark)
        // The bezel is a bezel: distinct from the ground, or the probe sampled the wrong thing.
        #expect(abs(PillLabelInkTests.lum(bezel) - PillLabelInkTests.lum(ground)) > 0.01, "no bezel sampled: \(bezel) on \(ground)")
        let scheme: ColorScheme = dark ? .dark : .light
        for (name, colour) in Self.colours {
            let ink = PillLabelInkTests.resolved(ChromeInk.buttonWords(scheme, colour), dark: dark)
            let onBezel = PillLabelInkTests.ratio(ink, bezel)
            let onGround = PillLabelInkTests.ratio(ink, ground)
            #expect(onBezel >= Self.textFloor, "\(name)'s words in \(dark ? "dark" : "light") are \(onBezel):1 on the bezel")
            #expect(onGround >= Self.textFloor, "\(name)'s words in \(dark ? "dark" : "light") are \(onGround):1 on the ground")
        }
    }

    /// **The fixture reproduces the defect**: the raw hue as words misses the floor on the light
    /// bezel — Green is the DS4 comment's 2.3:1 — so the test above is not passing on a pairing that
    /// was always fine.
    @Test func theRawHueMissedTheFloorOnTheLightBezel() throws {
        let bezel = try Self.bezel(dark: false)
        let raw = PillLabelInkTests.resolved(LiquidGlassHue.green.accentColor, dark: false)
        let r = PillLabelInkTests.ratio(raw, bezel)
        #expect(r < 2.5, "raw Green on the light bezel is \(r):1 — the defect is gone")
    }

    /// The extreme pixel against `bezel` — the darkest in light, the brightest in dark: the words.
    static func wordsRatio(_ rep: NSBitmapImageRep, bezel: NSColor, dark: Bool) -> CGFloat {
        var best: CGFloat = 1
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            let c = pixel(rep, x, y)
            let r = PillLabelInkTests.ratio(c, bezel)
            if r > best, dark ? PillLabelInkTests.lum(c) > PillLabelInkTests.lum(bezel)
                              : PillLabelInkTests.lum(c) < PillLabelInkTests.lum(bezel) { best = r }
        } }
        return best
    }

    /// **Read off the render**: under a sheet's deepened root tint, a Cancel tinted with
    /// `buttonWordsTint` paints its words at the floor. The same Cancel with no tint of its own
    /// takes the root's deepened fill as its words and misses it — measured 2.9:1 dark, 3.8:1
    /// light — so the probe can see the case the PDF sheets' Cancel was in.
    @Test(arguments: [false, true]) func aTintedButtonsWordsPaintAtTheFloor(dark: Bool) throws {
        let hue = LiquidGlassHue.green
        let bezel = try Self.bezel(dark: dark)
        let tinted = HStack { Button("Cancel") {}.buttonStyle(.bordered).buttonWordsTint(hue.accentColor) }
            .tint(hue.accentFillColor)
        let r = Self.wordsRatio(try Self.render(tinted, dark: dark), bezel: bezel, dark: dark)
        #expect(r >= Self.textFloor, "Cancel's words in \(dark ? "dark" : "light") paint at \(r):1 on the bezel")
        let bare = HStack { Button("Cancel") {}.buttonStyle(.bordered) }.tint(hue.accentFillColor)
        let b = Self.wordsRatio(try Self.render(bare, dark: dark), bezel: bezel, dark: dark)
        #expect(b < Self.textFloor, "an untinted Cancel under the root reads at \(b):1 — the probe proves nothing")
    }
}
