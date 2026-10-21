import Testing
import AppKit
import SwiftUI
@testable import Design

/// `LiquidGlassHue.stored(in:)` — what a colour parameter defaults to now that none may default to
/// `Color.accentColor` (`AccentFillScanTests`, rule 4).
@Suite struct StoredHueTests {

    @Test func theStoredHueIsReadAndBlueStandsInForNone() throws {
        let store = StoredHueAccentTests.store(nil)
        #expect(LiquidGlassHue.stored(in: store) == .blue, "nothing stored reads as the app's default, Blue")
        store.set(LiquidGlassHue.green.rawValue, forKey: LiquidGlass.hueKey)
        #expect(LiquidGlassHue.stored(in: store) == .green)
        store.set("no-such-hue", forKey: LiquidGlass.hueKey)
        #expect(LiquidGlassHue.stored(in: store) == .blue, "an unreadable value falls back as @AppStorage reads do")
    }
}

/// **A control handed no colour draws in the hue the user picked.**
///
/// Settings' size tiles and every `hoverAffordance`, `chromeHover`, `HoverChevron` and
/// `TextSizeStepper` left untinted drew SwiftUI's `Color.accentColor` — the SYSTEM accent — so in a
/// Coral window they stayed the Mac's blue. Each now reads the stored hue where it is drawn. The hue
/// comes from a scratch suite through `defaultAppStorage`, and the pixels are read back, because
/// only they say which accent a border or a glyph took. Coral, since it is nowhere near any system
/// accent; Green as the control, so a reading cannot pass by Coral being hard-wired.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct StoredHueAccentTests {

    /// A fresh scratch suite holding `hue` (or nothing), so no test reads or writes the real
    /// preference. Wiped, plist and all, when the last view holding it goes.
    nonisolated static func store(_ hue: LiquidGlassHue?) -> UserDefaults {
        let defaults = ScratchDefaults("StoredHueAccentTests")
        if let hue { defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey) }
        return defaults
    }

    /// `view` drawn in an sRGB window of `scheme`, with `hue` stored.
    private func render(_ view: some View, size: CGSize, hue: LiquidGlassHue,
                        scheme: ColorScheme) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view
            .frame(width: size.width, height: size.height)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(Self.store(hue))))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels within 0.02 of `hue`'s raw accent on every channel, read from `colorAt` as-is.
    private func pixels(of hue: LiquidGlassHue, in rep: NSBitmapImageRep) throws -> Int {
        let target = try #require(NSColor(hue.accentColor).usingColorSpace(.sRGB))
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if max(abs(c.redComponent - target.redComponent), abs(c.greenComponent - target.greenComponent),
                       abs(c.blueComponent - target.blueComponent)) < 0.02 { n += 1 }
            }
        }
        return n
    }

    /// Draws `view` under Coral and under Green: Coral's pixels must appear under Coral, at least
    /// `minimum` of them, and none under Green.
    private func expectWearsTheStoredHue(_ view: some View, size: CGSize, atLeast minimum: Int, _ what: String) throws {
        for scheme in [ColorScheme.light, .dark] {
            let coral = try pixels(of: .coral, in: render(view, size: size, hue: .coral, scheme: scheme))
            let green = try pixels(of: .coral, in: render(view, size: size, hue: .green, scheme: scheme))
            #expect(coral >= minimum, "\(what) drew \(coral) Coral pixels in \(scheme) with Coral picked — not the app's hue")
            #expect(green == 0, "\(what) drew \(green) Coral pixels in \(scheme) with Green picked — the hue is not read")
        }
    }

    @Test func theChosenSizeTileWearsTheStoredHue() throws {
        let preset = try #require(SizePreset.all.first)
        let row = SizePresetRow(fontSize: .constant(preset.fontSize), density: .constant(preset.density),
                                style: .named)
        // The chosen tile's 1.5pt border alone is a few hundred pixels.
        try expectWearsTheStoredHue(row.padding(8), size: CGSize(width: 440, height: 64), atLeast: 100,
                                    "the chosen size tile")
    }

    @Test func aTextSizeStepperHandedNoTintWearsTheStoredHue() throws {
        try expectWearsTheStoredHue(TextSizeStepper(size: .constant(.medium)).padding(8),
                                    size: CGSize(width: 120, height: 40), atLeast: 5, "the stepper's middle A")
    }

    @Test func aHoverChevronHandedNoTintWearsTheStoredHue() throws {
        let engaged = HoverChevron().environment(\.hoverAffordancePhase, .hover).scaleEffect(3)
        try expectWearsTheStoredHue(engaged.padding(8), size: CGSize(width: 60, height: 60), atLeast: 5,
                                    "an engaged row's chevron")
    }
}
