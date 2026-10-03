import AppKit
import SwiftUI
import Testing
@testable import Design

/// The one offscreen harness for the selection-lens and chrome-glass suites in this target: a view
/// in a borderless sRGB window, held for the rig's lifetime, read back as raw bytes.
///
/// **Why one.** Each suite had grown its own render-and-box helper — about a dozen across the four
/// test targets — and they drifted: some read `colorAt` (about 250 ms a frame, slow enough that a
/// sampled animation showed three frames), some dropped the window after layout so `.sRGB` and
/// `.aqua` stopped applying, some forgot the colour space. Mirrored per test target, as
/// `LayoutPumpWait` is, because the packages share no test-support module.
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
        Pixel.check(rep)
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

    /// Whether `rep` is laid out the way every reader here reads it: 8-bit integer samples, colour
    /// first. **Says so as a test failure when it is not** — every reader would otherwise answer
    /// "nothing matched", and each "draws nothing" test in these suites would pass on a capture it
    /// never read.
    @discardableResult
    static func check(_ rep: NSBitmapImageRep, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        let readable = rep.bitmapData != nil && rep.samplesPerPixel >= 3 && rep.bitsPerSample == 8
            && !rep.bitmapFormat.contains(.alphaFirst) && !rep.bitmapFormat.contains(.floatingPointSamples)
        if !readable {
            Issue.record("a capture these readers cannot read: \(rep.bitsPerSample)-bit, \(rep.samplesPerPixel) samples, format \(rep.bitmapFormat.rawValue)",
                         sourceLocation: sourceLocation)
        }
        return readable
    }

    static func box(_ rep: NSBitmapImageRep, width: CGFloat, rows: ClosedRange<CGFloat>? = nil,
                    _ match: Match) -> CGRect? {
        guard check(rep), let data = rep.bitmapData else { return nil }
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
        guard check(rep), let data = rep.bitmapData else { return 0 }
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
        guard check(rep), let data = rep.bitmapData else { return 0 }
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

    /// The colour at `point` (in points), as bytes — black for a capture `check` rejects, so a
    /// reader of it fails rather than traps.
    static func at(_ rep: NSBitmapImageRep, width: CGFloat, _ point: CGPoint) -> (UInt8, UInt8, UInt8) {
        guard check(rep), let d = rep.bitmapData else { return (0, 0, 0) }
        let scale = CGFloat(rep.pixelsWide) / width
        let x = min(rep.pixelsWide - 1, max(0, Int(point.x * scale)))
        let y = min(rep.pixelsHigh - 1, max(0, Int(point.y * scale)))
        let p = y * rep.bytesPerRow + x * rep.samplesPerPixel
        return (d[p], d[p + 1], d[p + 2])
    }

    /// One box per run of ROWS holding `match` — a column of separate markers, read apart.
    static func rowRuns(_ rep: NSBitmapImageRep, width: CGFloat, _ match: Match) -> [CGRect] {
        guard check(rep), let data = rep.bitmapData else { return [] }
        let scale = CGFloat(rep.pixelsWide) / width
        func hit(_ y: Int) -> Bool {
            (0..<rep.pixelsWide).contains { x in
                let p = y * rep.bytesPerRow + x * rep.samplesPerPixel
                return match(data[p], data[p + 1], data[p + 2])
            }
        }
        var boxes: [CGRect] = []
        var top: Int?
        for y in 0...rep.pixelsHigh {
            let inRun = y < rep.pixelsHigh && hit(y)
            if inRun, top == nil { top = y }
            if !inRun, let t = top {
                if let b = box(rep, width: width, rows: CGFloat(t) / scale...CGFloat(y - 1) / scale, match) {
                    boxes.append(b)
                }
                top = nil
            }
        }
        return boxes
    }

    /// One box per run of COLUMNS holding `match`, within `rows` — controls side by side, read apart.
    static func columnRuns(_ rep: NSBitmapImageRep, width: CGFloat, rows: ClosedRange<CGFloat>? = nil,
                           _ match: Match) -> [CGRect] {
        guard check(rep), let data = rep.bitmapData else { return [] }
        let scale = CGFloat(rep.pixelsWide) / width
        let ys = rows.map { max(0, Int($0.lowerBound * scale))..<min(rep.pixelsHigh, Int($0.upperBound * scale) + 1) }
            ?? 0..<rep.pixelsHigh
        var runs: [CGRect] = []
        var run: (minX: Int, maxX: Int, minY: Int, maxY: Int)?
        for x in 0...rep.pixelsWide {
            var lo = Int.max, hi = -1
            if x < rep.pixelsWide {
                for y in ys {
                    let p = y * rep.bytesPerRow + x * rep.samplesPerPixel
                    if match(data[p], data[p + 1], data[p + 2]) { lo = min(lo, y); hi = max(hi, y) }
                }
            }
            if hi >= 0 {
                run = run.map { ($0.minX, x, min($0.minY, lo), max($0.maxY, hi)) } ?? (x, x, lo, hi)
            } else if let r = run {
                runs.append(CGRect(x: CGFloat(r.minX) / scale, y: CGFloat(r.minY) / scale,
                                   width: CGFloat(r.maxX - r.minX + 1) / scale,
                                   height: CGFloat(r.maxY - r.minY + 1) / scale))
                run = nil
            }
        }
        return runs
    }

    /// Whether two boxes agree to within a pixel-and-a-bit on every edge.
    static func same(_ a: CGRect?, _ b: CGRect?, tolerance: CGFloat = 1.01) -> Bool {
        guard let a, let b else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }
}
