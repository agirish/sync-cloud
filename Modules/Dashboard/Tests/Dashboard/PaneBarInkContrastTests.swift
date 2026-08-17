import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// Whether a rung that supplies its own `ink:` is still legible in BOTH appearances.
///
/// `PaneNavChrome` normally routes its glyph through `ChromeInk.label`, which flattens to
/// full-strength white in dark — deliberately, because "an accent glyph on an accent wash has
/// nothing to shift against". A supplied `ink` bypasses that on purpose (a destructive control that
/// stopped being red in dark would lose its one distinguishing cue), so the bypass has to be
/// measured rather than assumed: the same decision that keeps the red also opts out of the rule
/// that was protecting contrast.
///
/// Measured against the pill's own fill, which is what the glyph actually sits on.
/// `.machinePinned(.pixelSampling)` — and this is the suite in the package that most needs it.
/// It does not merely read pixels back out of a live renderer: it computes a WCAG contrast ratio
/// from the darkest sampled glyph pixel against the modal sampled fill and holds it to absolute
/// numbers (3.0, and 4.0 for the control). Anti-aliasing decides how dark that darkest pixel gets,
/// so a different renderer moves the measurement itself — the doc above records 4.84:1 and 2.87:1
/// from this Mac, and the margin over the floor is what those numbers are.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneBarInkContrastTests {

    /// The floor for a non-text glyph carrying meaning. 3:1 is WCAG's non-text contrast minimum and
    /// the number the rest of this codebase's chrome is held to.
    static let floor = 3.0

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func testTheDeleteGlyphClearsTheContrastFloorInBothAppearances(appearance: NSAppearance.Name) throws {
        let measured = try Self.glyphContrast(appearance: appearance)
        #expect(measured >= Self.floor,
                "the trash glyph measures \(String(format: "%.2f", measured)):1 against its pill in \(appearance.rawValue) — below the \(Self.floor):1 a non-text control carrying meaning needs")
    }

    /// **The control on the measurement itself, and the number the tinted rung is judged against.**
    ///
    /// An absolute floor alone would be easy to argue with — anti-aliasing can starve a glyph's
    /// core and make any method pessimistic. So the same method measures an UNTINTED rung on the
    /// same surface in the same render: 4.84:1. That is comfortably above this fixture's own
    /// baseline expectation and above the app's documented ~3.4:1 on its hue-washed surface, which
    /// is expected — this fixture renders over `windowBackgroundColor` with no wash.
    ///
    /// What it establishes is that the method is not the pessimist: when the tinted rung measured
    /// 2.87:1 beside this, the gap was the tint's, not the measurement's.
    @Test func testTheMethodIsNotThePessimist() throws {
        let measured = try Self.standardGlyphContrast()
        #expect(measured > Self.floor + 1.0,
                "the untinted chrome glyph measures \(String(format: "%.2f", measured)):1 — with the control this low, a low number for the tinted rung says more about the method than the tint")
    }

    // MARK: - Measurement

    /// Contrast of an UNTINTED rung's glyph (Sort, which takes the standard chrome ink) against its
    /// pill, by the same method.
    private static func standardGlyphContrast() throws -> Double {
        let rep = try rendered(appearance: .aqua)
        // The darkest pixel in the trailing half that is NOT red — i.e. a plain chrome glyph.
        var best: (x: Int, y: Int, lum: Double)? = nil
        for x in (rep.pixelsWide / 2)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if Double(p.redComponent) - Double(max(p.greenComponent, p.blueComponent)) > 0.08 { continue }
                let l = luminance(p)
                if l < (best?.lum ?? 1.0) { best = (x, y, l) }
            }
        }
        let b = try #require(best)
        let glyph = rep.colorAt(x: b.x, y: b.y)!.usingColorSpace(.sRGB)!
        return contrast(glyph, try fill(around: b.x, b.y, in: rep))
    }

    static func fill(around cx: Int, _ cy: Int, in rep: NSBitmapImageRep) throws -> NSColor {
        var counts: [String: (Int, NSColor)] = [:]
        for x in max(0, cx - 18)...min(rep.pixelsWide - 1, cx + 18) {
            for y in max(0, cy - 18)...min(rep.pixelsHigh - 1, cy + 18) {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = String(format: "%.2f-%.2f-%.2f", Double(p.redComponent), Double(p.greenComponent), Double(p.blueComponent))
                counts[key, default: (0, p)].0 += 1
            }
        }
        return try #require(counts.values.max(by: { $0.0 < $1.0 })?.1)
    }

    /// Contrast between the darkest glyph pixel in the Delete cell and the pill fill behind it.
    ///
    /// The fill is sampled from the pill's own corner rather than assumed: it is
    /// `.primary.opacity(0.075)` over whatever the header is over, so a constant here would be a
    /// second opinion about a colour the view composes.
    private static func glyphContrast(appearance: NSAppearance.Name) throws -> Double {
        let rep = try rendered(appearance: appearance)
        // The Delete cell, located by finding the reddest column band in the trailing half.
        var best: (x: Int, y: Int, score: Double)? = nil
        for x in (rep.pixelsWide / 2)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let score = Double(p.redComponent) - Double(max(p.greenComponent, p.blueComponent))
                if score > (best?.score ?? 0.2) { best = (x, y, score) }
            }
        }
        let glyph = try #require(best.map { rep.colorAt(x: $0.x, y: $0.y)!.usingColorSpace(.sRGB)! },
                                 "no red glyph pixel found in \(appearance.rawValue) — the Delete rung is not painting its ink")
        // The pill behind it: sample just inside the cell but clear of the glyph strokes, taken as
        // the most common colour in the cell's top-left quadrant.
        let cx = best!.x, cy = best!.y
        var counts: [String: (Int, NSColor)] = [:]
        for x in max(0, cx - 18)...min(rep.pixelsWide - 1, cx + 18) {
            for y in max(0, cy - 18)...min(rep.pixelsHigh - 1, cy + 18) {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = String(format: "%.2f-%.2f-%.2f", Double(p.redComponent), Double(p.greenComponent), Double(p.blueComponent))
                counts[key, default: (0, p)].0 += 1
            }
        }
        let fill = try #require(counts.values.max(by: { $0.0 < $1.0 })?.1)
        return contrast(glyph, fill)
    }

    private static func luminance(_ c: NSColor) -> Double {
        func channel(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
             + 0.0722 * channel(c.blueComponent)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func rendered(appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let defaults = ScratchDefaults("PaneBarInkContrastTests-render")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let size = CGSize(width: 700, height: LiquidGlass.headerHeight)
        let header = PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    path: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            onDelete: {}, selectionCount: 3)
        let host = NSHostingView(rootView: AnyView(
            header
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        ))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
