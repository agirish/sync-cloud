import Testing
import Foundation
import AppKit
import SwiftUI
import Design
@testable import FileExplorer

/// The medium classification behind the shared row glyph. The rule that could rot: an unknown
/// or extensionless file must stay `.generic` (quiet, untinted) — the vocabulary makes distinct
/// mediums findable, it must not invent a colorful category for arbitrary data.
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
        // The cache must be an invisible optimization: for every kind the vocabulary
        // distinguishes (and the generic fallbacks), cached and direct classification agree.
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
        // The findability claim: each named medium must be tinted, or shape alone carries it.
        // Swept over `Kind.allCases` rather than a list written here: the list was a copy of the
        // table it checks, so a ninth medium added untinted would have left both stale together.
        for kind in FileTypeGlyph.Kind.allCases where kind != .folder && kind != .generic {
            #expect(FileTypeGlyph.tint(for: kind) != nil, "\(kind) lost its tint")
        }
        #expect(FileTypeGlyph.Kind.allCases.count == 10,
                "the vocabulary changed size — the sweeps here name their own exemptions")
    }
}

/// The two claims the identity vocabulary makes that nothing else measures: **a shape says which
/// medium this is**, and **the ink is legible on the card it is drawn on**.
///
/// Both were open. `.pdf` and `.wordProcessing` drew the same `doc.text.fill`, so the pair these
/// lists interleave most was separated by hue alone — against the type's own "shape carries the
/// medium" premise. And the eight tints are fixed sRGB values minted outside `Design`, several of
/// them dark, drawn at 13–17pt on a card whose dark fill is darker still: the exact shape that
/// produced `ChromeInk`, and never measured.
@MainActor
@Suite struct FileTypeGlyphContrastTests {

    /// The card these glyphs are drawn on: `controlBackgroundColor`, which `lensCard` fills with,
    /// and `groundedGlassCard` too in light and at Solid. In dark at Frosted and Clear a floating
    /// panel's ground is the window's tinted one instead, held to this card's contrast below.
    private static func cardFill(_ appearance: NSAppearance.Name) -> NSColor {
        var resolved = NSColor.controlBackgroundColor
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlBackgroundColor.usingColorSpace(.sRGB)
                ?? NSColor.controlBackgroundColor
        }
        return resolved
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let s = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(s.redComponent)
            + 0.7152 * linear(s.greenComponent)
            + 0.0722 * linear(s.blueComponent)
    }

    static func contrast(_ ink: NSColor, on surface: NSColor) -> CGFloat {
        let a = luminance(ink), b = luminance(surface)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// **Every identity tint clears 3:1 against the card fill, in BOTH appearances.**
    ///
    /// 3:1 is the floor for a graphical object that carries meaning — which is what these are: the
    /// glyph is the only thing on the row saying "this is a video". The dark half is the one that
    /// was never checked, and it is where the margins are thinnest (`video` 3.16, `wordProcessing`
    /// 3.21); light's floor is `presentation` at 3.10.
    ///
    /// Recomputed from the live system colours rather than compared to the numbers in
    /// `FileTypeGlyph`'s own comment, so the table there cannot quietly become fiction.
    @Test func everyIdentityTintIsLegibleOnTheCardInBothAppearances() throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let fill = Self.cardFill(appearance)
            // **Guard the harness before trusting a sweep over it.** If `performAsCurrentDrawingAppearance`
            // stopped resolving — or a future macOS moved the card fill — every ratio below would be
            // measured against the wrong surface and this suite would pass or fail for a reason that
            // has nothing to do with the tints.
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

    /// **The tinted dark ground costs no glyph any contrast** (HZ). In dark at Frosted the Go To
    /// results draw these glyphs on `glassPanelGround`, the window's own dark ground in the accent,
    /// where they used to sit on the charcoal. Over the window's background, on every accent at
    /// Tint 0 and his 12%, the worst glyph on the new ground must read at least as well as the worst
    /// did on the charcoal. The full diagonal and glow took it from 2.63:1 to about 2.3.
    ///
    /// Relative, not 3:1: offscreen there is no material, so the window background behind the
    /// panel renders brighter than it is, and the charcoal itself measures under 3:1 here. Frosted
    /// only: at Clear the desktop behind decides, and nothing offscreen can render it.
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

    /// **No two mediums share a shape.** A vocabulary whose premise is that the symbol names the
    /// medium cannot have two mediums answering the same symbol — the tint is then the only
    /// difference, which is the thing the type says it is not relying on.
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

    /// And each of those shapes is a symbol this renderer actually has — a typo'd name draws
    /// nothing at all, which no geometry or count on the row can see.
    @Test func everyShapeIsARealSymbol() {
        for kind in FileTypeGlyph.Kind.allCases {
            let name = FileTypeGlyph.symbol(for: kind)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "\(kind) draws “\(name)”, which this renderer does not have")
        }
    }
}
