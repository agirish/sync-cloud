import Testing
import AppKit
import PDFKit
import SwiftUI
import Design
import Sync
@testable import FileExplorer

/// **A PDF tool sheet's other buttons draw their words at 4.5:1, in light and dark.**
///
/// The tool sheets wore `.accentedProminent()` on their root, for the default button's fill. A
/// `.tint` reaches every `.bordered` button under it, and one with no tint of its own draws the
/// tint as its WORDS: Clean Metadata's Keep Current Values and Clear All, and a failure's Download,
/// were the deepened Green on their bezels. The tint now sits on the default button alone
/// (`AccentFillScanTests`, rule 7, holds the source).
///
/// Rendered for real and read back: the Clean Metadata sheet as `PanePDFTools` presents it, at
/// Green, and the button row under its form — found as the first rows below the last field that
/// differ from the sheet's ground — measured for its darkest (light) or brightest (dark) pixel
/// against the bezel's own colour. The same sheet under the old root tint is the control.
/// Measured 2026-10-26: Keep Current Values' words 13.0:1 light and 9.9:1 dark; under the old
/// tint 4.3:1 and 3.5:1, on this row's small bezels (`ChromeInk.buttonWords` cites 3.8:1 and
/// 2.9:1 for a regular-size one).
/// `.machinePinned(.pixelSampling)`, like every suite here that samples a live renderer.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) final class EditorPDFSheetButtonWordsTests {

    static let textFloor: CGFloat = 4.5
    static let size = CGSize(width: 420, height: 460)

    let folder = NSTemporaryDirectory() + "editor-pdf-button-words-" + UUID().uuidString
    let suiteName = "EditorPDFSheetButtonWordsTests-" + UUID().uuidString
    let defaults: UserDefaults

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(LiquidGlassHue.green.rawValue, forKey: LiquidGlass.hueKey)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: folder)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// A PDF with a title and an author, so Keep Current Values is enabled.
    private func fixture() throws -> EditorPDFTools {
        let file = (folder as NSString).appendingPathComponent("Word-\(UUID().uuidString).pdf")
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Quarterly", kCGPDFContextAuthor: "A. Person"]
        let context = try #require(CGContext(URL(fileURLWithPath: file) as CFURL, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let tools = EditorPDFTools()
        tools.attach(path: file, pageCount: 1, encryption: .none)
        return tools
    }

    private static func subviews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + subviews(type, in: $0) }
    }

    static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        var p = [Int](repeating: 0, count: 4)
        rep.getPixel(&p, atX: x, y: y)
        return NSColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    }

    static func lum(_ c: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
    }

    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (x, y) = (lum(a) + 0.05, lum(b) + 0.05)
        return max(x, y) / min(x, y)
    }

    /// The sheet, hosted in a window that is never ordered in, rendered once its form has loaded;
    /// with the y, in points from the top, of the last field's lower edge.
    private func render(rootTint: Color?, dark: Bool) async throws -> (NSBitmapImageRep, fieldsEnd: CGFloat) {
        let tools = try fixture()
        let sheet = EditorPDFToolSheetView(tools: tools, sheet: .metadata)
            .presentedNativeControlAccent()
            .tint(rootTint)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, dark ? .dark : .light)
            .defaultAppStorage(defaults)
        let host = NSHostingView(rootView: sheet)
        host.frame = CGRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        var fields: [NSTextField] = []
        for _ in 0..<1000 {
            host.layoutSubtreeIfNeeded()
            fields = Self.subviews(NSTextField.self, in: host).filter(\.isEditable)
            if fields.count == 5 { break }
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(fields.count == 5, "the metadata form never loaded: \(fields.count) fields")
        try? await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let fieldsEnd = fields.map { field -> CGFloat in
            let r = field.convert(field.bounds, to: host)
            return host.isFlipped ? r.maxY : host.bounds.height - r.minY
        }.max() ?? 0
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, fieldsEnd)
    }

    /// The button row's words against its bezel: the rows from the first one below the fields that
    /// differs from the sheet's ground to the next that does not; the bezel is the row's commonest
    /// colour that is not the ground, and the words its extreme pixel on the far side of it.
    static func wordsRatio(_ rep: NSBitmapImageRep, below fieldsEnd: CGFloat, dark: Bool) throws -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / size.width
        let ground = pixel(rep, 2, Int((fieldsEnd + 2) * scale))
        // By channel, and finely: a tinted bezel in dark is a few levels off the sheet, and in
        // luminance the dark bezel and the sheet are 0.01 apart. The sheet's own ground is flat.
        func differs(_ c: NSColor) -> Bool {
            max(abs(c.redComponent - ground.redComponent), abs(c.greenComponent - ground.greenComponent),
                abs(c.blueComponent - ground.blueComponent)) > 1.5 / 255
        }
        func marked(_ y: Int) -> Bool { (0..<rep.pixelsWide).filter { differs(pixel(rep, $0, y)) }.count >= 20 }
        var y = Int((fieldsEnd + 2) * scale)
        while y < rep.pixelsHigh, !marked(y) { y += 1 }
        let top = y
        while y < rep.pixelsHigh, marked(y) { y += 1 }
        let rows = top..<y
        try #require(rows.count >= Int(12 * scale), "no button row below the fields: rows \(rows)")

        var counts: [Int: Int] = [:]
        var colours: [Int: NSColor] = [:]
        for y in rows { for x in 0..<rep.pixelsWide {
            let c = pixel(rep, x, y)
            guard differs(c) else { continue }
            let key = Int(c.redComponent * 255) << 16 | Int(c.greenComponent * 255) << 8 | Int(c.blueComponent * 255)
            counts[key, default: 0] += 1
            colours[key] = c
        } }
        let bezel = try #require(counts.max { $0.value < $1.value }.flatMap { colours[$0.key] }, "no bezel in the row")
        var best: CGFloat = 1
        for y in rows { for x in 0..<rep.pixelsWide {
            let c = pixel(rep, x, y)
            guard dark ? lum(c) > lum(bezel) : lum(c) < lum(bezel) else { continue }
            best = max(best, ratio(c, bezel))
        } }
        return best
    }

    /// **Keep Current Values' words read at the floor**, and under the old root tint the same
    /// probe reads them below it — so it can see the case it guards.
    @Test(arguments: [false, true]) func theMetadataSheetsOtherButtonsReadAtTheFloor(dark: Bool) async throws {
        let (rep, fieldsEnd) = try await render(rootTint: nil, dark: dark)
        let r = try Self.wordsRatio(rep, below: fieldsEnd, dark: dark)
        #expect(r >= Self.textFloor, "Keep Current Values' words in \(dark ? "dark" : "light") paint at \(r):1 on the bezel")

        let (old, oldEnd) = try await render(rootTint: LiquidGlassHue.green.accentFillColor, dark: dark)
        let o = try Self.wordsRatio(old, below: oldEnd, dark: dark)
        #expect(o < Self.textFloor, "under the old root tint the words read at \(o):1 — the probe proves nothing")
    }
}
