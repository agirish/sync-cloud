import AppKit
import CoreGraphics
import Foundation

/// **One run of text a page's content stream draws** — a `Tj`, `TJ`, `'` or `"` — with the font it
/// names, where its baseline starts and ends, and its fill colour.
///
/// Read off the content stream rather than asked of PDFKit, whose `attributedString` names a
/// stand-in — plain Helvetica or Arial — for an embedded face it can't load: measured 2026-10-18 on
/// page 1 of his PDFs, 44 of 132.
struct EditorPDFTextRun: Equatable, Sendable {
    /// The font's `/BaseFont` without its subset tag — "ArialMT" for "ABCDEF+ArialMT".
    var fontName: String
    /// The `/FontDescriptor`'s `/Flags`: fixed pitch, serif, script, italic…
    var fontFlags: Int
    /// The point size on the page: the `Tf` size scaled by the text and graphics matrices.
    var fontSize: CGFloat
    /// The baseline at the run's first glyph and after its last, in page space.
    var start: CGPoint
    var end: CGPoint
    /// The fill colour, sRGB, or `nil` for a colour space this does not read (a pattern, a spot ink).
    var color: EditorPDFRGB?
    /// Text render mode 3: drawn invisibly, as an OCR layer over a scan is.
    var isInvisible: Bool

    static let fixedPitchFlag = 1 << 0
    static let serifFlag = 1 << 1
    static let scriptFlag = 1 << 3
}

/// A colour as three sRGB components, 0…1.
public struct EditorPDFRGB: Equatable, Hashable, Sendable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// The largest difference in any one component.
    func distance(to other: EditorPDFRGB) -> CGFloat {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
    }

    static let black = EditorPDFRGB(red: 0, green: 0, blue: 0)
    static let white = EditorPDFRGB(red: 1, green: 1, blue: 1)
}

/// **Reads a page's text runs off its content stream** with `CGPDFScanner`: the graphics state's
/// matrix (`q`, `Q`, `cm`), the text state (`BT`, `Tf`, `Td`, `TD`, `Tm`, `T*`, `TL`, `Tc`, `Tw`,
/// `Tz`, `Tr`), the fill colour (`g`, `rg`, `k`, `cs`, `sc`, `scn`), and form XObjects (`Do`), into
/// which it follows. Each run's end comes from its glyphs' widths in the font's `/Widths` or `/W`.
///
/// Main-thread only, on the reader's own document — like everything else drawn from it.
final class EditorPDFTextRunReader {
    private(set) var runs: [EditorPDFTextRun] = []

    private struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var fill: EditorPDFRGB? = .black
        /// Components the fill colour space takes, or `nil` for one this does not read.
        var fillComponents: Int? = 1
        var charSpacing: CGFloat = 0
        var wordSpacing: CGFloat = 0
        var horizontalScale: CGFloat = 1
        var leading: CGFloat = 0
        var font: Font?
        var fontSize: CGFloat = 0
        var renderMode = 0
    }

    /// What a run needs of a font resource.
    final class Font {
        let name: String
        let flags: Int
        /// Two bytes per code for a composite (Type0) font, one for a simple one.
        let bytesPerCode: Int
        let widths: [Int: CGFloat]
        let defaultWidth: CGFloat

        init(name: String, flags: Int, bytesPerCode: Int, widths: [Int: CGFloat], defaultWidth: CGFloat) {
            self.name = name
            self.flags = flags
            self.bytesPerCode = bytesPerCode
            self.widths = widths
            self.defaultWidth = defaultWidth
        }

        func width(_ code: Int) -> CGFloat { widths[code] ?? defaultWidth }
    }

    private var state = GraphicsState()
    private var stack: [GraphicsState] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    /// By the font dictionary's address: one resource, read once.
    private var fonts: [Int: Font] = [:]
    private var depth = 0
    /// A page that draws more runs than this is read only this far — the picked words are rarely
    /// past it, and a map of a hundred thousand glyph runs is not worth the wait.
    static let runLimit = 50_000

    /// The runs `page` draws, in drawing order.
    static func runs(of page: CGPDFPage) -> [EditorPDFTextRun] {
        let reader = EditorPDFTextRunReader()
        let stream = CGPDFContentStreamCreateWithPage(page)
        reader.scan(stream)
        return reader.runs
    }

    private func scan(_ stream: CGPDFContentStreamRef) {
        guard depth < 8, runs.count < Self.runLimit else { return }
        depth += 1
        defer { depth -= 1 }
        let table = Self.table
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private static func reader(_ info: UnsafeMutableRawPointer?) -> EditorPDFTextRunReader {
        Unmanaged<EditorPDFTextRunReader>.fromOpaque(info!).takeUnretainedValue()
    }

    // MARK: Operands

    private static func number(_ scanner: CGPDFScannerRef) -> CGFloat? {
        var value: CGPDFReal = 0
        return CGPDFScannerPopNumber(scanner, &value) ? value : nil
    }

    /// `count` numbers, in the order they were written.
    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var out: [CGFloat] = []
        for _ in 0..<count {
            guard let n = number(scanner) else { return nil }
            out.append(n)
        }
        return out.reversed()
    }

    private static func name(_ scanner: CGPDFScannerRef) -> String? {
        var pointer: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    private static func matrix(_ n: [CGFloat]) -> CGAffineTransform {
        CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
    }

    // MARK: The operator table

    /// Built once and never changed after: its callbacks keep no state of their own, only the
    /// reader each scan hands them.
    nonisolated(unsafe) private static let table: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        func on(_ op: String, _ body: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, op, body) }

        on("q") { _, info in let r = reader(info); r.stack.append(r.state) }
        on("Q") { _, info in let r = reader(info); if let s = r.stack.popLast() { r.state = s } }
        on("cm") { s, info in
            guard let n = numbers(s, 6) else { return }
            let r = reader(info)
            r.state.ctm = matrix(n).concatenating(r.state.ctm)
        }
        on("BT") { _, info in let r = reader(info); r.textMatrix = .identity; r.lineMatrix = .identity }
        on("Tf") { s, info in
            guard let size = number(s), let key = name(s) else { return }
            let r = reader(info)
            r.state.fontSize = size
            r.state.font = r.font(named: key, in: CGPDFScannerGetContentStream(s))
        }
        on("Tc") { s, info in if let n = number(s) { reader(info).state.charSpacing = n } }
        on("Tw") { s, info in if let n = number(s) { reader(info).state.wordSpacing = n } }
        on("Tz") { s, info in if let n = number(s) { reader(info).state.horizontalScale = n / 100 } }
        on("TL") { s, info in if let n = number(s) { reader(info).state.leading = n } }
        on("Tr") { s, info in if let n = number(s) { reader(info).state.renderMode = Int(n) } }
        on("Td") { s, info in if let n = numbers(s, 2) { reader(info).moveLine(n[0], n[1]) } }
        on("TD") { s, info in
            guard let n = numbers(s, 2) else { return }
            let r = reader(info)
            r.state.leading = -n[1]
            r.moveLine(n[0], n[1])
        }
        on("Tm") { s, info in
            guard let n = numbers(s, 6) else { return }
            let r = reader(info)
            r.lineMatrix = matrix(n)
            r.textMatrix = r.lineMatrix
        }
        on("T*") { _, info in let r = reader(info); r.moveLine(0, -r.state.leading) }
        on("Tj") { s, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(s, &string), let string else { return }
            let r = reader(info)
            r.show([.bytes(EditorPDFTextRunReader.bytes(string))])
        }
        on("'") { s, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(s, &string), let string else { return }
            let r = reader(info)
            r.moveLine(0, -r.state.leading)
            r.show([.bytes(EditorPDFTextRunReader.bytes(string))])
        }
        on("\"") { s, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(s, &string), let string, let n = numbers(s, 2) else { return }
            let r = reader(info)
            r.state.wordSpacing = n[0]
            r.state.charSpacing = n[1]
            r.moveLine(0, -r.state.leading)
            r.show([.bytes(EditorPDFTextRunReader.bytes(string))])
        }
        on("TJ") { s, info in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(s, &array), let array else { return }
            var parts: [ShowPart] = []
            for i in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var value: CGPDFReal = 0
                if CGPDFArrayGetString(array, i, &string), let string {
                    parts.append(.bytes(EditorPDFTextRunReader.bytes(string)))
                } else if CGPDFArrayGetNumber(array, i, &value) {
                    parts.append(.adjust(value))
                }
            }
            reader(info).show(parts)
        }
        // Fill colour.
        on("g") { s, info in
            guard let n = number(s) else { return }
            let r = reader(info)
            r.state.fill = EditorPDFRGB(red: n, green: n, blue: n)
            r.state.fillComponents = 1
        }
        on("rg") { s, info in
            guard let n = numbers(s, 3) else { return }
            let r = reader(info)
            r.state.fill = EditorPDFRGB(red: n[0], green: n[1], blue: n[2])
            r.state.fillComponents = 3
        }
        on("k") { s, info in
            guard let n = numbers(s, 4) else { return }
            let r = reader(info)
            r.state.fill = EditorPDFTextRunReader.cmyk(n)
            r.state.fillComponents = 4
        }
        on("cs") { s, info in
            guard let key = name(s) else { return }
            let r = reader(info)
            r.state.fillComponents = EditorPDFTextRunReader.components(ofSpace: key, in: CGPDFScannerGetContentStream(s))
            // Every space's initial colour is black, or its zero tint.
            r.state.fill = r.state.fillComponents == nil ? nil : .black
        }
        let setColor: CGPDFOperatorCallback = { s, info in
            let r = reader(info)
            guard let count = r.state.fillComponents, let n = numbers(s, count) else {
                r.state.fill = nil
                return
            }
            switch count {
            case 1: r.state.fill = EditorPDFRGB(red: n[0], green: n[0], blue: n[0])
            case 3: r.state.fill = EditorPDFRGB(red: n[0], green: n[1], blue: n[2])
            case 4: r.state.fill = EditorPDFTextRunReader.cmyk(n)
            default: r.state.fill = nil
            }
        }
        on("sc", setColor)
        on("scn", setColor)
        on("Do") { s, info in
            guard let key = name(s) else { return }
            reader(info).drawForm(named: key, in: CGPDFScannerGetContentStream(s))
        }
        return table
    }()

    private static func bytes(_ string: CGPDFStringRef) -> [UInt8] {
        guard let pointer = CGPDFStringGetBytePtr(string) else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: CGPDFStringGetLength(string)))
    }

    private static func cmyk(_ n: [CGFloat]) -> EditorPDFRGB {
        EditorPDFRGB(red: (1 - n[0]) * (1 - n[3]), green: (1 - n[1]) * (1 - n[3]), blue: (1 - n[2]) * (1 - n[3]))
    }

    /// How many numbers a fill in `space` takes, for the spaces this reads as colour.
    private static func components(ofSpace key: String, in stream: CGPDFContentStreamRef) -> Int? {
        switch key {
        case "DeviceGray", "CalGray", "G": return 1
        case "DeviceRGB", "CalRGB", "RGB": return 3
        case "DeviceCMYK", "CMYK": return 4
        default: break
        }
        guard let object = CGPDFContentStreamGetResource(stream, "ColorSpace", key) else { return nil }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array else {
            var name: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object, .name, &name), let name { return components(ofSpace: String(cString: name), in: stream) }
            return nil
        }
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &family), let family else { return nil }
        switch String(cString: family) {
        case "CalGray": return 1
        case "CalRGB": return 3
        case "ICCBased":
            var stream: CGPDFStreamRef?
            var n: CGPDFInteger = 0
            guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetInteger(dict, "N", &n), [1, 3, 4].contains(n) else { return nil }
            return n
        default:
            return nil
        }
    }

    // MARK: Text

    private enum ShowPart {
        case bytes([UInt8])
        /// A `TJ` adjustment, in thousandths of the font size, moving back.
        case adjust(CGFloat)
    }

    private func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    /// One run: where the text matrix stands now, then advanced by every glyph and adjustment.
    private func show(_ parts: [ShowPart]) {
        guard runs.count < Self.runLimit, let font = state.font else { return }
        let begin = textMatrix
        let size = state.fontSize
        let scale = state.horizontalScale
        for part in parts {
            switch part {
            case .adjust(let n):
                advance(-n / 1000 * size * scale)
            case .bytes(let bytes):
                var i = 0
                while i < bytes.count {
                    let code: Int
                    if font.bytesPerCode == 2, i + 1 < bytes.count {
                        code = Int(bytes[i]) << 8 | Int(bytes[i + 1])
                        i += 2
                    } else {
                        code = Int(bytes[i])
                        i += 1
                    }
                    let space = font.bytesPerCode == 1 && code == 32 ? state.wordSpacing : 0
                    advance((font.width(code) / 1000 * size + state.charSpacing + space) * scale)
                }
            }
        }
        let start = CGPoint.zero.applying(begin.concatenating(state.ctm))
        let end = CGPoint.zero.applying(textMatrix.concatenating(state.ctm))
        // The size on the page: the text space's vertical unit, through both matrices.
        let m = begin.concatenating(state.ctm)
        runs.append(EditorPDFTextRun(fontName: font.name, fontFlags: font.flags,
                                     fontSize: abs(size) * hypot(m.c, m.d), start: start, end: end,
                                     color: state.fill, isInvisible: state.renderMode == 3))
    }

    private func advance(_ tx: CGFloat) {
        textMatrix = CGAffineTransform(translationX: tx, y: 0).concatenating(textMatrix)
    }

    // MARK: Fonts

    private func font(named key: String, in stream: CGPDFContentStreamRef) -> Font? {
        guard let object = CGPDFContentStreamGetResource(stream, "Font", key) else { return nil }
        var dict: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dict), let dict else { return nil }
        let id = unsafeBitCast(dict, to: Int.self)
        if let known = fonts[id] { return known }
        let font = Self.readFont(dict)
        fonts[id] = font
        return font
    }

    private static func string(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var name: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, key, &name), let name else { return nil }
        return String(cString: name)
    }

    private static func real(_ array: CGPDFArrayRef, _ i: Int) -> CGFloat? {
        var value: CGPDFReal = 0
        return CGPDFArrayGetNumber(array, i, &value) ? value : nil
    }

    static func readFont(_ dict: CGPDFDictionaryRef) -> Font {
        let base = string(dict, "BaseFont") ?? ""
        let name = EditorPDFFontMatch.dropSubsetTag(base)
        var flags = 0
        var descriptor: CGPDFDictionaryRef?
        var widths: [Int: CGFloat] = [:]
        var defaultWidth: CGFloat = 0
        if string(dict, "Subtype") == "Type0" {
            var descendants: CGPDFArrayRef?
            var cid: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dict, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &cid), let cid {
                var dw: CGPDFReal = 1000
                defaultWidth = CGPDFDictionaryGetNumber(cid, "DW", &dw) ? dw : 1000
                var w: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(cid, "W", &w), let w { widths = cidWidths(w) }
                _ = CGPDFDictionaryGetDictionary(cid, "FontDescriptor", &descriptor)
            }
            if let descriptor { flags = flagsOf(descriptor) }
            return Font(name: name, flags: flags, bytesPerCode: 2, widths: widths, defaultWidth: defaultWidth)
        }
        _ = CGPDFDictionaryGetDictionary(dict, "FontDescriptor", &descriptor)
        if let descriptor {
            flags = flagsOf(descriptor)
            var missing: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missing) { defaultWidth = missing }
        }
        var array: CGPDFArrayRef?
        var first: CGPDFInteger = 0
        if CGPDFDictionaryGetArray(dict, "Widths", &array), let array {
            _ = CGPDFDictionaryGetInteger(dict, "FirstChar", &first)
            for i in 0..<CGPDFArrayGetCount(array) {
                if let w = real(array, i) { widths[first + i] = w }
            }
        } else if let face = NSFont(name: name, size: 1000) {
            // One of the standard fourteen, named without widths: the Mac's own face of that name.
            for code in 32..<256 {
                guard let scalar = UnicodeScalar(code) else { continue }
                widths[code] = NSAttributedString(string: String(Character(scalar)), attributes: [.font: face]).size().width
            }
            if defaultWidth == 0 { defaultWidth = 500 }
        } else if defaultWidth == 0 {
            defaultWidth = 500
        }
        return Font(name: name, flags: flags, bytesPerCode: 1, widths: widths, defaultWidth: defaultWidth)
    }

    private static func flagsOf(_ descriptor: CGPDFDictionaryRef) -> Int {
        var flags: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(descriptor, "Flags", &flags) ? flags : 0
    }

    /// A CID font's `/W`: `c [w1 w2 …]` gives widths from `c` on, `cFirst cLast w` one width for a range.
    private static func cidWidths(_ w: CGPDFArrayRef) -> [Int: CGFloat] {
        var out: [Int: CGFloat] = [:]
        var i = 0
        let count = CGPDFArrayGetCount(w)
        while i < count {
            guard let first = real(w, i) else { break }
            var list: CGPDFArrayRef?
            if i + 1 < count, CGPDFArrayGetArray(w, i + 1, &list), let list {
                for j in 0..<CGPDFArrayGetCount(list) {
                    if let width = real(list, j) { out[Int(first) + j] = width }
                }
                i += 2
            } else if i + 2 < count, let last = real(w, i + 1), let width = real(w, i + 2) {
                // Bounded: a malformed range must not build a dictionary of millions.
                if last >= first, last - first < 70_000 {
                    for c in Int(first)...Int(last) { out[c] = width }
                }
                i += 3
            } else {
                break
            }
        }
        return out
    }

    // MARK: Form XObjects

    private func drawForm(named key: String, in stream: CGPDFContentStreamRef) {
        guard let object = CGPDFContentStreamGetResource(stream, "XObject", key) else { return }
        var form: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &form), let form, let dict = CGPDFStreamGetDictionary(form),
              Self.string(dict, "Subtype") == "Form" else { return }
        var resources: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
        let saved = state
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
            let n = (0..<6).compactMap { Self.real(array, $0) }
            if n.count == 6 { state.ctm = Self.matrix(n).concatenating(state.ctm) }
        }
        let savedText = (textMatrix, lineMatrix, stack)
        stack = []
        // A form with no `/Resources` of its own takes its page's: handed its own dictionary, which
        // has no `/Font` or `/XObject`, every lookup falls through to the parent stream's.
        let content = CGPDFContentStreamCreateWithStream(form, resources ?? dict, stream)
        scan(content)
        CGPDFContentStreamRelease(content)
        (textMatrix, lineMatrix, stack) = savedText
        state = saved
    }
}
