import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard
import FileExplorerTestSupport

/// Whether a rung that supplies its own `ink:` stays legible in both appearances. A supplied `ink`
/// bypasses `ChromeInk.label`'s flattening to full white in dark on purpose, so a destructive
/// control stays red, and gives up that contrast rule, so it is measured here against the pill's
/// own fill. Machine-pinned: it holds a WCAG ratio from the darkest sampled glyph pixel to absolute
/// numbers, and anti-aliasing decides how dark that pixel gets, so another renderer moves it.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneBarInkContrastTests {

    /// The floor for a non-text glyph carrying meaning: WCAG's non-text minimum, which the rest of
    /// the app's chrome is held to.
    static let floor = 3.0

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func testTheDeleteGlyphClearsTheContrastFloorInBothAppearances(appearance: NSAppearance.Name) throws {
        let measured = try Self.glyphContrast(appearance: appearance)
        #expect(measured >= Self.floor,
                "the trash glyph measures \(String(format: "%.2f", measured)):1 against its pill in \(appearance.rawValue) — below the \(Self.floor):1 a non-text control carrying meaning needs")
    }

    /// The control on the measurement itself. Anti-aliasing can starve a glyph's core and make any
    /// method pessimistic, so the same method measures an untinted rung in the same render: a tinted
    /// rung failing beside a passing control is the tint's gap, not the method's.
    @Test func testTheMethodIsNotThePessimist() throws {
        let measured = try Self.standardGlyphContrast()
        #expect(measured > Self.floor + 1.0,
                "the untinted chrome glyph measures \(String(format: "%.2f", measured)):1 — with the control this low, a low number for the tinted rung says more about the method than the tint")
    }

    /// The probe reads a known colour back as itself. `colorAt` on an sRGB capture returns the sRGB
    /// numbers tagged as calibrated RGB, so converting them `.usingColorSpace(.sRGB)` shifts every
    /// reading and the WCAG ratios above with it.
    @Test func theProbeReadsAKnownColourBackUnchanged() throws {
        let size = CGSize(width: 20, height: 20)
        let host = NSHostingView(rootView: Color(.sRGB, red: 0.2, green: 0.702, blue: 0.502)
            .frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let p = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        #expect(abs(p.redComponent - 0.2) < 0.005 && abs(p.greenComponent - 0.702) < 0.005
                && abs(p.blueComponent - 0.502) < 0.005, "read back as \(p)")
    }

    // MARK: - Measurement

    /// A rendered header plus the rows its bar's controls occupy, from one layout pass. The rows are
    /// the drawn pills' `_FocusRingView` frames, not a fraction of the header: both searches pick an
    /// extreme pixel, so a window catching a rung's title, which hangs below its pill, could measure
    /// a title stroke as a glyph.
    struct RenderedHeader {
        let rep: NSBitmapImageRep
        let barRows: Range<Int>
    }

    /// Contrast of an untinted rung's glyph (one in the standard chrome ink) against its pill, by
    /// the same method.
    private static func standardGlyphContrast() throws -> Double {
        let measured = try rendered(appearance: .aqua)
        let rep = measured.rep
        // The darkest non-red pixel on the bar's row: a plain chrome glyph.
        var best: (x: Int, y: Int, lum: Double)? = nil
        for x in 0..<rep.pixelsWide {
            for y in measured.barRows {
                guard let p = rep.colorAt(x: x, y: y) else { continue }
                if Double(p.redComponent) - Double(max(p.greenComponent, p.blueComponent)) > 0.08 { continue }
                let l = luminance(p)
                if l < (best?.lum ?? 1.0) { best = (x, y, l) }
            }
        }
        let b = try #require(best)
        let glyph = rep.colorAt(x: b.x, y: b.y)!
        return contrast(glyph, try fill(around: b.x, b.y, in: rep))
    }

    static func fill(around cx: Int, _ cy: Int, in rep: NSBitmapImageRep) throws -> NSColor {
        var counts: [String: (Int, NSColor)] = [:]
        for x in max(0, cx - 18)...min(rep.pixelsWide - 1, cx + 18) {
            for y in max(0, cy - 18)...min(rep.pixelsHigh - 1, cy + 18) {
                guard let p = rep.colorAt(x: x, y: y) else { continue }
                let key = String(format: "%.2f-%.2f-%.2f", Double(p.redComponent), Double(p.greenComponent), Double(p.blueComponent))
                counts[key, default: (0, p)].0 += 1
            }
        }
        return try #require(counts.values.max(by: { $0.0 < $1.0 })?.1)
    }

    /// Contrast between the reddest glyph pixel in the Delete cell and the pill fill behind it. The
    /// fill is sampled, not assumed: it is `.primary.opacity(0.075)` over whatever the header is
    /// over, so a constant would second-guess a colour the view composes.
    private static func glyphContrast(appearance: NSAppearance.Name) throws -> Double {
        let measured = try rendered(appearance: appearance)
        let rep = measured.rep
        // The Delete cell, located by finding the reddest pixel on the bar's row.
        var best: (x: Int, y: Int, score: Double)? = nil
        for x in 0..<rep.pixelsWide {
            for y in measured.barRows {
                guard let p = rep.colorAt(x: x, y: y) else { continue }
                let score = Double(p.redComponent) - Double(max(p.greenComponent, p.blueComponent))
                if score > (best?.score ?? 0.2) { best = (x, y, score) }
            }
        }
        let glyph = try #require(best.map { rep.colorAt(x: $0.x, y: $0.y)! },
                                 "no red glyph pixel found in \(appearance.rawValue) — the Delete rung is not painting its ink")
        // The pill behind it: the most common colour in a square around the glyph pixel, which the
        // fill outnumbers the strokes in.
        return contrast(glyph, try fill(around: best!.x, best!.y, in: rep))
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

    static func rendered(appearance: NSAppearance.Name) throws -> RenderedHeader {
        let defaults = ScratchDefaults("PaneBarInkContrastTests-render")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let size = CGSize(width: 700, height: LiquidGlass.headerHeight)
        let header = PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            onDelete: {}, selectionCount: 3)
        let rig = ProbeRig(AnyView(
            header
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        ), size: size)
        rig.window.appearance = NSAppearance(named: appearance)
        let rep = rig.capture()
        let host = rig.host

        // The bar's own band, from the drawn controls (see `RenderedHeader`). Rings are in points and the
        // bitmap in pixels, so the scale is measured off the two: a hard-coded 2 would halve the
        // window on a 1x display.
        let rings = FocusRings.frames(in: host)
        let top = try #require(rings.map(\.minY).min(), "no controls found — the ring oracle broke")
        // The bar is the topmost band of rings, above the breadcrumb's controls.
        let bar = rings.filter { $0.minY < top + 5 }
        let scale = Double(rep.pixelsHigh) / Double(host.bounds.height)
        let low = Int((bar.map(\.minY).min() ?? 0) * scale)
        let high = Int(((bar.map(\.maxY).max() ?? 0) * scale).rounded(.up))
        try #require(low < high, "the bar's band measured empty")
        return RenderedHeader(rep: rep, barRows: low..<min(high, rep.pixelsHigh))
    }
}
