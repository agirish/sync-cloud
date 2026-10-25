import AppKit
import SwiftUI
import Testing
@testable import Design

/// **A coloured pill's words are label colour; the colour is the wash (DS1).**
///
/// The owner's call: the word in its own colour on a wash of that colour measured, in light, 1.4:1
/// for yellow, about 1.9:1 for green, 2:1 for orange and 2.8:1 for red. Now the words and their
/// glyph take `PillVariant.labelInk(for:)` — black in light, white in dark — and the tint stays in
/// the wash, the hairline and any dot.
@Suite struct PillLabelInkTests {

    static let textFloor: CGFloat = 4.5

    /// Every colour a pill is tinted with: the semantic table and every hue's accent.
    static var tints: [(String, Color)] {
        SemanticColor.all.map { ($0.name, $0.color) }
            + LiquidGlassHue.allCases.map { ("hue \($0.displayName)", $0.accentColor) }
    }

    @Test func aColouredPillsWordsAreLabelColourAndANeutralOneStaysQuiet() {
        for (name, tint) in Self.tints {
            #expect(PillVariant.labelInk(for: tint) == .primary, "\(name)'s words are not label colour")
        }
        #expect(PillVariant.labelInk(for: .secondary) == .secondary, "a neutral pill went loud")
    }

    static func resolved(_ color: Color, dark: Bool) -> NSColor {
        var out = NSColor.white
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .white
        }
        return out
    }

    /// `top` at its own alpha (times `alpha`) over an opaque `bottom`.
    static func over(_ top: NSColor, alpha: CGFloat = 1, _ bottom: NSColor) -> NSColor {
        let a = top.alphaComponent * alpha
        return NSColor(srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
                       green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                       blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
    }

    static func lum(_ c: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }

    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (lum(a) + 0.05, lum(b) + 0.05)
        return max(x, y) / min(x, y)
    }

    /// The grounds pills sit on — the sheets either side of the app's surfaces.
    static func ground(dark: Bool) -> NSColor {
        dark ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1)
             : NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    }

    /// **The words on the wash, every tint, both appearances, at 4.5:1 or better** — label colour
    /// at its own alpha over the tint's wash over the ground, as the pill composites it.
    @Test func theWordsReadOnTheirWashInBothAppearances() {
        for (name, tint) in Self.tints {
            for dark in [false, true] {
                let wash = Self.over(Self.resolved(tint, dark: dark), alpha: PillVariant.fillOpacity, Self.ground(dark: dark))
                let ink = Self.over(Self.resolved(PillVariant.labelInk(for: tint), dark: dark), wash)
                let r = Self.ratio(ink, wash)
                #expect(r >= Self.textFloor, "\(name) pill words in \(dark ? "dark" : "light") are \(r):1 on their wash")
            }
        }
    }

    /// **The fixture reproduces the defect**: the word in its own tint misses the floor on its wash
    /// in light for the colours the review measured, so the test above is not passing on a pairing
    /// that was always fine.
    @Test func theTintedWordMissedTheFloorInLight() {
        for (name, tint) in [("caution", SemanticColor.caution), ("success", SemanticColor.success),
                             ("warning", SemanticColor.warning), ("error", SemanticColor.error)] {
            let wash = Self.over(Self.resolved(tint, dark: false), alpha: PillVariant.fillOpacity, Self.ground(dark: false))
            let r = Self.ratio(Self.resolved(tint, dark: false), wash)
            #expect(r < Self.textFloor, "\(name) on its own wash is \(r):1 — the defect is gone")
        }
    }

    /// **The pill still reads as its colour**: the wash is measurably the tint, not grey. Chroma
    /// (max − min channel) of the composited wash, against the ground's zero.
    @Test func theWashStillCarriesTheColour() {
        for (name, tint) in SemanticColor.all.filter({ $0.name != "neutral" }).map({ ($0.name, $0.color) }) {
            for dark in [false, true] {
                let wash = Self.over(Self.resolved(tint, dark: dark), alpha: PillVariant.fillOpacity, Self.ground(dark: dark))
                let channels = [wash.redComponent, wash.greenComponent, wash.blueComponent]
                let chroma = (channels.max() ?? 0) - (channels.min() ?? 0)
                #expect(chroma >= 0.06, "\(name)'s wash in \(dark ? "dark" : "light") is near grey (chroma \(chroma))")
            }
        }
    }
}

/// **Rendered and read back**: the words paint black in light and white in dark, the wash keeps
/// the tint — and the PNGs are written out to be looked at.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PillLabelInkRenderTests {

    static let size = CGSize(width: 380, height: 260)

    static func specimen(dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // A known swatch, read back first: the probe is trusted only if this reads exactly.
            Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 12, height: 12)
            Pill(.mini, tint: SemanticColor.caution, systemImage: "exclamationmark.triangle", text: "Caution caution")
            HStack(spacing: 6) {
                Pill(.mini, tint: SemanticColor.success, systemImage: "checkmark", text: "Keep")
                Pill(.mini, tint: SemanticColor.error, systemImage: "trash", text: "Move to Trash")
                Pill(.mini, tint: SemanticColor.warning, systemImage: "arrow.triangle.merge", text: "Fold in")
            }
            HStack(spacing: 6) {
                StatusBadge(isValid: true)
                StatusBadge(isValid: false)
            }
            Pill(.standard, tint: LiquidGlassHue.coral.accentColor, systemImage: "externaldrive", count: 7, label: "Differences")
            TokenChipsRow(items: [.init(label: "kind:pdf", word: "kind:pdf", isActive: true),
                                  .init(label: "size:>1MB", word: "size:>1MB", isActive: false)],
                          tint: LiquidGlassHue.coral.accentColor, onRemove: { _ in })
            Pill(.mini, tint: .secondary, text: "12", isNumeric: true)
        }
        .padding(12)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(dark ? Color(red: 0.13, green: 0.13, blue: 0.13) : Color(red: 0.96, green: 0.96, blue: 0.96))
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.appFontScale, 1.6)
    }

    static func render(dark: Bool) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: specimen(dark: dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SyncCloud-DS1-pills-\(dark ? "dark" : "light").png")
        try rep.representation(using: .png, properties: [:])?.write(to: out)
        print("[DS1] wrote \(out.path)")
        return rep
    }

    /// The pixel at (x, y) in points, as raw sRGB bytes scaled to 0…1.
    static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
        var p = [Int](repeating: 0, count: 4)
        rep.getPixel(&p, atX: x, y: y)
        return (CGFloat(p[0]) / 255, CGFloat(p[1]) / 255, CGFloat(p[2]) / 255)
    }

    /// The caution pill's row: the darkest pixel (light) or brightest (dark) is its words, and in
    /// label colour it is a near-neutral black or white — where the tinted word was a yellow whose
    /// darkest pixel sat near L 0.8.
    @Test(arguments: [false, true]) func theWordsPaintInLabelColour(dark: Bool) throws {
        let rep = try Self.render(dark: dark)
        let scale = CGFloat(rep.pixelsWide) / Self.size.width
        // The swatch, read back exactly, or nothing below is trusted.
        let swatch = Self.pixel(rep, Int(18 * scale), Int(18 * scale))
        #expect(swatch.0 > 0.99 && swatch.1 < 0.01 && swatch.2 < 0.01, "the known swatch reads \(swatch)")
        // The caution pill's band: below the swatch, one mini pill tall at 1.6×.
        let rows = Int(32 * scale)..<Int(56 * scale)
        var extreme: (l: CGFloat, c: (CGFloat, CGFloat, CGFloat)) = (dark ? 0 : 1, (0, 0, 0))
        var washChroma: CGFloat = 0
        for y in rows { for x in 0..<rep.pixelsWide {
            let c = Self.pixel(rep, x, y)
            let l = AccentLabel.relativeLuminance(red: c.0, green: c.1, blue: c.2)
            if dark ? l > extreme.l : l < extreme.l { extreme = (l, c) }
            washChroma = max(washChroma, max(c.0, c.1, c.2) - min(c.0, c.1, c.2))
        } }
        let chroma = max(extreme.c.0, extreme.c.1, extreme.c.2) - min(extreme.c.0, extreme.c.1, extreme.c.2)
        print("[DS1] \(dark ? "dark" : "light") caution words: L \(extreme.l) chroma \(chroma) · wash chroma \(washChroma)")
        if dark {
            #expect(extreme.l > 0.6, "the brightest ink in the caution pill is L \(extreme.l), not white")
        } else {
            #expect(extreme.l < 0.08, "the darkest ink in the caution pill is L \(extreme.l), not black")
        }
        #expect(chroma < 0.12, "the caution pill's words are tinted: \(extreme.c)")
        #expect(washChroma > 0.06, "the caution pill's wash carries no colour")
    }
}
