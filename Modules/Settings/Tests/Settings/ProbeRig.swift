import AppKit
import SwiftUI
import Design

/// The one offscreen harness for the selection-lens and chrome-glass suites in this target: a view
/// in a borderless sRGB window, held for the rig's lifetime, read back as raw bytes.
///
/// **Why one.** Each suite had grown its own render-and-box helper — about a dozen across the four
/// test targets — and they drifted: some read `colorAt` (about 250 ms a frame, slow enough that a
/// sampled animation showed three frames), some dropped the window after layout so `.sRGB` and
/// `.aqua` stopped applying, some forgot the colour space. Mirrored per test target, as
/// `LayoutPumpWait` is, because the packages share no test-support module — the first copy is
/// `Modules/Design/Tests/DesignTests/ProbeRig.swift`; keep them in step.
@MainActor
final class ProbeRig<Root: View> {
    let host: NSHostingView<Root>
    let window: NSWindow
    let size: CGSize

    init(_ root: Root, size: CGSize) {
        self.size = size
        host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    func capture() -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The bounding box, in points, of the pixels matching `match` — in the rows `rows` spans when
    /// given, so the same colour elsewhere cannot widen it.
    func box(rows: ClosedRange<CGFloat>? = nil, _ match: Pixel.Match) -> CGRect? {
        Pixel.box(capture(), width: size.width, rows: rows, match)
    }

    func count(rows: ClosedRange<CGFloat>? = nil, _ match: Pixel.Match) -> Int {
        Pixel.count(capture(), width: size.width, rows: rows, match)
    }
}

/// Reading a capture by colour, from the raw bytes.
enum Pixel {
    typealias Match = @Sendable (_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool

    /// The lens probe, `(1, 0, 1)`. The raw bytes are exact sRGB — measured `255, 0, 255` — and the
    /// `(1, 0.25, 1)` older comments quote was `colorAt(…).usingColorSpace(.sRGB)` shifting them on
    /// the way out. Loose on purpose: anti-aliased edges, and the films a test is checking for.
    static let lensProbe: Match = { r, g, b in r > 229 && g < 115 && b > 229 }
    /// Chrome glass's probe, `(0, 1, 1)` — raw `0, 255, 255`.
    static let chromeProbe: Match = { r, g, b in r < 115 && g > 229 && b > 229 }

    /// Within `tolerance` (0...255) of `color` on every channel.
    static func near(_ color: Color, within tolerance: Int = 31) -> Match {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let want = (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        return { r, g, b in
            abs(Int(r) - want.0) <= tolerance && abs(Int(g) - want.1) <= tolerance && abs(Int(b) - want.2) <= tolerance
        }
    }

    static func box(_ rep: NSBitmapImageRep, width: CGFloat, rows: ClosedRange<CGFloat>? = nil,
                    _ match: Match) -> CGRect? {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3, rep.bitsPerSample == 8 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / width
        let ys = rows.map { max(0, Int($0.lowerBound * scale))..<min(rep.pixelsHigh, Int($0.upperBound * scale) + 1) }
            ?? 0..<rep.pixelsHigh
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in ys {
            for x in 0..<rep.pixelsWide {
                let p = y * rep.bytesPerRow + x * rep.samplesPerPixel
                guard match(data[p], data[p + 1], data[p + 2]) else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    static func count(_ rep: NSBitmapImageRep, width: CGFloat, rows: ClosedRange<CGFloat>? = nil,
                      _ match: Match) -> Int {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3, rep.bitsPerSample == 8 else { return 0 }
        let scale = CGFloat(rep.pixelsWide) / width
        let ys = rows.map { max(0, Int($0.lowerBound * scale))..<min(rep.pixelsHigh, Int($0.upperBound * scale) + 1) }
            ?? 0..<rep.pixelsHigh
        var n = 0
        for y in ys {
            for x in 0..<rep.pixelsWide {
                let p = y * rep.bytesPerRow + x * rep.samplesPerPixel
                if match(data[p], data[p + 1], data[p + 2]) { n += 1 }
            }
        }
        return n
    }

    /// How many pixels inside `rect` (in points) match — a marker's own box, read apart from the
    /// same colour anywhere else in the render.
    static func count(_ rep: NSBitmapImageRep, width: CGFloat, in rect: CGRect, _ match: Match) -> Int {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3, rep.bitsPerSample == 8 else { return 0 }
        let scale = CGFloat(rep.pixelsWide) / width
        let xs = max(0, Int(rect.minX * scale))..<min(rep.pixelsWide, Int(rect.maxX * scale))
        let ys = max(0, Int(rect.minY * scale))..<min(rep.pixelsHigh, Int(rect.maxY * scale))
        var n = 0
        for y in ys {
            for x in xs {
                let p = y * rep.bytesPerRow + x * rep.samplesPerPixel
                if match(data[p], data[p + 1], data[p + 2]) { n += 1 }
            }
        }
        return n
    }

    /// Near-white and near-black ink — a label's two inks, on a fill and on glass.
    static let whiteInk: Match = { r, g, b in r > 240 && g > 240 && b > 240 }
    static let blackInk: Match = { r, g, b in r < 70 && g < 70 && b < 70 }

    /// The colour at `point` (in points), as bytes.
    static func at(_ rep: NSBitmapImageRep, width: CGFloat, _ point: CGPoint) -> (UInt8, UInt8, UInt8) {
        let scale = CGFloat(rep.pixelsWide) / width
        let p = Int(point.y * scale) * rep.bytesPerRow + Int(point.x * scale) * rep.samplesPerPixel
        let d = rep.bitmapData!
        return (d[p], d[p + 1], d[p + 2])
    }

    /// Whether two boxes agree to within a pixel-and-a-bit on every edge.
    static func same(_ a: CGRect?, _ b: CGRect?, tolerance: CGFloat = 1.01) -> Bool {
        guard let a, let b else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}
