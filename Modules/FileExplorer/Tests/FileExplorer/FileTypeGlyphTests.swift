import Testing
import Foundation
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// The medium classification behind the shared row glyph. The rule that could rot: an unknown or
/// extensionless file must stay `.generic` (quiet, untinted). The vocabulary makes distinct mediums
/// findable; it must not invent a colourful category for arbitrary data.
@Suite struct FileTypeGlyphTests {

    @Test func theCommonMediumsClassify() {
        #expect(FileTypeGlyph.classify(ext: "pdf", isDirectory: false) == .pdf)
        #expect(FileTypeGlyph.classify(ext: "JPG", isDirectory: false) == .image)
        #expect(FileTypeGlyph.classify(ext: "heic", isDirectory: false) == .image)
        #expect(FileTypeGlyph.classify(ext: "mp3", isDirectory: false) == .audio)
        #expect(FileTypeGlyph.classify(ext: "m4a", isDirectory: false) == .audio)
        #expect(FileTypeGlyph.classify(ext: "mp4", isDirectory: false) == .video)
        #expect(FileTypeGlyph.classify(ext: "mov", isDirectory: false) == .video)
        #expect(FileTypeGlyph.classify(ext: "docx", isDirectory: false) == .wordProcessing)
        #expect(FileTypeGlyph.classify(ext: "pages", isDirectory: false) == .wordProcessing)
        #expect(FileTypeGlyph.classify(ext: "xlsx", isDirectory: false) == .spreadsheet)
        #expect(FileTypeGlyph.classify(ext: "csv", isDirectory: false) == .spreadsheet)
        #expect(FileTypeGlyph.classify(ext: "pptx", isDirectory: false) == .presentation)
        #expect(FileTypeGlyph.classify(ext: "zip", isDirectory: false) == .archive)
    }

    @Test func unknownAndExtensionlessStayGeneric() {
        #expect(FileTypeGlyph.classify(ext: "", isDirectory: false) == .generic)
        #expect(FileTypeGlyph.classify(ext: "xyzzy123", isDirectory: false) == .generic)
        #expect(FileTypeGlyph.tint(for: .generic) == nil)
    }

    @Test @MainActor func theCacheAnswersExactlyAsTheLookupDoes() {
        // The cache is invisible: cached and direct classification agree for every kind.
        for (name, isDir) in [("a.pdf", false), ("b.JPG", false), ("c.mp3", false),
                              ("d.docx", false), ("e.xyzzy", false), ("f", false),
                              ("Reports.pdf", true)] {
            let direct = FileTypeGlyph.classify(ext: (name as NSString).pathExtension,
                                                isDirectory: isDir)
            #expect(FileTypeGlyph.cachedKind(name: name, isDirectory: isDir) == direct,
                    "cache disagrees with classify for \(name)")
            // And again, now that it is warm.
            #expect(FileTypeGlyph.cachedKind(name: name, isDirectory: isDir) == direct)
        }
    }

    @Test func directoriesAreFoldersWhateverTheirName() {
        #expect(FileTypeGlyph.classify(ext: "pdf", isDirectory: true) == .folder)
        #expect(FileTypeGlyph.tint(for: .folder) == nil)
    }

    @Test func everyDistinctMediumCarriesATint() {
        // Swept over `Kind.allCases` rather than a list written here, so a new medium added
        // untinted is caught.
        for kind in FileTypeGlyph.Kind.allCases where kind != .folder && kind != .generic {
            #expect(FileTypeGlyph.tint(for: kind) != nil, "\(kind) lost its tint")
        }
        #expect(FileTypeGlyph.Kind.allCases.count == 10,
                "the vocabulary changed size — the sweeps here name their own exemptions")
    }
}

/// The identity vocabulary's two claims: a shape alone says which medium this is, and the ink is
/// legible on the card it is drawn on. The tints are fixed sRGB values minted outside `Design`,
/// several of them dark, so their contrast is measured here.
@MainActor
@Suite struct FileTypeGlyphContrastTests {

    /// The card these glyphs are drawn on: `controlBackgroundColor` (`lensCard`, and
    /// `groundedGlassCard` in light and at Solid). In dark at Frosted and Clear a floating panel's
    /// ground is the window's tinted one instead, held to this card's contrast below.
    private static func cardFill(_ appearance: NSAppearance.Name) -> NSColor {
        var resolved = NSColor.controlBackgroundColor
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlBackgroundColor.usingColorSpace(.sRGB)
                ?? NSColor.controlBackgroundColor
        }
        return resolved
    }

    /// `Contrast`'s readings of `color`, converted to sRGB first.
    private static func luminance(_ color: NSColor) -> CGFloat {
        color.usingColorSpace(.sRGB).map(Contrast.luminance) ?? 0
    }

    static func contrast(_ ink: NSColor, on surface: NSColor) -> CGFloat {
        Contrast.ratio(ink.usingColorSpace(.sRGB) ?? ink, surface.usingColorSpace(.sRGB) ?? surface)
    }

    /// Every identity tint clears 3:1 against the card fill, in both appearances: the floor for a
    /// graphical object that carries meaning. Recomputed from the live system colours rather than
    /// compared to the numbers in `FileTypeGlyph`'s own comment.
    @Test func everyIdentityTintIsLegibleOnTheCardInBothAppearances() throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let fill = Self.cardFill(appearance)
            // Guard the harness: if `performAsCurrentDrawingAppearance` stopped resolving, every
            // ratio below would be measured against the wrong surface.
            let fillLuminance = Self.luminance(fill)
            if appearance == .darkAqua {
                #expect(fillLuminance < 0.05,
                        "the dark card fill resolved to L=\(fillLuminance) — not a dark surface")
            } else {
                #expect(fillLuminance > 0.5,
                        "the light card fill resolved to L=\(fillLuminance) — not a light surface")
            }
            var measured = 0
            for kind in FileTypeGlyph.Kind.allCases {
                guard let tint = FileTypeGlyph.tint(for: kind) else { continue }
                measured += 1
                let ratio = Self.contrast(NSColor(tint), on: fill)
                #expect(ratio >= 3.0,
                        "\(kind)'s tint is \(String(format: "%.2f", ratio)):1 on the \(appearance.rawValue) card — under the 3:1 a meaning-carrying glyph needs")
            }
            #expect(measured == 8, "measured \(measured) tints, not the eight this vocabulary mints")
        }
    }

    /// The tinted dark ground costs no glyph any contrast: in dark at Frosted the Go To results draw
    /// on `glassPanelGround` rather than the charcoal, and on every accent at Tint 0 and 12% the
    /// worst glyph there must read at least as well as the worst on the charcoal.
    ///
    /// Relative, not 3:1: offscreen there is no material, so the window background behind the panel
    /// renders brighter than it is, and the charcoal itself measures under 3:1 here. Frosted only:
    /// at Clear the desktop behind decides, and nothing offscreen can render it.
    @Test(.machinePinned(.pixelSampling)) func theDarkPanelGroundLowersNoGlyphsContrast() throws {
        for tint in [0.0, 0.12] {
            // `.solid` is the charcoal: `glassPanelGround` keeps `controlBackgroundColor` there.
            let charcoal = try Self.worstGlyphContrast(groundLevel: .solid, tint: tint)
            let tinted = try Self.worstGlyphContrast(groundLevel: .frosted, tint: tint)
            #expect(charcoal > 1.5 && charcoal < 5, "the charcoal measured \(charcoal):1 — the harness is off")
            #expect(tinted >= charcoal,
                    "at Tint \(tint) the worst glyph is \(String(format: "%.2f", tinted)):1 on the tinted ground, \(String(format: "%.2f", charcoal)):1 on the charcoal")
        }
    }

    /// The same promise in arithmetic, so it runs on CI too, where the machine-pinned pixel test
    /// above skips. The ground's brightest point (the deep base's top stop under the diagonal's
    /// first stop) is composited by hand. Mutation: `panelGroundAccentScale` = 1 must fail it.
    @Test func thePanelGroundsAccentShareKeepsEveryGlyphAsLegibleAsTheCharcoal() throws {
        let charcoal = Self.cardFill(.darkAqua)
        #expect(Self.luminance(charcoal) < 0.05, "premise: the charcoal resolved to a dark surface")
        let glyphs = Self.darkGlyphTints()
        #expect(glyphs.count == 8, "measured \(glyphs.count) tints, not the eight this vocabulary mints")
        let charcoalWorst = glyphs.map { Self.contrast($0, on: charcoal) }.min() ?? 0

        let base = LiquidGlass.darkBaseTop
        let share = LiquidGlass.accentDiagonalOpacities(dark: true, accentT: GlassLevel.frosted.backgroundIntensity)[0]
        for tint in [0.0, 0.12] {
            let alpha = share * LiquidGlass.backgroundHueStrength(forTint: tint) * LiquidGlass.panelGroundAccentScale
            for hue in LiquidGlassHue.allCases where hue != .none {
                let stop = try #require(NSColor(hue.gradientColors[0]).usingColorSpace(.sRGB))
                func over(_ ink: CGFloat, _ ground: Double) -> CGFloat { CGFloat(ground) + (ink - CGFloat(ground)) * CGFloat(alpha) }
                let ground = NSColor(srgbRed: over(stop.redComponent, base.red), green: over(stop.greenComponent, base.green),
                                     blue: over(stop.blueComponent, base.blue), alpha: 1)
                let worst = glyphs.map { Self.contrast($0, on: ground) }.min() ?? 0
                #expect(worst >= charcoalWorst,
                        "\(hue) at Tint \(tint): the worst glyph is \(String(format: "%.2f", worst)):1 on the panel's ground, \(String(format: "%.2f", charcoalWorst)):1 on the charcoal")
            }
        }
    }

    /// Every identity tint, resolved in dark.
    private static func darkGlyphTints() -> [NSColor] {
        var tints: [NSColor] = []
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            tints = FileTypeGlyph.Kind.allCases.compactMap { kind in
                FileTypeGlyph.tint(for: kind).flatMap { NSColor($0).usingColorSpace(.sRGB) }
            }
        }
        return tints
    }

    /// The lowest contrast any identity tint has against the brightest point of a dark Frosted
    /// panel's ground, across every accent, over the window background it floats on.
    private static func worstGlyphContrast(groundLevel: GlassLevel, tint: Double) throws -> CGFloat {
        var worst = CGFloat.infinity
        for hue in LiquidGlassHue.allCases {
            let size = CGSize(width: 372, height: 600)
            let host = NSHostingView(rootView: Color.clear
                .glassPanelGround(level: groundLevel, hue: hue, tint: tint,
                                  opacity: GlassLevel.frosted.groundedBackingOpacity, cornerRadius: 0)
                .frame(width: size.width, height: size.height)
                .background(Color.clear.liquidGlassAppBackground(level: .frosted, hue: hue, tint: tint)))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.colorSpace = .sRGB
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            var brightest = NSColor.black
            for x in stride(from: 4, to: rep.pixelsWide - 4, by: 16) {
                for y in stride(from: 4, to: rep.pixelsHigh - 4, by: 16) {
                    let c = try #require(rep.colorAt(x: x, y: y))
                    if luminance(c) > luminance(brightest) { brightest = c }
                }
            }
            for kind in FileTypeGlyph.Kind.allCases {
                guard let ink = FileTypeGlyph.tint(for: kind) else { continue }
                worst = min(worst, contrast(NSColor(ink), on: brightest))
            }
        }
        return worst
    }

    /// No two mediums share a shape, which would leave the tint as the only difference.
    @Test func everyMediumDrawsItsOwnShape() {
        var byGlyph: [String: [FileTypeGlyph.Kind]] = [:]
        for kind in FileTypeGlyph.Kind.allCases {
            byGlyph[FileTypeGlyph.symbol(for: kind), default: []].append(kind)
        }
        let shared = byGlyph.filter { $0.value.count > 1 }
            .map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
        #expect(byGlyph.count == FileTypeGlyph.Kind.allCases.count,
                "two mediums share a glyph: \(shared)")
    }

    /// Each shape is a symbol this renderer has: a mistyped name draws nothing, which no geometry
    /// or count on the row can see.
    @Test func everyShapeIsARealSymbol() {
        for kind in FileTypeGlyph.Kind.allCases {
            let name = FileTypeGlyph.symbol(for: kind)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "\(kind) draws “\(name)”, which this renderer does not have")
        }
    }
}
