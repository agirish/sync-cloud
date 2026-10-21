import AppKit
import Foundation
import PDFKit

/// **The font a correction's words are drawn in** (TE83, TE86): the original's own face when this
/// Mac has it — "Same font" — else the nearest of the Aa tool's fonts — "Stand-in".
enum EditorPDFFontMatch {
    /// "ABCDEF+ArialMT" → "ArialMT": a subset's six-capital tag and its plus go.
    static func dropSubsetTag(_ name: String) -> String {
        let chars = Array(name)
        guard chars.count > 7, chars[6] == "+", chars[0..<6].allSatisfy({ $0.isASCII && $0.isUppercase }) else { return name }
        return String(chars[7...])
    }

    /// **The PostScript name this Mac draws `name` in, or `nil` when it hasn't the face** — the
    /// name itself when a face of exactly that name opens (Times and Courier do, though no font list
    /// shows them), else the family a TrueType-style name gives — "Arial", "Times New Roman",
    /// "Courier New,Bold" — in its style.
    static func installed(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if let face = NSFont(name: name, size: 12), face.fontName == name { return name }
        let parts = name.split(separator: ",", maxSplits: 1).map(String.init)
        // A PostScript name with its style after a dash is a face, not a family: missing is missing.
        guard parts.count == 2 || !name.contains("-") else { return nil }
        let style = parts.count == 2 ? parts[1].lowercased() : ""
        let wanted = squashed(parts[0])
        guard let family = NSFontManager.shared.availableFontFamilies.first(where: { squashed($0) == wanted }) else { return nil }
        var traits: NSFontTraitMask = []
        if style.contains("bold") { traits.insert(.boldFontMask) }
        if style.contains("italic") || style.contains("oblique") { traits.insert(.italicFontMask) }
        guard let face = NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: 12),
              NSFontManager.shared.traits(of: face).isSuperset(of: traits) else { return nil }
        return face.fontName
    }

    /// "Times New Roman" and "TimesNewRoman" as one key.
    private static func squashed(_ family: String) -> String { family.replacingOccurrences(of: " ", with: "").lowercased() }

    /// **The Aa font nearest a face this Mac lacks**: its descriptor's flags first — fixed pitch,
    /// script, serif — then its name, for a font whose flags say nothing.
    static func standIn(for name: String, flags: Int) -> EditorPDFTextFont {
        if flags & EditorPDFTextRun.fixedPitchFlag != 0 { return .mono }
        if flags & EditorPDFTextRun.scriptFlag != 0 { return .handwritten }
        if flags & EditorPDFTextRun.serifFlag != 0 { return .serif }
        let lower = name.lowercased()
        if ["mono", "courier", "consol", "menlo", "code", "typewriter", "ocr"].contains(where: lower.contains) { return .mono }
        if ["sans", "grotesk", "gothic", "arial", "helvet"].contains(where: lower.contains) { return .sans }
        if ["serif", "times", "roman", "garamond", "georgia", "cambria", "minion", "book", "caslon", "baskerville",
            "palatino", "charter", "slab", "adelle"].contains(where: lower.contains) { return .serif }
        return .sans
    }

    /// The family a reader knows the face by — "Adelle", "Times New Roman" — for the line under
    /// the retype box. The PostScript name's style goes: "TimesNewRomanPS-BoldMT" → "TimesNewRomanPS".
    static func shownName(_ postScriptName: String) -> String {
        if let font = NSFont(name: postScriptName, size: 12), let family = font.familyName { return family }
        let base = postScriptName.split(whereSeparator: { $0 == "-" || $0 == "," }).first.map(String.init) ?? postScriptName
        return base.isEmpty ? postScriptName : base
    }
}

/// **What a click with Replace picked** (TE83): the words, where they are, and how to redraw them.
/// Every rect and point is in the page's DISPLAY space, as Fill & Sign's items are.
public struct EditorPDFReplacePick: Equatable, Sendable {
    public var page: Int
    /// The words as the page's text layer has them.
    public var words: String
    /// The words' glyphs' box, as the text layer reports each one.
    public var wordsRect: CGRect
    /// What the patch covers: the words' box with a margin for the glyphs' edges.
    public var cover: CGRect
    /// The original's baseline and the left of its first glyph.
    public var baseline: CGFloat
    public var left: CGFloat
    public var fontSize: CGFloat
    /// The original font's name, its subset tag dropped — `nil` when no run on the page was found
    /// under the words.
    public var fontName: String?
    /// The PostScript name to draw in when this Mac has the original's face, else `nil`.
    public var installedFont: String?
    /// The Aa font nearest the original, for when it isn't installed — or when it is changed.
    public var standIn: EditorPDFTextFont
    public var ink: EditorPDFRGB
    public var patch: EditorPDFRGB
    /// Whether the ground around the words is one flat colour — the patch shows on any other.
    public var plainBackground: Bool
}

/// **Why Replace says no** (TE87), each in words the reader is told — the tool's tooltip, the
/// right-click item's line, the note card after a click.
public enum EditorPDFReplaceRefusal: Error, Equatable, Sendable {
    case noText
    case severalLines
    case brokenTextLayer
    case notAcross
    case inFormField

    public var reason: String {
        switch self {
        case .noText: return "There’s no text on this page to replace."
        case .severalLines: return "Pick words on one line."
        case .brokenTextLayer:
            return "This page’s text doesn’t line up with what’s printed, so the patch would land in the wrong place."
        case .notAcross: return "These words don’t run across the page, so new words can’t be set over them."
        case .inFormField: return "These words are inside a form field. Fill it with Form Fields instead."
        }
    }
}

/// **Finding and measuring the words Replace picks** — on the reader's own document, on the main
/// thread, as PDFView itself reads it for a text selection.
@MainActor
enum EditorPDFReplace {
    /// A gap between two glyphs wider than this many times the font size splits a line into two
    /// runs of words — the columns of a table, a label and its value.
    static let columnGap: CGFloat = 1.2

    /// The patch reaches this far past the glyphs' box, as a share of the font size, and never
    /// less than `minimumMargin` — antialiased edges and an accent's top otherwise peep out.
    static let marginShare: CGFloat = 0.08
    static let minimumMargin: CGFloat = 0.6

    // MARK: Which words

    /// One character of a selection: where it is in the page's string, and its box in page space.
    struct Glyph {
        var index: Int
        var bounds: CGRect
        var isSpace: Bool
    }

    static func glyphs(of selection: PDFSelection, on page: PDFPage) -> [Glyph] {
        guard let string = page.string as NSString? else { return [] }
        var out: [Glyph] = []
        for r in 0..<selection.numberOfTextRanges(on: page) {
            let range = selection.range(at: r, on: page)
            guard range.location != NSNotFound else { continue }
            for i in range.location..<min(range.location + range.length, string.length) {
                let c = string.character(at: i)
                let space = c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0
                // A one-character selection's box, not `characterBounds(at:)`: on some files that
                // runs two characters behind the page's string — measured 2026-10-20, "Account
                // Number: 311311897" put its last "9" on another line — and it is drawn tight to
                // the ink, where a selection's box spans the font's height.
                let bounds = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
                out.append(Glyph(index: i, bounds: bounds, isSpace: space))
            }
        }
        return out.sorted { $0.index < $1.index }
    }

    /// **The words on the line under `point`** (page space): the glyphs in a thin strip across the
    /// page at the pointer, kept to the line of the one under it, cut at a gap as wide as a table's
    /// column, to the piece under the pointer. `nil` off any text.
    ///
    /// Found by where glyphs are, not by PDFKit's `selectionForLine(at:)`, which follows the page's
    /// string — and on a flattened form (his Form G-28) that string runs in another order than the
    /// print, so the line it gave was one across the page from the pointer.
    static func line(at point: CGPoint, on page: PDFPage, box: EditorPDFPageBox) -> PDFSelection? {
        let shownPoint = box.displayPoint(page: point)
        let across = CGRect(x: 0, y: shownPoint.y - 0.5, width: box.displaySize.width, height: 1)
        guard let strip = page.selection(for: box.pageRect(display: across)) else { return nil }
        let all = glyphs(of: strip, on: page)
        let marks = all.filter { !$0.isSpace && !$0.bounds.isEmpty }
            .map { (glyph: $0, shown: box.displayRect(page: $0.bounds)) }
        guard let anchor = marks.filter({ $0.shown.insetBy(dx: -1, dy: 0).contains(shownPoint) })
            .min(by: { abs($0.shown.midX - shownPoint.x) < abs($1.shown.midX - shownPoint.x) }) else { return nil }
        // The anchor's line: glyphs that share at least half its height.
        let line = marks.filter { overlap($0.shown, anchor.shown) >= 0.5 * min($0.shown.height, anchor.shown.height) }
            .sorted { $0.shown.minX < $1.shown.minX }
        let size = median(line.map(\.shown.height)) / 1.15
        var pieces: [[(glyph: Glyph, shown: CGRect)]] = []
        for mark in line {
            if let previous = pieces.last?.last, mark.shown.minX - previous.shown.maxX <= columnGap * max(size, 1) {
                pieces[pieces.count - 1].append(mark)
            } else {
                pieces.append([mark])
            }
        }
        guard let piece = pieces.first(where: { $0.contains { $0.glyph.index == anchor.glyph.index } }) else { return nil }
        // The piece's characters and the spaces between them, in the page's string.
        let kept = Set(piece.map(\.glyph.index))
        let lo = kept.min()!, hi = kept.max()!
        let spaces = all.filter { $0.isSpace && $0.index > lo && $0.index < hi }
            .filter { g in piece.contains { $0.glyph.index == g.index - 1 } || piece.contains { $0.glyph.index == g.index + 1 } }
        return selection(of: kept.union(spaces.map(\.index)), on: page)
    }

    /// How far two rects overlap from top to bottom.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat { max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY)) }

    /// One selection of exactly these characters, a contiguous run at a time.
    static func selection(of indices: Set<Int>, on page: PDFPage) -> PDFSelection? {
        let sorted = indices.sorted()
        guard var start = sorted.first else { return nil }
        var ranges: [NSRange] = []
        var end = start
        for i in sorted.dropFirst() {
            if i == end + 1 { end = i } else { ranges.append(NSRange(location: start, length: end - start + 1)); start = i; end = i }
        }
        ranges.append(NSRange(location: start, length: end - start + 1))
        guard let out = page.selection(for: ranges[0]) else { return nil }
        for range in ranges.dropFirst() {
            if let more = page.selection(for: range) { out.add(more) }
        }
        return out
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    /// PDFKit's point size for the selection's first glyph. Its face can be a stand-in; its size,
    /// measured with the content stream's, agrees in 77% of lines — the run's is used when found.
    static func fontSize(of selection: PDFSelection) -> CGFloat? {
        guard let attributed = selection.attributedString, attributed.length > 0,
              let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return nil }
        return font.pointSize
    }

    /// Whether the page has any text at all — a scan has none.
    static func hasText(_ page: PDFPage) -> Bool {
        !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The page's form-field widgets, page space — words inside one are the field's to change.
    static func widgets(on page: PDFPage) -> [CGRect] {
        page.annotations.filter { $0.type == "Widget" }.map(\.bounds)
    }

    // MARK: Measuring them

    /// **The pick for `selection` on `page`**, or why Replace refuses it — every check made here
    /// rather than after the reader has typed.
    static func pick(_ selection: PDFSelection, page: PDFPage, index: Int, box: EditorPDFPageBox,
                     widgets: [CGRect] = []) -> Result<EditorPDFReplacePick, EditorPDFReplaceRefusal> {
        guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.noText)
        }
        let raw = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(.noText) }
        guard selection.pages.count == 1 else { return .failure(.severalLines) }
        let marks = glyphs(of: selection, on: page).filter { !$0.isSpace && !$0.bounds.isEmpty }
        guard let first = marks.first, let last = marks.last else { return .failure(.noText) }
        // One line as printed: every glyph shares half its height with the first. PDFKit's own
        // lines can't say — it splits one printed line into two where its runs were written apart.
        let firstShown = box.displayRect(page: first.bounds)
        if marks.contains(where: { glyph in
            let shown = box.displayRect(page: glyph.bounds)
            return overlap(shown, firstShown) < 0.5 * min(shown.height, firstShown.height)
        }) {
            return .failure(.severalLines)
        }
        // The text layer's breaks inside one printed line are spaces. Its spaces stay as they are: a
        // double space taken down to one moved every word after it (measured 2026-10-20, "Plan Year:
        // 01/01/2018" retyped as it was came out a space short).
        let words = String(raw.map { $0.isNewline || $0 == "\t" ? " " : $0 })
        let pageRect = marks.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let reported = fontSize(of: selection) ?? pageRect.height

        // **The layer check, by its box** (Form G-28): the words' box as PDFKit reports it against
        // their glyphs' own. On a healthy page the two agree; on a broken one a word claims most of
        // the page.
        let claimed = selection.bounds(for: page)
        let slack = max(4, reported)
        if claimed.width > pageRect.width + 2 * slack || claimed.height > pageRect.height + 2 * slack
            || pageRect.height > 4 * max(reported, 1) {
            return .failure(.brokenTextLayer)
        }
        // Across the page as it is shown: the last glyph right of the first.
        let lastShown = box.displayRect(page: last.bounds)
        if marks.count > 1, lastShown.midX < firstShown.midX { return .failure(.notAcross) }
        if widgets.contains(where: { $0.intersects(pageRect) }) { return .failure(.inFormField) }

        let shown = box.displayRect(page: pageRect)
        let run = page.pageRef.flatMap { run(under: firstShown, in: EditorPDFTextRunReader.runs(of: $0), box: box) }
        let size = ((run?.fontSize ?? reported) * 10).rounded() / 10
        let baseline = run.map { box.displayPoint(page: $0.start).y } ?? shown.minY + 0.2 * size
        let fontName = run?.fontName
        let installed = fontName.flatMap { EditorPDFFontMatch.installed($0) }
        let standIn = EditorPDFFontMatch.standIn(for: fontName ?? "", flags: run?.fontFlags ?? 0)
        let margin = max(minimumMargin, marginShare * size)
        let cover = shown.insetBy(dx: -margin, dy: -margin)
        let ground = background(around: cover, page: page, box: box, ink: run?.color)
        // **The layer check, by the print**: the words' glyphs are drawn inside their box. Where the
        // page's text says words are and nothing is printed, the patch would cover the wrong place.
        if ground.inkShare < minimumInk { return .failure(.brokenTextLayer) }
        let ink = run?.color ?? attributedInk(of: selection) ?? .black
        return .success(EditorPDFReplacePick(
            page: index, words: words, wordsRect: shown, cover: cover, baseline: baseline,
            left: shown.minX, fontSize: max(size, 1), fontName: fontName, installedFont: installed, standIn: standIn,
            ink: ink, patch: ground.color, plainBackground: ground.isPlain))
    }

    /// **The run that draws the glyph at `glyph`** (display space): of the upright runs whose line
    /// the glyph sits on, the last to start at or before it. Their ends come from widths a font may
    /// carry wrong; their starts are where the content stream put them.
    static func run(under glyph: CGRect, in runs: [EditorPDFTextRun], box: EditorPDFPageBox) -> EditorPDFTextRun? {
        let shown = runs.filter { !$0.isInvisible }.map { run -> (run: EditorPDFTextRun, start: CGPoint, end: CGPoint) in
            (run, box.displayPoint(page: run.start), box.displayPoint(page: run.end))
        }
        let onLine = shown.filter { r in
            abs(r.end.y - r.start.y) < 0.5 && r.end.x >= r.start.x - 0.01
                && glyph.midY >= r.start.y - 0.35 * r.run.fontSize && glyph.midY <= r.start.y + r.run.fontSize
        }
        let before = onLine.filter { $0.start.x <= glyph.minX + 1 }
        return before.max { a, b in
            if abs(a.start.x - b.start.x) > 0.01 { return a.start.x < b.start.x }
            // Two runs starting together: the one whose line the glyph's middle is closer to.
            return abs(glyph.midY - (a.start.y + 0.35 * a.run.fontSize)) > abs(glyph.midY - (b.start.y + 0.35 * b.run.fontSize))
        }?.run
    }

    /// PDFKit's colour for the first glyph — second to the content stream's, which matched the
    /// pixels better in 172 of the 197 lines where the two disagreed (2026-10-20).
    static func attributedInk(of selection: PDFSelection) -> EditorPDFRGB? {
        guard let attributed = selection.attributedString, attributed.length > 0,
              let color = (attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        else { return nil }
        return EditorPDFRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }

    // MARK: The ground under them

    /// The ring round the cover that must be the ground too, in points, and the pixels per point.
    static let ringWidth: CGFloat = 1.5
    static let samplingScale: CGFloat = 2
    /// A pixel within this of a blend of ground and ink is plain; more than ``shadeShare`` of the
    /// cover and its ring beyond it is a pattern.
    static let plainTolerance: CGFloat = 0.08
    static let shadeShare: CGFloat = 0.1
    /// A pixel this far from the ground is ink, and words cover at least this share of their box.
    static let inkDistance: CGFloat = 0.25
    static let minimumInk: CGFloat = 0.02

    /// **The colour the page has under the words, whether it is one flat colour, and how much of
    /// the cover is ink** (display space). The page is drawn into an sRGB bitmap as the copy flattens
    /// it. The ground is the commonest colour INSIDE the cover — the space between the glyphs —
    /// not around it: white words on a coloured band took the white of the page past the band
    /// (his property tax bill, 2026-10-20). Plain means every pixel in the cover and in a thin ring
    /// round it is the ground, the ink, or a blend of the two — anything else is a pattern, or an
    /// edge the patch would show against.
    static func background(around cover: CGRect, page: PDFPage, box: EditorPDFPageBox, ink: EditorPDFRGB?)
        -> (color: EditorPDFRGB, isPlain: Bool, inkShare: CGFloat) {
        let ring = ringWidth
        let area = cover.insetBy(dx: -ring, dy: -ring).intersection(box.displayBounds)
        guard !area.isNull, area.width > 0, area.height > 0, let pixels = render(area, page: page, box: box) else {
            return (.white, true, 1)
        }
        var outside: [EditorPDFRGB] = []
        var inside: [EditorPDFRGB] = []
        let scale = samplingScale
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = CGPoint(x: area.minX + (CGFloat(x) + 0.5) / scale, y: area.minY + (CGFloat(y) + 0.5) / scale)
                if cover.contains(p) { inside.append(pixels.color(x: x, y: y)) } else { outside.append(pixels.color(x: x, y: y)) }
            }
        }
        guard !inside.isEmpty else { return (.white, true, 1) }
        let ground = commonest(inside)
        let inkShare = CGFloat(inside.filter { $0.distance(to: ground) > inkDistance }.count) / CGFloat(inside.count)
        // The ink: the run's, else the cover's pixel farthest from the ground.
        let ink = ink ?? inside.max { $0.distance(to: ground) < $1.distance(to: ground) } ?? ground
        // Inside, glyph edges blend ground into ink: only what is off that blend is a pattern. In the
        // ring, past the glyphs, a faint shade of the ground is one too — a texture, a gradient.
        let offInside = inside.filter { offBlend($0, ground, ink) > plainTolerance }.count
        let offRing = outside.filter { c in
            let d = c.distance(to: ground)
            return (d > plainTolerance && d <= inkDistance) || (d > inkDistance && offBlend(c, ground, ink) > plainTolerance)
                && c.distance(to: ink) > inkDistance
        }.count
        let plain = CGFloat(offInside) <= shadeShare * CGFloat(inside.count)
            && CGFloat(offRing) <= shadeShare * CGFloat(max(outside.count, 1))
        return (ground, plain, inkShare)
    }

    /// How far `c` lies from every blend of `a` and `b` — 0 for either, or anything an antialiased
    /// edge between them draws.
    static func offBlend(_ c: EditorPDFRGB, _ a: EditorPDFRGB, _ b: EditorPDFRGB) -> CGFloat {
        let d = (b.red - a.red, b.green - a.green, b.blue - a.blue)
        let length = d.0 * d.0 + d.1 * d.1 + d.2 * d.2
        guard length > 0 else { return c.distance(to: a) }
        let t = max(0, min(1, ((c.red - a.red) * d.0 + (c.green - a.green) * d.1 + (c.blue - a.blue) * d.2) / length))
        return c.distance(to: EditorPDFRGB(red: a.red + t * d.0, green: a.green + t * d.1, blue: a.blue + t * d.2))
    }

    /// The commonest colour of `samples`, bucketed by 1/16 a component, averaged within its bucket.
    static func commonest(_ samples: [EditorPDFRGB]) -> EditorPDFRGB {
        func key(_ c: EditorPDFRGB) -> Int { Int(c.red * 15.99) << 8 | Int(c.green * 15.99) << 4 | Int(c.blue * 15.99) }
        var buckets: [Int: [EditorPDFRGB]] = [:]
        for s in samples { buckets[key(s), default: []].append(s) }
        let top = buckets.values.max { $0.count < $1.count }!
        let n = CGFloat(top.count)
        return EditorPDFRGB(red: top.reduce(0) { $0 + $1.red } / n, green: top.reduce(0) { $0 + $1.green } / n,
                            blue: top.reduce(0) { $0 + $1.blue } / n)
    }

    /// An sRGB bitmap of an area of the page, its content and annotations as drawn.
    struct Pixels {
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var data: [UInt8]

        /// Row 0 is the BOTTOM of the area, as display space runs.
        func color(x: Int, y: Int) -> EditorPDFRGB {
            let o = (height - 1 - y) * bytesPerRow + x * 4
            let a = CGFloat(data[o + 3]) / 255
            guard a > 0 else { return .white }
            // Premultiplied over white.
            return EditorPDFRGB(red: CGFloat(data[o]) / 255 + (1 - a), green: CGFloat(data[o + 1]) / 255 + (1 - a),
                                blue: CGFloat(data[o + 2]) / 255 + (1 - a))
        }
    }

    /// `area` of the page as shown (display space), drawn as the toolkit flattens a page: the
    /// content under the crop box's drawing transform, then the annotations, which map into
    /// display space themselves.
    static func render(_ area: CGRect, page: PDFPage, box: EditorPDFPageBox) -> Pixels? {
        let scale = samplingScale
        let width = Int(ceil(area.width * scale)), height = Int(ceil(area.height * scale))
        guard width > 0, height > 0, width * height < 4_000_000, let cgPage = page.pageRef,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.saveGState()
        ctx.concatenate(cgPage.getDrawingTransform(.cropBox, rect: box.displayBounds, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
        let annotations = page.annotations.filter(\.shouldDisplay)
        if !annotations.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for annotation in annotations { annotation.draw(with: .cropBox, in: ctx) }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let base = ctx.data else { return nil }
        let count = ctx.bytesPerRow * height
        let bytes = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: count))
        return Pixels(width: width, height: height, bytesPerRow: ctx.bytesPerRow, data: bytes)
    }
}

/// **A correction placed with Replace** (TE83): the new words over a patch that hides the old ones.
/// Every rect and point is in its page's DISPLAY space, as the item's own rect is.
///
/// The patch stays where the old words are: a correction is not dragged, and its words keep the
/// old ones' baseline and left edge whatever their size — so the item's rect follows them.
public struct EditorPDFCorrection: Equatable, Sendable {
    /// The words covered, as the page's text layer has them.
    public var covered: String
    /// The new words — the covered ones until they are retyped.
    public var words: String
    /// What the patch covers.
    public var cover: CGRect
    public var baseline: CGFloat
    public var left: CGFloat
    public var patch: EditorPDFRGB
    public var plainBackground: Bool
    /// The original font's name, for the line under the retype box — `nil` when none was found.
    public var fontName: String?
    /// The PostScript name of the original's face on this Mac, or `nil` when it hasn't it.
    public var installedFont: String?
    /// Drawn in the original's face rather than the item's Aa font — while it is installed and no
    /// other font has been chosen.
    public var keepsOriginalFont: Bool
    /// The original's ink, and whether it is still the one drawn rather than the palette's.
    public var ink: EditorPDFRGB
    public var keepsOriginalInk: Bool

    public init(_ pick: EditorPDFReplacePick) {
        covered = pick.words
        words = pick.words
        cover = pick.cover
        baseline = pick.baseline
        left = pick.left
        patch = pick.patch
        plainBackground = pick.plainBackground
        fontName = pick.fontName
        installedFont = pick.installedFont
        keepsOriginalFont = pick.installedFont != nil
        ink = pick.ink
        keepsOriginalInk = true
    }

    /// Whether the words are drawn in the original's own face.
    public var isSameFont: Bool { keepsOriginalFont && installedFont != nil }
}

/// **A page's corrections, as the note card says them** (TE85): the covered words are still in the
/// copy, and the page can be made a picture to take them out (decision AK, 2026-10-20).
public struct EditorPDFCorrectionNote: Equatable, Sendable, Identifiable {
    public var page: Int
    public var line: String
    public var button: String
    /// The page is set to be saved as a picture: the button puts it back.
    public var pictured: Bool

    public var id: Int { page }
}

extension EditorPDFRGB {
    /// A plain word for the colour, for the line under the retype box — "black", "dark red".
    var name: String {
        let hi = max(red, green, blue), lo = min(red, green, blue)
        if hi - lo < 0.1 {
            switch hi {
            case ..<0.2: return "black"
            case ..<0.8: return "grey"
            default: return "white"
            }
        }
        var hue: CGFloat = 0
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
        let word: String
        switch hue * 360 {
        case ..<15, 345...: word = "red"
        case ..<45: word = "orange"
        case ..<70: word = "yellow"
        case ..<170: word = "green"
        case ..<260: word = "blue"
        case ..<300: word = "purple"
        default: word = "pink"
        }
        return hi < 0.45 ? "dark \(word)" : word
    }
}

/// **The line under a correction's retype box** (TE83, mockup step 2): the font the new words use
/// — and whether it is the original, or a stand-in for one this Mac hasn't — their size and ink,
/// and the two keys. Drawn as a small popover would be, in the menu's own colours.
final class EditorPDFRetypeHint: NSView {
    struct Lines: Equatable {
        var font: String
        var chip: String
        var sameFont: Bool
        var keys: String
    }

    var lines = Lines(font: "", chip: "", sameFont: true, keys: "") {
        didSet { if lines != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    static let sameFontChip = "Same font"
    static let standInChip = "Stand-in"
    static let keysLine = "Return to place · Esc to cancel"

    static func lines(for item: EditorPDFFillItem, correction: EditorPDFCorrection) -> Lines {
        let size = item.fontSize.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(item.fontSize))" : String(format: "%.1f", item.fontSize)
        let tail = "\(size) pt · \(item.ink.name)"
        if correction.isSameFont, let installed = correction.installedFont {
            return Lines(font: "\(EditorPDFFontMatch.shownName(installed)) · \(tail)", chip: sameFontChip, sameFont: true, keys: keysLine)
        }
        let font: String
        if let name = correction.fontName, correction.installedFont == nil {
            font = "\(EditorPDFFontMatch.shownName(name)) isn’t on this Mac, using \(item.font.title) · \(tail)"
        } else if correction.fontName == nil {
            font = "The original font wasn’t found, using \(item.font.title) · \(tail)"
        } else {
            font = "\(item.font.title) · \(tail)"
        }
        return Lines(font: font, chip: standInChip, sameFont: false, keys: keysLine)
    }

    private static let padding = CGSize(width: 9, height: 6)
    private static let gap: CGFloat = 4

    private var fontLine: NSAttributedString {
        NSAttributedString(string: lines.font, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
    }

    private var chipLine: NSAttributedString {
        NSAttributedString(string: lines.chip, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: lines.sameFont ? NSColor.systemGreen : NSColor.systemOrange,
        ])
    }

    private var keysLine: NSAttributedString {
        NSAttributedString(string: lines.keys, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
    }

    override var intrinsicContentSize: NSSize {
        let first = fontLine.size(), chip = chipLine.size(), keys = keysLine.size()
        let width = max(first.width + 6 + chip.width + 12, keys.width)
        return NSSize(width: ceil(width + 2 * Self.padding.width),
                      height: ceil(max(first.height, chip.height + 2) + Self.gap + keys.height + 2 * Self.padding.height))
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        let ground = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor.windowBackgroundColor.setFill()
        ground.fill()
        NSColor.separatorColor.setStroke()
        ground.stroke()
        let first = fontLine, chip = chipLine, keys = keysLine
        let firstSize = first.size(), chipSize = chip.size()
        let pad = Self.padding
        let top = bounds.maxY - pad.height
        let lineHeight = max(firstSize.height, chipSize.height + 2)
        first.draw(at: CGPoint(x: pad.width, y: top - lineHeight + (lineHeight - firstSize.height) / 2))
        let chipRect = CGRect(x: pad.width + firstSize.width + 6, y: top - lineHeight, width: chipSize.width + 12, height: lineHeight)
        (lines.sameFont ? NSColor.systemGreen : NSColor.systemOrange).withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        chip.draw(at: CGPoint(x: chipRect.minX + 6, y: chipRect.midY - chipSize.height / 2))
        keys.draw(at: CGPoint(x: pad.width, y: pad.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
