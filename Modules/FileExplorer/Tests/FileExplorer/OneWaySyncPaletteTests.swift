import AppKit
import Testing
@testable import FileExplorer

/// One-way sync's teal and slate are used as text and glyphs (History's outcomes, the side
/// chips' pencil and lock), so each has to read in both appearances, at the body-text floor.
@Suite struct OneWaySyncPaletteTests {
    static let lightSheet = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    static let darkSheet = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)

    func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        var out = NSColor.black
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB)! }
        return out
    }

    func luminance(_ c: NSColor) -> CGFloat {
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (luminance(a) + 0.05, luminance(b) + 0.05)
        return max(x, y) / min(x, y)
    }

    @Test func theSidesReadAsTextInBothAppearances() {
        for (name, color) in [("source", OneWaySyncPalette.sourceNS), ("copy", OneWaySyncPalette.copyNS)] {
            #expect(ratio(resolved(color, .aqua), Self.lightSheet) >= 4.5, "\(name) in light")
            #expect(ratio(resolved(color, .darkAqua), Self.darkSheet) >= 4.5, "\(name) in dark")
        }
    }
}
