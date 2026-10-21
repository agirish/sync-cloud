import AppKit
import Design
import SwiftUI
import Testing
@testable import SyncCloud

/// **Help wears the hue the user picked.**
///
/// It kept the SYSTEM accent (C7, `3e6264e79`) — the open topic's fill was `Color.accentColor`
/// deepened, its article's words and tip wash `Color.accentColor` — so on a Coral card the sidebar
/// lit up in the Mac's blue. The hue comes from a scratch suite through `defaultAppStorage` (the
/// test host IS the app, so the real preference must not be read), and the pixels are read back
/// as `colorAt` returns them: Coral's deepened fill must be there under Coral and absent under
/// Green.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct HelpAccentTests {

    private func render(hue: LiquidGlassHue, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let store = TestDefaults()
        store.defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)
        let size = CGSize(width: 820, height: 600)
        let host = NSHostingView(rootView: AnyView(
            HelpView(available: size, openAt: "browse-workspace", onClose: {})
                .frame(width: size.width, height: size.height)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                .defaultAppStorage(store.defaults)))
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

    private func pixels(near color: Color, in rep: NSBitmapImageRep) throws -> Int {
        let target = try #require(NSColor(color).usingColorSpace(.sRGB))
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

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func theOpenTopicFillsWithTheHueDeepened(scheme: ColorScheme) throws {
        let fill = LiquidGlassHue.coral.accentFillColor
        let underCoral = try pixels(near: fill, in: render(hue: .coral, scheme: scheme))
        let underGreen = try pixels(near: fill, in: render(hue: .green, scheme: scheme))
        // The open row is ~200×26pt of fill, minus its label.
        #expect(underCoral > 1_000, "Help's open topic drew \(underCoral) pixels of Coral's fill in \(scheme) with Coral picked")
        #expect(underGreen == 0, "Help's open topic drew \(underGreen) pixels of Coral's fill in \(scheme) with Green picked")
    }
}
