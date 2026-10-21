import AppKit
import Combine
import Events
import PDFToolkitCore
import Sync

/// **A page as the reader sees it, and the arithmetic between that and the page's own space.**
///
/// Fill & Sign's items live in **display space**: the page's crop box turned by its rotation, y up,
/// origin at the displayed page's bottom-left corner — upright, the way the reader placed them. The
/// toolkit takes rects in PAGE space (``FillSignItem/rect``) and maps text back into display space
/// itself (`PDFToolkit.displayRect`), so text keeps the rect it was placed with; a drawn signature
/// is mapped point by point through the page's transform, so its strokes are turned here first and
/// it comes out upright on a turned page rather than lying on its side.
public struct EditorPDFPageBox: Equatable, Sendable {
    public var cropBox: CGRect
    /// 0, 90, 180 or 270 — `PDFPage.rotation`, clockwise.
    public var rotation: Int

    public init(cropBox: CGRect, rotation: Int) {
        self.cropBox = cropBox
        self.rotation = ((rotation % 360) + 360) % 360
    }

    /// The page as drawn: the crop box, its sides swapped for a quarter turn.
    public var displaySize: CGSize {
        rotation == 90 || rotation == 270 ? CGSize(width: cropBox.height, height: cropBox.width) : cropBox.size
    }

    public var displayBounds: CGRect { CGRect(origin: .zero, size: displaySize) }

    /// Page space → display space — the toolkit's `displayRect` for a bare point.
    public func displayPoint(page p: CGPoint) -> CGPoint {
        let c = cropBox
        switch rotation {
        case 90: return CGPoint(x: p.y - c.minY, y: c.maxX - p.x)
        case 180: return CGPoint(x: c.maxX - p.x, y: c.maxY - p.y)
        case 270: return CGPoint(x: c.maxY - p.y, y: p.x - c.minX)
        default: return CGPoint(x: p.x - c.minX, y: p.y - c.minY)
        }
    }

    /// Display space → page space: ``displayPoint(page:)`` undone.
    public func pagePoint(display d: CGPoint) -> CGPoint {
        let c = cropBox
        switch rotation {
        case 90: return CGPoint(x: c.maxX - d.y, y: d.x + c.minY)
        case 180: return CGPoint(x: c.maxX - d.x, y: c.maxY - d.y)
        case 270: return CGPoint(x: d.y + c.minX, y: c.maxY - d.x)
        default: return CGPoint(x: d.x + c.minX, y: d.y + c.minY)
        }
    }

    public func pageRect(display r: CGRect) -> CGRect {
        Self.spanning(pagePoint(display: CGPoint(x: r.minX, y: r.minY)), pagePoint(display: CGPoint(x: r.maxX, y: r.maxY)))
    }

    public func displayRect(page r: CGRect) -> CGRect {
        Self.spanning(displayPoint(page: CGPoint(x: r.minX, y: r.minY)), displayPoint(page: CGPoint(x: r.maxX, y: r.maxY)))
    }

    private static func spanning(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// **Strokes normalized to `display` (0…1, y down) as the toolkit wants them**: normalized to
    /// the same rect in page space. On an unturned page the two are the same numbers.
    func pageStrokes(_ strokes: [[CGPoint]], in display: CGRect) -> [[CGPoint]] {
        let page = pageRect(display: display)
        guard page.width > 0, page.height > 0 else { return strokes }
        return strokes.map { stroke in
            stroke.map { n in
                let p = pagePoint(display: CGPoint(x: display.minX + n.x * display.width,
                                                   y: display.maxY - n.y * display.height))
                return CGPoint(x: (p.x - page.minX) / page.width, y: (page.maxY - p.y) / page.height)
            }
        }
    }
}

/// The two inks the palette offers (mockup 17): a dark blue, as a pen signs, and near-black.
public enum EditorPDFFillColor: String, CaseIterable, Codable, Sendable {
    case blue
    case black

    public var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        switch self {
        case .blue: return (26 / 255, 61 / 255, 143 / 255)
        case .black: return (17 / 255, 17 / 255, 17 / 255)
        }
    }

    public var nsColor: NSColor {
        let c = components
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    /// The Ink menu's line — "Blue", under a menu that already says Ink (TE126).
    public var title: String {
        switch self {
        case .blue: return "Blue"
        case .black: return "Black"
        }
    }

    /// "Blue ink" — where nothing else on screen says Ink: the Add sheet's swatches.
    public var inkTitle: String { "\(title) ink" }
}

/// **The Mac's own handwriting faces a typed signature can take** (TE88; decision AQ, 2026-10-19:
/// built-in faces only, nothing bundled). SignPainter is left out (decision AT, 2026-10-19): on a PDF
/// with form fields a typed item is saved as a FreeText annotation, and Preview, Chrome and Acrobat
/// all drew its ligature letters ("ir", "or") garbled or not at all.
public enum EditorPDFSignatureFace: String, CaseIterable, Codable, Sendable {
    case snellRoundhand
    case savoye
    case zapfino
    case bradleyHand
    case appleChancery
    case noteworthy
    case brushScript

    public var title: String {
        switch self {
        case .snellRoundhand: return "Snell Roundhand"
        case .savoye: return "Savoye"
        case .zapfino: return "Zapfino"
        case .bradleyHand: return "Bradley Hand"
        case .appleChancery: return "Apple Chancery"
        case .noteworthy: return "Noteworthy"
        case .brushScript: return "Brush Script"
        }
    }

    public var postScriptName: String {
        switch self {
        case .snellRoundhand: return "SnellRoundhand"
        case .savoye: return "SavoyeLetPlain"
        case .zapfino: return "Zapfino"
        case .bradleyHand: return "BradleyHandITCTT-Bold"
        case .appleChancery: return "Apple-Chancery"
        case .noteworthy: return "Noteworthy-Light"
        case .brushScript: return "BrushScriptMT"
        }
    }

    var toolkit: FillSignFont { .named(postScriptName) }
}

/// **A drawn signature's pen** (TE90). Medium is the width every signature had before.
public enum EditorPDFPen: String, CaseIterable, Codable, Sendable {
    case fine
    case medium
    case bold

    public var title: String {
        switch self {
        case .fine: return "Fine"
        case .medium: return "Medium"
        case .bold: return "Bold"
        }
    }

    /// The toolkit's pen width: a fraction of the placed box's shorter side.
    public var widthFraction: CGFloat {
        switch self {
        case .fine: return 0.013
        case .medium: return FillSignSignature.defaultPenWidthFraction
        case .bold: return 0.031
        }
    }

    /// The pen's width on the Add Signature pad, in points — medium is the pad's old 2.2.
    var padWidth: CGFloat { 2.2 * widthFraction / FillSignSignature.defaultPenWidthFraction }
}

/// **The font of placed text and dates** (TE93). Serif is Charter, not New York: New York has only
/// a private system name, which a form's FreeText annotation can't carry — measured 2026-10-19, it
/// came out as Helvetica in Preview, Chrome and Acrobat. Charter came through in all three.
public enum EditorPDFTextFont: String, CaseIterable, Codable, Sendable {
    case sans
    case serif
    case rounded
    case mono
    case handwritten

    public var title: String {
        switch self {
        case .sans: return "Sans"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .mono: return "Mono"
        case .handwritten: return "Handwritten"
        }
    }

    /// `nil` is the system font, as every text item was before.
    var toolkit: FillSignFont? {
        switch self {
        case .sans: return nil
        case .serif: return .named("Charter-Roman")
        case .rounded: return .systemRounded
        case .mono: return .systemMonospaced
        case .handwritten: return .named("Noteworthy-Light")
        }
    }

    func font(size: CGFloat) -> NSFont { PDFToolkit.font(size: size, script: false, font: toolkit) }
}

/// **A signature or a set of initials** — drawn with the pointer or typed in a script face. Saved
/// ones are kept on this Mac only (``EditorPDFSignatureStore``), as pen strokes or the typed words.
public struct EditorPDFSignature: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, Identifiable {
        case signature
        case initials

        public var id: String { rawValue }
        public var title: String { self == .signature ? "Signature" : "Initials" }
    }

    public enum Look: Hashable, Codable, Sendable {
        /// Pen strokes normalized to the ink's own box — 0…1, y down — and that box's width over
        /// its height, so it is placed at the shape it was drawn.
        case drawn(strokes: [[CGPoint]], aspect: CGFloat)
        /// Words drawn in a script face (``face``).
        case typed(String)
    }

    public var id: UUID
    public var kind: Kind
    public var look: Look
    /// A typed one's face — Snell Roundhand, the one face there was, for one saved before faces.
    public var face: EditorPDFSignatureFace
    /// A drawn one's pen — Medium, the one width there was, for one saved before pens.
    public var pen: EditorPDFPen

    public init(id: UUID = UUID(), kind: Kind, look: Look, face: EditorPDFSignatureFace = .snellRoundhand,
                pen: EditorPDFPen = .medium) {
        self.id = id
        self.kind = kind
        self.look = look
        self.face = face
        self.pen = pen
    }

    private enum CodingKeys: String, CodingKey { case id, kind, look, face, pen }

    /// **Signatures saved before faces and pens decode as Snell Roundhand and Medium** — and a face
    /// this build doesn't know (a later one's) as Snell too, rather than losing every saved one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        look = try c.decode(Look.self, forKey: .look)
        face = (try? c.decodeIfPresent(EditorPDFSignatureFace.self, forKey: .face)) ?? .snellRoundhand
        pen = (try? c.decodeIfPresent(EditorPDFPen.self, forKey: .pen)) ?? .medium
    }

    /// **Strokes from the pad, in its own points (y down), fitted to their own box** — `nil` when
    /// nothing was drawn. A flat stroke (a dash, an underline) keeps a box at least a fifth as tall
    /// as it is wide, so it is not placed a hair high.
    public static func drawn(_ strokes: [[CGPoint]], kind: Kind, pen: EditorPDFPen = .medium) -> EditorPDFSignature? {
        let points = strokes.flatMap { $0 }
        guard let first = points.first else { return nil }
        var box = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        let width = max(box.width, 1)
        let height = max(box.height, width / 5, 1)
        box = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
        let normalized = strokes.filter { !$0.isEmpty }.map { stroke in
            stroke.map { CGPoint(x: ($0.x - box.minX) / box.width, y: ($0.y - box.minY) / box.height) }
        }
        return EditorPDFSignature(kind: kind, look: .drawn(strokes: normalized, aspect: width / height), pen: pen)
    }

    /// **The trackpad's wobble smoothed out** (TE91): each point averaged with its neighbours, then
    /// its corners cut once, so the pen's line runs in gentle curves. The ends stay where they were
    /// drawn, and a dot or a two-point dash is left as it is.
    public static func smoothed(_ strokes: [[CGPoint]]) -> [[CGPoint]] {
        strokes.map { stroke in
            guard stroke.count >= 3 else { return stroke }
            let reach = 3
            let averaged = stroke.indices.map { i -> CGPoint in
                if i == 0 || i == stroke.count - 1 { return stroke[i] }
                let span = max(0, i - reach)...min(stroke.count - 1, i + reach)
                let sum = stroke[span].reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                return CGPoint(x: sum.x / CGFloat(span.count), y: sum.y / CGFloat(span.count))
            }
            var cut = [averaged[0]]
            for (a, b) in zip(averaged, averaged.dropFirst()) {
                cut.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                cut.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            cut.append(averaged[averaged.count - 1])
            return cut
        }
    }

    /// **"AG" for "Abhishek Girish"** (TE94): the first letter of each word, at most three.
    public static func initials(of name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).compactMap { $0.first(where: \.isLetter) }
            .prefix(3).map { $0.uppercased() }.joined()
    }

    /// **What VoiceOver and the menus call it** (decision BD, 2026-10-20): a typed one by its words;
    /// a drawn one by its place among the drawn ones of its kind in `saved` — newest first, as the
    /// menus list them — and its pen: "Drawn signature 2, bold pen". Every drawn one was read as
    /// "Drawn signature", so two could not be told apart, in the menu or in its Delete submenu.
    public func spokenName(among saved: [EditorPDFSignature]) -> String {
        guard case .drawn = look else {
            if case .typed(let words) = look { return words }
            return kind.title
        }
        let drawn = saved.filter { $0.kind == kind && { if case .drawn = $0.look { return true }; return false }($0) }
        let word = "Drawn \(kind.title.lowercased())"
        guard let at = drawn.firstIndex(where: { $0.id == id }) else { return word }
        return "\(word) \(at + 1), \(pen.title.lowercased()) pen"
    }
}

/// One thing placed on a page with Fill & Sign — not written anywhere until Save Filled Copy.
public struct EditorPDFFillItem: Identifiable, Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// Typed text, a date, or a mark — all drawn as text, which is all the toolkit's text is.
        case text(String)
        case signature(EditorPDFSignature)
        /// New words over a patch hiding old ones (TE83).
        case correction(EditorPDFCorrection)
    }

    public let id: UUID
    /// Zero-based.
    public var page: Int
    /// In the page's display space — ``EditorPDFPageBox``.
    public var rect: CGRect
    public var content: Content
    /// Text's point size, and a typed signature's. A drawn signature is sized by its rect.
    public var fontSize: CGFloat
    public var color: EditorPDFFillColor
    /// Text's font (TE93). A typed signature's face is its signature's.
    public var font: EditorPDFTextFont

    public init(id: UUID = UUID(), page: Int, rect: CGRect, content: Content, fontSize: CGFloat,
                color: EditorPDFFillColor, font: EditorPDFTextFont = .sans) {
        self.id = id
        self.page = page
        self.rect = rect
        self.content = content
        self.fontSize = fontSize
        self.color = color
        self.font = font
    }

    /// The words this item draws, and whether in the script face — `nil` for a drawn signature.
    public var words: (string: String, script: Bool)? {
        switch content {
        case .text(let string): return (string, false)
        case .correction(let correction): return (correction.words, false)
        case .signature(let signature):
            if case .typed(let string) = signature.look { return (string, true) }
            return nil
        }
    }

    /// The face the toolkit is asked for: text's font, a typed signature's face.
    var toolkitFont: FillSignFont? {
        switch content {
        case .text: return font.toolkit
        case .signature(let signature): return signature.face.toolkit
        case .correction(let correction):
            if correction.isSameFont, let name = correction.installedFont { return .named(name) }
            return font.toolkit
        }
    }

    /// The correction this item is, or `nil`.
    public var correction: EditorPDFCorrection? {
        if case .correction(let correction) = content { return correction }
        return nil
    }

    public var isCorrection: Bool { correction != nil }

    /// **The ink the words are drawn in**: the palette's — or a correction's original, until the
    /// Ink tool chooses another.
    public var ink: EditorPDFRGB {
        if let correction, correction.keepsOriginalInk { return correction.ink }
        let c = color.components
        return EditorPDFRGB(red: c.red, green: c.green, blue: c.blue)
    }

    /// **The face this item's words are drawn in, at `size`** — the toolkit's own choice, so the
    /// screen draws what Save writes.
    func nsFont(size: CGFloat) -> NSFont {
        PDFToolkit.font(size: max(4, size), script: words?.script ?? false, font: toolkitFont)
    }

    /// A ✓, ✗ or • — text, but a mark keeps the system font: not every face has its glyph.
    public var isMark: Bool {
        if case .text(let string) = content { return EditorPDFFillMark(rawValue: string) != nil }
        return false
    }

    /// The typed signature or set of initials this item is, or `nil`.
    public var signature: EditorPDFSignature? {
        if case .signature(let signature) = content { return signature }
        return nil
    }

    public var isSignature: Bool { signature != nil }

    /// **What VoiceOver calls it**: "Check Mark", "Text, Lease ends 1 May", "Signature, Ada Quill",
    /// or a drawn one by its name among `saved` (``EditorPDFSignature/spokenName(among:)``).
    public func spokenName(among saved: [EditorPDFSignature]) -> String {
        switch content {
        case .text(let string):
            if let mark = EditorPDFFillMark(rawValue: string) { return mark.title }
            return string.isEmpty ? "Text, empty" : "Text, \(string)"
        case .correction(let correction):
            return correction.words.isEmpty ? "Correction, words removed" : "Correction, \(correction.words)"
        case .signature(let signature):
            if case .typed(let words) = signature.look { return "\(signature.kind.title), \(words)" }
            return signature.spokenName(among: saved)
        }
    }

    public var hasInk: Bool {
        switch content {
        case .text(let string): return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // The patch draws, words or none: retyped to nothing, it takes the words out.
        case .correction: return true
        case .signature(let signature):
            switch signature.look {
            case .typed(let string): return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .drawn(let strokes, _): return strokes.contains { !$0.isEmpty }
            }
        }
    }

    /// **What the toolkit draws for this item**, on a page turned as `box` says — a correction's
    /// patch first, then its words.
    public func toolkitItems(on box: EditorPDFPageBox) -> [FillSignItem] {
        guard let correction else { return [toolkitItem(on: box)] }
        let patch = FillSignItem(id: Self.patchID(id), pageIndex: page, rect: box.pageRect(display: correction.cover),
                                 content: .patch(FillSignPatch(red: correction.patch.red, green: correction.patch.green,
                                                               blue: correction.patch.blue)))
        return [patch, toolkitItem(on: box)]
    }

    /// The patch's id: the item's, its first byte turned over — the same every save.
    static func patchID(_ id: UUID) -> UUID {
        var bytes = id.uuid
        bytes.0 ^= 0xFF
        return UUID(uuid: bytes)
    }

    /// **What the toolkit draws for this item's words or strokes**, on a page turned as `box` says.
    public func toolkitItem(on box: EditorPDFPageBox) -> FillSignItem {
        let ink = self.ink
        let pageRect = box.pageRect(display: rect)
        let content: FillSignItem.Content
        switch self.content {
        case .text(let string):
            content = .text(FillSignText(string: string, fontSize: fontSize, red: ink.red, green: ink.green,
                                         blue: ink.blue, font: toolkitFont))
        case .correction(let correction):
            content = .text(FillSignText(string: correction.words, fontSize: fontSize, red: ink.red, green: ink.green,
                                         blue: ink.blue, font: toolkitFont))
        case .signature(let signature):
            switch signature.look {
            case .typed(let string):
                content = .text(FillSignText(string: string, fontSize: fontSize, red: ink.red, green: ink.green,
                                             blue: ink.blue, isScript: true, font: toolkitFont))
            case .drawn(let strokes, _):
                content = .signature(FillSignSignature(strokes: box.pageStrokes(strokes, in: rect), red: ink.red,
                                                       green: ink.green, blue: ink.blue,
                                                       penWidthFraction: signature.pen.widthFraction))
            }
        }
        return FillSignItem(id: id, pageIndex: page, rect: pageRect, content: content)
    }

    /// **The box words of `fontSize` need** in the face the toolkit draws them with. The toolkit
    /// word-wraps inside the rect and draws only what fits, so a box too small drops the end of the
    /// words (`wordsPlacedAtTheirMeasuredBoxComeOutWhole`). Measured 2026-10-18, the exact measured
    /// box already comes out whole; the room over it is for the screen — the typing field's own
    /// insets, and the selection ring kept off the glyphs.
    public static func size(of string: String, fontSize: CGFloat, script: Bool, font: FillSignFont? = nil) -> CGSize {
        let measured = measure(string, fontSize: fontSize, script: script, font: font)
        return CGSize(width: ceil(measured.width + fontSize * 0.3 + 2), height: ceil(measured.height + 1))
    }

    /// This item's words' box at `fontSize`.
    func wordsSize(fontSize: CGFloat) -> CGSize? {
        words.map { Self.size(of: $0.string, fontSize: fontSize, script: $0.script, font: toolkitFont) }
    }

    static func measure(_ string: String, fontSize: CGFloat, script: Bool, font: FillSignFont?) -> CGSize {
        let face = PDFToolkit.font(size: max(4, fontSize), script: script, font: font)
        return NSAttributedString(string: string.isEmpty ? "M" : string, attributes: [.font: face]).size()
    }

    /// **The point size that sets `string` in `face` as wide as `reference` sets it at `size`** —
    /// every face placed at one width (TE88), so Zapfino's loops don't make a bigger signature.
    static func fittedSize(_ string: String, face: EditorPDFSignatureFace, matching reference: EditorPDFSignatureFace,
                           at size: CGFloat) -> CGFloat {
        guard face != reference else { return size }
        let want = measure(string, fontSize: size, script: true, font: reference.toolkit).width
        let got = measure(string, fontSize: size, script: true, font: face.toolkit).width
        guard want > 0, got > 0 else { return size }
        return max(4, (size * want / got * 10).rounded() / 10)
    }
}

/// What the next click on a page places.
public enum EditorPDFFillTool: Equatable, Sendable {
    /// A click fills the PDF's own field under it (Phase 5c) — first in the palette, and what Fill &
    /// Sign opens on when the file has fields it can fill.
    case formFields
    case text
    /// A click picks the line of words under it to retype (TE82).
    case replace
    case date
    case mark(EditorPDFFillMark)
    case signature(EditorPDFSignature)
}

/// ✓ ✗ • — drawn as text, as the toolkit draws every word (mockup 17).
public enum EditorPDFFillMark: String, CaseIterable, Sendable {
    case check = "✓"
    case cross = "✗"
    case dot = "•"

    public var title: String {
        switch self {
        case .check: return "Check Mark"
        case .cross: return "Cross"
        case .dot: return "Dot"
        }
    }
}

/// **Saved signatures and initials — on this Mac, and only here.** Kept in the app's own defaults
/// as pen strokes or typed words; never synced, never logged.
@MainActor
public final class EditorPDFSignatureStore: ObservableObject {
    public static let key = "editorPDFSavedSignatures"
    /// The most of each kind kept; adding past it lets the oldest go — said on the Add sheet first
    /// (``isFull(_:)``, TE100).
    static let limit = 6

    @Published public private(set) var saved: [EditorPDFSignature]
    /// Where they are kept — and the Add Signature sheet's last face, pen and smoothing.
    let defaults: UserDefaults
    nonisolated(unsafe) private var change: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = Self.read(defaults)
        // **Settings ▸ Reset All Settings takes them while the app runs**, not at the next launch:
        // the list held here kept offering a removed signature to place, until a relaunch. Any
        // change to the domain is looked at; only a list that differs from the stored one moves.
        change = observeDefaultsChanges(of: defaults) { [weak self] in self?.reread() }
    }

    deinit { if let change { NotificationCenter.default.removeObserver(change) } }

    private func reread() {
        let stored = Self.read(defaults)
        if stored != saved { saved = stored }
    }

    private static func read(_ defaults: UserDefaults) -> [EditorPDFSignature] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([EditorPDFSignature].self, from: $0) } ?? []
    }

    public func saved(_ kind: EditorPDFSignature.Kind) -> [EditorPDFSignature] { saved.filter { $0.kind == kind } }

    /// Whether adding one more of `kind` lets the oldest go.
    public func isFull(_ kind: EditorPDFSignature.Kind) -> Bool { saved(kind).count >= Self.limit }

    /// Newest first. **Built on what is stored, not on what was read at launch**: Settings ▸ Reset
    /// All Settings empties the domain under a store that is already up, and the next add wrote the
    /// signatures it had just removed back with the new one.
    public func add(_ signature: EditorPDFSignature) {
        var next = [signature] + Self.read(defaults).filter { $0.id != signature.id }
        let overflow = next.filter { $0.kind == signature.kind }.dropFirst(Self.limit).map(\.id)
        next.removeAll { overflow.contains($0.id) }
        write(next)
    }

    public func delete(_ id: UUID) { write(Self.read(defaults).filter { $0.id != id }) }

    /// **A saved one restyled in place** (decision AS) — where it was in the list, under its id.
    /// One deleted meanwhile stays deleted.
    public func replace(_ signature: EditorPDFSignature) {
        write(Self.read(defaults).map { $0.id == signature.id ? signature : $0 })
    }

    /// The Add Signature sheet's last face, pen and smoothing — remembered for next time (TE88, TE90,
    /// TE91), on this Mac like the signatures.
    public static let faceKey = "editorPDFSignatureFace"
    public static let penKey = "editorPDFSignaturePen"
    public static let smoothKey = "editorPDFSignatureSmoothing"

    private func write(_ signatures: [EditorPDFSignature]) {
        saved = signatures
        if let data = try? JSONEncoder().encode(signatures) { defaults.set(data, forKey: Self.key) }
    }
}

/// **Fill & Sign: the items placed on the open PDF, and the palette's state** (mockups 17, 18 and
/// F). A sibling of ``EditorPDFTools`` on ``EditorPDFDocument``, observed by the palette, the save
/// pill, the header's button and the page view's overlay.
///
/// **Nothing is written until Save Filled Copy**, which is a tool run like any other —
/// ``EditorPDFTool/fillAndSign(_:)`` through ``EditorPDFTools/run(_:bannerFailures:)`` — so the copy
/// is named, written and reported by the one rule every tool follows, and the open file stays
/// exactly as it was. Placing, moving and deleting are undone with ⌘Z on this object's own stack
/// (``undoManager``), never the window's, which holds the file operations'.
@MainActor
public final class EditorPDFFillSign: ObservableObject {

    /// Whether the palette is up.
    @Published public private(set) var isOn = false
    @Published public private(set) var items: [EditorPDFFillItem] = []
    @Published public var selection: UUID?
    /// What the next click places, or `nil`.
    @Published public var armed: EditorPDFFillTool? {
        didSet { if armed != .replace { replaceNote = nil } }
    }
    /// **Why the last click with Replace picked nothing** (TE87) — said in the note card until the
    /// next pick, or another tool.
    @Published public private(set) var replaceNote: String?
    /// **The pages to save as pictures** (TE85, decision AK): the words corrections cover there go
    /// from the copy, and so does every other word's text on the page.
    @Published public private(set) var pictures: Set<Int> = []
    /// The item whose words are being typed, or `nil`.
    @Published public private(set) var editing: UUID?
    /// The Add Signature sheet, for signatures or for initials.
    @Published public var addingSignature: EditorPDFSignature.Kind? {
        // The sheet put away without Add: the field it was opened from is no longer being signed.
        // And File ▸ PDF Tools, which observes only the tools, greys under this sheet
        // (`EditorPDFToolsMenuEntry.entries`) — so the tools are told it moved.
        didSet {
            if addingSignature == nil { signing = nil }
            if (oldValue == nil) != (addingSignature == nil) { tools?.objectWillChange.send() }
        }
    }
    /// **The signature field being signed** (TE107): where the signature chosen from its menu — or
    /// added on the sheet it opened — is placed, instead of arming the Signature tool.
    @Published public var signing: SigningTarget?
    /// What the next item is drawn in, and what A− / A+ and the inks last chose.
    @Published public private(set) var color: EditorPDFFillColor = .blue
    @Published public private(set) var fontSize: CGFloat = EditorPDFFillSign.defaultFontSize
    /// The next text's font, and what the Aa tool last chose for text (TE93).
    @Published public private(set) var textFont: EditorPDFTextFont = .sans
    /// Why Fill & Sign is off for this file, or `nil` — said when its button is pressed.
    @Published public private(set) var refusal: String?

    // MARK: The PDF's own form (Phase 5c)

    /// The file's fields, read in the lane with the facts — ``EditorPDFForm/none`` for a flat file.
    @Published public private(set) var form = EditorPDFForm.none
    /// **The values typed into the form's fields and not yet saved**, by fully qualified name —
    /// only those that differ from the file's own. Draft state: nothing reaches the reader's
    /// document or the file until Save Filled Copy hands them to `fillFormData`.
    @Published public private(set) var values: [String: FormFieldValue] = [:]
    /// The field the keyboard is on — Tab and ⇧Tab move it, Space and Return act on it.
    @Published public private(set) var focusedField: String?
    /// The text field being typed into, or `nil`.
    @Published public private(set) var editingField: String?
    /// The file's owner permissions, apart: form entry lets its fields be filled, commenting lets
    /// text and signatures be placed on its pages (``EditorPDFFacts/allowsFormEntry``).
    @Published public private(set) var allowsFormEntry = true
    @Published public private(set) var allowsCommenting = true

    public let store: EditorPDFSignatureStore
    /// Placing, moving, deleting — undone with ⌘Z while the pages have the keyboard.
    public let undoManager = UndoManager()
    /// The run that writes the copy. Set by the document.
    weak var tools: EditorPDFTools?

    private(set) var path: String?
    /// Each page's crop box and rotation, read in the lane with the facts.
    private(set) var boxes: [EditorPDFPageBox] = []
    /// The items before a drag or a typing session began — what its one undo step restores.
    private var gestureBefore: [EditorPDFFillItem]?
    private var editBefore: [EditorPDFFillItem]?
    /// The values before a field's typing began — what its one undo step restores.
    private var fieldEditBefore: [String: FormFieldValue]?

    var today: () -> Date = Date.init
    /// Today in the Mac's short date format — "17/10/2026" here, "10/17/26" in the US.
    var formatDate: (Date) -> String = { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .none) }
    /// Puts a refusal to the reader — an alert in the app, recorded in a test.
    var presentRefusal: @MainActor (String) -> Void = { EditorPDFFillSign.alertRefusal($0) }
    /// Asks what to do with unsaved items — an alert in the app, a canned answer in a test. `count`
    /// is the items placed and the fields changed together.
    lazy var askLeaving: @MainActor (_ name: String, _ count: Int) -> LeaveAnswer = { [unowned self] name, count in
        EditorPDFFillSign.alertLeaving(name: name, count: count, fields: self.values.count,
                                       corrected: self.onlyCorrections)
    }

    public enum LeaveAnswer: Sendable { case save, discard, cancel }

    /// Asks before a saved signature is deleted — an alert in the app, a canned answer in a test.
    public var confirmDeletingSaved: @MainActor (_ signature: EditorPDFSignature, _ name: String) -> Bool = { signature, name in
        EditorPDFFillSign.deleteSavedAlert(signature, name: name).runModal() == .alertSecondButtonReturn
    }

    static let defaultFontSize: CGFloat = 12
    static let fontSizes: [CGFloat] = [6, 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 72]
    /// A drawn signature's width when placed, and initials', in page points.
    static let signatureWidth: CGFloat = 150
    static let initialsWidth: CGFloat = 54
    /// A typed signature's point size when placed, and typed initials' — in Snell Roundhand; every
    /// other face is placed at the width Snell would take (TE88).
    static let signatureFontSize: CGFloat = 28
    static let initialsFontSize: CGFloat = 20

    public init(store: EditorPDFSignatureStore) {
        self.store = store
        // **One step per change, grouped here** rather than by the run loop's event: a placement and
        // the drag that follows it in one pass — a test's, or a synthesized event's — were one step.
        undoManager.groupsByEvent = false
    }

    // MARK: The file

    /// `allowsFilling` is the file's own permissions — read in the lane with the facts — and `form`,
    /// `allowsFormEntry` and `allowsCommenting` its form and the permissions' two halves (5c).
    func attach(path: String, boxes: [EditorPDFPageBox], encryption: PDFEncryptionState, allowsFilling: Bool,
                form: EditorPDFForm = .none, allowsFormEntry: Bool = true, allowsCommenting: Bool = true) {
        let reloaded = self.path == path
        // **What there was before either drop below**, for the one banner that says it all: a
        // reload that changed both the form and the pages cleared the fields first, and the items'
        // banner then said only "the items you placed" over the fields' own. What the pill counts —
        // a text box opened and left empty is no lost work.
        let filledBefore = values.count, placedBefore = unsaved.count
        if self.path == path, boxes != self.boxes || form != self.form {
            // **The undo steps go with the pages and the form they were taken on** — with nothing
            // to drop now as well. A Discard, or a placement undone, left steps that ⌘Z then played
            // back onto pages that had changed: counted as unsaved, drawn nowhere, and left out of
            // the copy without a word.
            undoManager.removeAllActions()
        }
        if self.path == path, form != self.form, !values.isEmpty {
            // **A reload whose form is no longer the one the values were typed into** — a field
            // renamed, a value changed elsewhere. Said, as the items' drop is.
            Logger.shared.info("Edit dropped \(Self.fields(values.count)) filled with Fill & Sign on "
                               + "\(EditorPDFTools.logName(path)) — the file changed on disk")
            values = [:]
            focusedField = nil
            editingField = nil
            fieldEditBefore = nil
            undoManager.removeAllActions()
            tools?.banner = EditorPDFToolBanner(message: "The file changed on disk, so the fields you filled were cleared.",
                                                kind: .note)
        }
        if self.path == path, boxes != self.boxes, !items.isEmpty {
            // **A reload whose pages are no longer the ones the items were placed on.** A file that
            // changed but kept every page as it was keeps its items.
            // `clear()` takes the filled fields too, so the log and the banner name them as well.
            let lost = [placedBefore > 0 ? "\(Self.count(placedBefore)) placed" : nil,
                        values.isEmpty ? nil : "\(Self.fields(values.count)) filled"].compactMap { $0 }
            if !lost.isEmpty {
                Logger.shared.info("Edit dropped \(lost.joined(separator: " and ")) with Fill & Sign on "
                                   + "\(EditorPDFTools.logName(path)) — the file changed on disk")
            }
            clear()
            switch (placedBefore > 0, filledBefore > 0) {
            case (true, true):
                tools?.banner = EditorPDFToolBanner(
                    message: "The file changed on disk, so the items you placed and the fields you filled were cleared.",
                    kind: .note)
            case (true, false):
                tools?.banner = EditorPDFToolBanner(
                    message: "The file changed on disk, so the items you placed were dropped.", kind: .note)
            case (false, true):
                // The pages changed and the form did not: `clear()` took the fields all the same.
                tools?.banner = EditorPDFToolBanner(
                    message: "The file changed on disk, so the fields you filled were cleared.", kind: .note)
            case (false, false):
                // Only an empty text box went — no work.
                break
            }
        } else if self.path != path {
            clear()
            isOn = false
        }
        self.path = path
        self.boxes = boxes
        self.form = form
        self.allowsFormEntry = allowsFormEntry
        self.allowsCommenting = allowsCommenting
        // An owner who forbids commenting gets no placed items, form or not: a file with no form
        // allowed only "form entry" has nothing that permission covers, and took items flattened
        // into an unrestricted copy — the inconsistency `nothingToFillReason` closed for forms.
        refusal = Self.refusal(encryption: encryption, allowsFilling: allowsFilling)
            ?? (!allowsCommenting && !offersFormFields
                ? (form.hasFields ? Self.nothingToFillReason : Self.restrictedReason) : nil)
        if refusal != nil, reloaded, let lost = unsavedWork {
            // **A reload that now refuses the file takes what was placed.** The palette and the
            // pill go with `isOn`, and the overlay draws only while on, so the items were kept out
            // of sight — yet File ▸ Save Filled Copy and the leave question could still flatten them
            // into a copy of a file whose owner now forbids it.
            Logger.shared.info("Edit dropped \(lost) with Fill & Sign on \(EditorPDFTools.logName(path)) — "
                               + "the file changed on disk and no longer allows it")
            clear()
            tools?.banner = EditorPDFToolBanner(
                message: "The file changed on disk and no longer allows filling, so Fill & Sign’s unsaved work — \(lost) — was dropped.",
                kind: .note)
        }
        if refusal == nil, reloaded, form.hasFields, items.contains(where: \.isCorrection) {
            // **A reload that now has a form takes the corrections** (decision AV): Replace is off
            // on a form, so the save refused them every time, and only Discard got out.
            let corrections = items.filter(\.isCorrection).count
            Logger.shared.info("Edit dropped \(corrections == 1 ? "1 correction" : "\(corrections) corrections") with "
                               + "Fill & Sign on \(EditorPDFTools.logName(path)) — the file changed on disk and now has a fillable form")
            if let editing, items.contains(where: { $0.id == editing && $0.isCorrection }) {
                self.editing = nil
                editBefore = nil
            }
            items.removeAll(where: \.isCorrection)
            if let selection, !items.contains(where: { $0.id == selection }) { self.selection = nil }
            undoManager.removeAllActions()
            tools?.banner = EditorPDFToolBanner(
                message: "The file changed on disk and now has a fillable form, so your corrections were dropped.",
                kind: .note)
        }
        if refusal != nil { isOn = false }
    }

    /// What a ``detach()`` now would throw away — "2 items and 1 field" — or `nil` with nothing
    /// unsaved: the words for the banner when the file goes from under the reader.
    var unsavedWork: String? {
        // What the pill counts: an item with nothing in it yet — text box just opened — is not work.
        let parts = placedParts + (values.isEmpty ? [] : [Self.fields(values.count)])
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }

    func detach() {
        if let path, !unsaved.isEmpty {
            Logger.shared.info("Edit discarded \(Self.count(unsaved.count)) placed with Fill & Sign on "
                               + "\(EditorPDFTools.logName(path)) — the file was closed")
        }
        if let path, !values.isEmpty {
            Logger.shared.info("Edit discarded \(Self.fields(values.count)) filled with Fill & Sign on "
                               + "\(EditorPDFTools.logName(path)) — the file was closed")
        }
        clear()
        isOn = false
        path = nil
        boxes = []
        refusal = nil
        form = .none
        allowsFormEntry = true
        allowsCommenting = true
    }

    private func clear() {
        items = []
        pictures = []
        replaceNote = nil
        selection = nil
        editing = nil
        armed = nil
        addingSignature = nil
        signing = nil
        gestureBefore = nil
        editBefore = nil
        values = [:]
        focusedField = nil
        editingField = nil
        fieldEditBefore = nil
        undoManager.removeAllActions()
    }

    static let restrictedTitle = "This PDF doesn’t allow filling"
    /// **A form whose owner forbids commenting and has no field that can be filled** — every field
    /// read-only or a signature. Placed items would have to be flattened into the pages, against the
    /// owner's "no commenting", and a form with a fillable field already refuses them for exactly
    /// that; this used to be the one form where they were taken (his call, 2026-10-18, to match).
    static let nothingToFillReason = "Its owner doesn’t allow adding text or signatures to its pages, and its form "
        + "has no field that can be filled."
    static let restrictedReason = "Its owner restricted editing, so Fill & Sign is off for it. Tools ▸ Remove Password… "
        + "can write an unrestricted copy if you know the password."

    /// A file locked to open is opened by URL in the lane, where unlocking the reader's copy does
    /// not reach — so it is refused for the tools' reason. One whose owner forbade both comments
    /// and form filling is refused for its owner's.
    static func refusal(encryption: PDFEncryptionState, allowsFilling: Bool) -> String? {
        if encryption == .lockedToOpen { return EditorPDFTools.lockedReason }
        return allowsFilling ? nil : restrictedReason
    }

    // MARK: On and off

    /// The header's button. On arms Text (mockup 17); off with unsaved items asks first.
    public func toggle() {
        guard mayToggle else { return }
        if isOn {
            guard mayLeave() else { return }
            clear()
            isOn = false
            return
        }
        if let refusal {
            presentRefusal(refusal)
            return
        }
        guard hasPages else { return }
        isOn = true
        // A file with fields it can fill opens on them (mockup 19); any other on Text, as in 5b.
        armed = offersFormFields ? .formFields : .text
    }

    /// A file with pages to place on — what ``toggle()`` needs to turn on, and what File ▸ Fill &
    /// Sign is greyed without.
    var hasPages: Bool { path != nil && !boxes.isEmpty }

    /// **Not off while a tool run is writing** — Save Filled Copy's own, most of all. Turning it off
    /// then asked whether to save the items being saved: Save was refused as "still running", and
    /// Discard cleared what the copy was taking. The button and File ▸ Fill & Sign grey with it.
    public var mayToggle: Bool { !(isOn && tools?.running != nil) }

    /// **The refusal as a menu line** — the alert's own title for an owner's restriction, whose
    /// reason is two sentences; the tools' short reason for a file locked to open, which File ▸ PDF
    /// Tools already shows as a line.
    var menuReason: String? {
        refusal.map { $0 == Self.restrictedReason || $0 == Self.nothingToFillReason ? Self.restrictedTitle : $0 }
    }

    /// **Esc: stops typing, then lets go of the selection, then of the tool — and with nothing left
    /// to let go of, puts Fill & Sign away** (TE98) through ``toggle()``, which asks about unsaved
    /// work. `first` is the reader's own Esc, tried before that last step: an open find card closes
    /// before the palette goes.
    @discardableResult
    public func escape(first: () -> Bool = { false }) -> Bool {
        if editingField != nil { endFieldEditing(); return true }
        if focusedField != nil { focusedField = nil; return true }
        if editing != nil { endEditing(); return true }
        if selection != nil { selection = nil; return true }
        if armed != nil { armed = nil; return true }
        if first() { return true }
        guard isOn else { return false }
        toggle()
        return true
    }

    // MARK: Counting

    /// The items that would draw something — what Save Filled Copy writes and the save pill counts.
    public var unsaved: [EditorPDFFillItem] { items.filter(\.hasInk) }
    public var hasUnsavedItems: Bool { !unsaved.isEmpty }

    /// Items placed or fields changed — what Save Filled Copy writes and a leave asks about.
    public var hasUnsavedChanges: Bool { hasUnsavedItems || !values.isEmpty }

    /// "4 items not saved" — the save pill's words while Fill & Sign holds some — and with a form,
    /// "2 fields changed" (mockup 19), or both.
    public var unsavedCaption: String? {
        let n = unsaved.count, f = values.count
        switch (f, n) {
        case (0, 0): return nil
        case (0, _): return "\(placed) not saved"
        case (_, 0): return "\(Self.fields(f)) changed"
        default: return "\(Self.fields(f)) changed · \(placed) not saved"
        }
    }

    /// The same, shorter, for a pill with less room — "2 fields · 1 item".
    public var unsavedShortCaption: String? {
        let f = values.count
        let parts = (f == 0 ? [] : [Self.fields(f)]) + placedParts
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2 items", "1 correction", "2 items and 1 correction" — what is placed, corrections apart (TE84).
    private var placed: String { placedParts.joined(separator: " and ") }

    private var placedParts: [String] {
        let corrections = unsaved.filter(\.isCorrection).count, others = unsaved.count - corrections
        return (others == 0 ? [] : [Self.count(others)]) + (corrections == 0 ? [] : [Self.corrections(corrections)])
    }

    /// **Only corrections to save** — the pill's button says Save Corrected Copy, and the copy is
    /// named "(corrected)" (TE84).
    public var onlyCorrections: Bool { values.isEmpty && !unsaved.isEmpty && unsaved.allSatisfy(\.isCorrection) }

    /// The save pill's button.
    public var saveTitle: String { onlyCorrections ? "Save Corrected Copy" : "Save Filled Copy" }

    nonisolated static func count(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }
    nonisolated static func corrections(_ n: Int) -> String { n == 1 ? "1 correction" : "\(n) corrections" }
    nonisolated static func fields(_ n: Int) -> String { n == 1 ? "1 field" : "\(n) fields" }

    // MARK: Placing

    public func box(_ page: Int) -> EditorPDFPageBox? { boxes.indices.contains(page) ? boxes[page] : nil }

    /// **The armed tool's item, at `point` in the display space of `page`.** Text starts at the
    /// click, the way a caret lands, and is typed straight away; a mark or a signature is centred
    /// on it. Text, dates and marks stay chosen for the next click; a signature is placed once.
    @discardableResult
    public func place(at point: CGPoint, page: Int) -> UUID? {
        guard isOn, let armed, let box = box(page) else { return nil }
        // The owner allows the form but not marks on its pages: nothing is placed (5c).
        guard armed == .formFields || offersPlacing else { return nil }
        endEditing()
        endFieldEditing()
        guard let (made, name) = armedItem(page: page) else { return nil }
        var item = made
        let extent = Self.extent(of: item)
        item.rect = Self.placedRect(extent: extent, at: point, caret: armed == .text, in: box)
        if case .text = armed {
            // Placed for typing: its undo step is taken when the typing ends, and an item left
            // empty goes as though it was never placed.
            editBefore = items
            items.append(item)
            editing = item.id
        } else {
            change(name) { $0.append(item) }
            if case .signature = armed { self.armed = nil }
        }
        selection = item.id
        lastPlaced = item.id
        return item.id
    }

    /// **The item placed last, while it is still the one selected by placing it** — Return on it
    /// places another rather than typing into it (decision BA). Let go by a click or Tab onto any item.
    public private(set) var lastPlaced: UUID?

    /// Where an item of `extent` goes for a point on the page: text from the point, as a caret
    /// lands; anything else centred on it — kept on the page.
    static func placedRect(extent: CGSize, at point: CGPoint, caret: Bool, in box: EditorPDFPageBox) -> CGRect {
        let origin = caret ? CGPoint(x: point.x - 2, y: point.y - extent.height / 2)
                           : CGPoint(x: point.x - extent.width / 2, y: point.y - extent.height / 2)
        return FillSignGeometry.clamped(CGRect(origin: origin, size: extent), in: box.displayBounds)
    }

    /// **Return with a tool chosen** (decision BA, 2026-10-20): the item at `center` — the middle of
    /// what can be seen of `page`, which the overlay works out — selected, so the arrows move it and
    /// a text box takes the typing. **Not on top of one already there**: it goes just below what it
    /// would cover, and below that, so a second Return with Date still chosen is seen as a second date.
    @discardableResult
    public func placeFromKeyboard(around center: CGPoint, page: Int) -> UUID? {
        guard isOn, let armed, armed != .formFields, offersPlacing, let box = box(page),
              let (item, _) = armedItem(page: page) else { return nil }
        endEditing()
        let extent = Self.extent(of: item)
        var point = center
        for _ in 0..<64 {
            let rect = Self.placedRect(extent: extent, at: point, caret: armed == .text, in: box)
            guard let covered = items.filter({ $0.page == page && $0.rect.intersects(rect) })
                    .min(by: { $0.rect.minY < $1.rect.minY }) else { break }
            // Display space runs up the page: below is a smaller y.
            let next = covered.rect.minY - Self.keyboardGap - extent.height / 2
            guard next < point.y - 0.5, next - extent.height / 2 >= box.displayBounds.minY else { break }
            point.y = next
        }
        return place(at: point, page: page)
    }

    /// The room between an item placed from the keyboard and the one it would have covered.
    static let keyboardGap: CGFloat = 4

    /// The armed tool's item, not yet anywhere, and its undo name.
    private func armedItem(page: Int) -> (EditorPDFFillItem, String)? {
        guard let armed else { return nil }
        let content: EditorPDFFillItem.Content
        var size: CGFloat = fontSize
        var font = textFont
        let name: String
        switch armed {
        case .formFields, .replace:
            // Fields are filled, not placed on: the overlay sends a click on one to it. Replace
            // picks words, through ``beginCorrection(_:)``.
            return nil
        case .text:
            content = .text("")
            name = "Place Text"
        case .date:
            content = .text(formatDate(today()))
            name = "Place Date"
        case .mark(let mark):
            content = .text(mark.rawValue)
            font = .sans
            name = "Place Mark"
        case .signature(let signature):
            content = .signature(signature)
            if case .typed(let words) = signature.look {
                size = EditorPDFFillItem.fittedSize(
                    words, face: signature.face, matching: .snellRoundhand,
                    at: signature.kind == .signature ? Self.signatureFontSize : Self.initialsFontSize)
            }
            name = "Place \(signature.kind.title)"
        }
        return (EditorPDFFillItem(page: page, rect: .zero, content: content, fontSize: size, color: color, font: font), name)
    }

    // MARK: Signing a form's signature field (TE107)

    /// A form's signature field, in the display space of its page — where its signature goes.
    public struct SigningTarget: Equatable, Sendable {
        public var page: Int
        public var rect: CGRect
    }

    /// **Whether a click on `field` signs it**: a signature field, on a file whose owner lets
    /// signatures be placed on its pages.
    public func signs(_ field: FormField) -> Bool { isOn && field.kind == .signature && offersPlacing }

    /// The box a signature put in `widget` fills, or `nil` for a page the file doesn't have.
    public func signingTarget(for widget: FormField.Widget) -> SigningTarget? {
        box(widget.pageIndex).map { SigningTarget(page: widget.pageIndex, rect: $0.displayRect(page: widget.rect)) }
    }

    /// **`signature` placed in a signature field** — as big as the field's box takes it, keeping its
    /// shape, at the box's left edge and centred on its height. An ordinary item from then on: it
    /// moves, resizes and deletes as one placed with the Signature tool does.
    @discardableResult
    public func place(_ signature: EditorPDFSignature, in target: SigningTarget) -> UUID? {
        guard isOn, offersPlacing, let box = box(target.page), target.rect.width > 0, target.rect.height > 0 else {
            return nil
        }
        endEditing()
        endFieldEditing()
        let field = target.rect
        var item = EditorPDFFillItem(page: target.page, rect: .zero, content: .signature(signature),
                                     fontSize: Self.signatureFontSize, color: color)
        let size: CGSize
        switch signature.look {
        case .typed:
            item.fontSize = Self.fittedFontSize(of: item, in: field.size)
            size = item.wordsSize(fontSize: item.fontSize) ?? field.size
        case .drawn(_, let aspect):
            let shape = max(aspect, 0.2)
            let width = min(field.width, field.height * shape)
            size = CGSize(width: width, height: width / shape)
        }
        item.rect = FillSignGeometry.clamped(CGRect(x: field.minX, y: field.midY - size.height / 2,
                                                    width: size.width, height: size.height), in: box.displayBounds)
        change("Place \(signature.kind.title)") { $0.append(item) }
        selection = item.id
        return item.id
    }

    /// The largest point size, in half points, whose words' box fits inside `room` — at least 4,
    /// the smallest the words are drawn.
    static func fittedFontSize(of item: EditorPDFFillItem, in room: CGSize) -> CGFloat {
        guard let unit = item.wordsSize(fontSize: 10), unit.width > 0, unit.height > 0 else { return item.fontSize }
        var size = max(4, (10 * min(room.width / unit.width, room.height / unit.height) * 2).rounded(.down) / 2)
        while size > 4, let box = item.wordsSize(fontSize: size), box.width > room.width || box.height > room.height {
            size -= 0.5
        }
        return min(size, fontSizes.last!)
    }

    /// The size an item takes: its words' box, or a drawn signature at its placing width.
    static func extent(of item: EditorPDFFillItem) -> CGSize {
        if let size = item.wordsSize(fontSize: item.fontSize) { return size }
        guard case .signature(let signature) = item.content, case .drawn(_, let aspect) = signature.look else {
            return item.rect.size
        }
        let width = signature.kind == .signature ? signatureWidth : initialsWidth
        let natural = CGSize(width: width, height: width / max(aspect, 0.2))
        // **A tall, narrow drawing keeps its shape, no taller than the box is wide** — initials
        // drawn as one upright stroke came out 54 × 270 pt, a signature 150 × 750, most of a page.
        guard natural.height > width else { return natural }
        return CGSize(width: width * width / natural.height, height: width)
    }

    // MARK: Typing

    /// Starts typing into a placed text item — a double-click.
    public func beginEditing(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if case .signature = item.content { return }
        endEditing()
        // **One thing types at a time**: a form field left typing took the keyboard straight back,
        // and the text box closed as it opened.
        endFieldEditing()
        focusedField = nil
        editBefore = items
        editing = id
        selection = id
    }

    /// The words as typed, every keystroke — the box grows with them. No undo step per key: the
    /// whole session is one, taken by ``endEditing()``.
    public func type(_ string: String, into id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].content {
        case .text: items[index].content = .text(string)
        case .correction(var correction):
            correction.words = string
            items[index].content = .correction(correction)
        case .signature: return
        }
        resizeToWords(index)
    }

    /// Ends the typing: one undo step for it, and an item left empty is removed.
    public func endEditing() {
        guard let id = editing else { return }
        editing = nil
        let wasNew = editBefore.map { before in !before.contains { $0.id == id } } ?? false
        if let index = items.firstIndex(where: { $0.id == id }) {
            // A correction placed with its words as they were changes nothing: it goes, as Esc's would.
            let unchanged = items[index].correction.map { wasNew && $0.words == $0.covered } ?? false
            if !items[index].hasInk || unchanged {
                items.remove(at: index)
                if selection == id { selection = nil }
            }
        }
        guard let before = editBefore else { return }
        editBefore = nil
        let correcting = (items + before).contains { $0.id == id && $0.isCorrection }
        let placed = correcting ? "Replace Text" : "Place Text"
        if items != before { register(before, wasNew ? placed : items.contains { $0.id == id } ? "Typing" : "Delete") }
    }

    /// **Esc in a correction's retype box**: the page as it was before the box opened — a new
    /// correction goes, one being retyped keeps its words. Text's Esc keeps what was typed
    /// (``endEditing()``).
    public func cancelEditing() {
        guard let id = editing else { return }
        guard items.first(where: { $0.id == id })?.isCorrection == true, let before = editBefore else {
            endEditing()
            return
        }
        editing = nil
        editBefore = nil
        items = before
        if !items.contains(where: { $0.id == id }) { selection = nil }
    }

    // MARK: Replace (TE82–TE87)

    /// **Why Replace is off for this file**, or `nil` (TE87): Fill & Sign's own refusal, an owner who
    /// forbids adding to the pages, or a fillable form — where Fill & Sign keeps what is placed as
    /// notes another app can delete, so a correction would peel off (decision AV, 2026-10-20).
    public var replaceRefusal: String? {
        if let refusal { return refusal }
        if form.hasFields { return Self.formReplaceReason }
        if !offersPlacing { return Self.noCommentingReason + "." }
        return nil
    }

    static let formReplaceReason = "This PDF has a fillable form. Corrections would be saved as notes another app "
        + "can delete, so Replace is off here."

    /// **The words a click or a right-click picked, opened for retyping** (TE83): a box exactly
    /// over them, holding them, in their size and ink — and their font when this Mac has it. Return
    /// places the correction, Esc leaves the page as it was; the two are one undo step.
    @discardableResult
    public func beginCorrection(_ pick: EditorPDFReplacePick) -> UUID? {
        guard isOn, replaceRefusal == nil, let box = box(pick.page) else { return nil }
        endEditing()
        endFieldEditing()
        replaceNote = nil
        // Words already corrected open their correction again, rather than a second patch on the
        // first — on the same line: a cover a font's full height tall reaches the next line in
        // single-spaced text, and that line is words of its own.
        if let existing = items.first(where: { item in
            guard item.page == pick.page, let correction = item.correction else { return false }
            return abs(correction.baseline - pick.baseline) < max(1, pick.fontSize / 2)
                && correction.cover.minX < pick.wordsRect.maxX && pick.wordsRect.minX < correction.cover.maxX
        }) {
            beginEditing(existing.id)
            return existing.id
        }
        var item = EditorPDFFillItem(page: pick.page, rect: pick.wordsRect, content: .correction(EditorPDFCorrection(pick)),
                                     fontSize: pick.fontSize, color: color, font: pick.standIn)
        Self.resizeToWords(&item, in: box)
        editBefore = items
        items.append(item)
        editing = item.id
        selection = item.id
        return item.id
    }

    /// A click with Replace that picked nothing, and why — said in the note card.
    public func refuseReplace(_ refusal: EditorPDFReplaceRefusal) {
        replaceNote = refusal.reason
    }

    /// **Return with Replace chosen and nothing to retype**: Replace has no spot of its own to use,
    /// as the other tools do — it needs the words — so the note card says how to pick them.
    public func explainReplaceFromKeyboard() {
        replaceNote = Self.replaceByKeyboardNote
    }

    static let replaceByKeyboardNote = "Click or drag across the words to replace."

    /// **Right-click ▸ Replace Text…**: Fill & Sign on, with Replace chosen and these words picked.
    public func replace(_ pick: EditorPDFReplacePick) {
        guard replaceRefusal == nil, hasPages else { return }
        if !isOn { isOn = true }
        armed = .replace
        beginCorrection(pick)
    }

    /// The pages that carry a correction not yet saved, in order.
    public var correctedPages: [Int] { Array(Set(unsaved.filter(\.isCorrection).map(\.page))).sorted() }

    /// **The note card's lines for the corrections** (TE85): per page, the covered words are still in
    /// the copy, with the button that makes the page a picture — or, once chosen, that it will be one.
    public var correctionNotes: [EditorPDFCorrectionNote] {
        correctedPages.map { page in
            let number = page + 1
            if pictures.contains(page) {
                return EditorPDFCorrectionNote(
                    page: page,
                    line: "Page \(number) will be saved as a picture, so the words you covered are gone from the copy, "
                        + "and its text can’t be searched or copied.",
                    button: "Keep Page \(number) as Text", pictured: true)
            }
            let corrections = unsaved.compactMap { $0.page == page ? $0.correction : nil }
            if corrections.count == 1 {
                return EditorPDFCorrectionNote(
                    page: page,
                    line: "“\(Self.quoted(corrections[0].covered))” is still in the copy, under the patch. Search and copy will find it.",
                    button: "Remove It: Make Page \(number) a Picture", pictured: false)
            }
            return EditorPDFCorrectionNote(
                page: page,
                line: "The \(corrections.count) passages you covered on page \(number) are still in the copy, under their patches. "
                    + "Search and copy will find them.",
                button: "Remove Them: Make Page \(number) a Picture", pictured: false)
        }
    }

    /// Words quoted in a note: a long passage is cut.
    static func quoted(_ words: String) -> String { words.count > 40 ? String(words.prefix(40)) + "…" : words }

    /// **The note card's warnings for Replace**: why the last click picked nothing, and a patch on a
    /// ground that isn't plain.
    public var replaceNotes: [String] {
        var out: [String] = []
        if let replaceNote { out.append(replaceNote) }
        if unsaved.contains(where: { $0.correction.map { !$0.plainBackground } ?? false }) {
            out.append(Self.patternedNote)
        }
        return out
    }

    static let patternedNote = "The background here isn’t plain, so the patch will show."

    /// **The note card's button**: a page to save as a picture, or back as text — one undo step.
    public func setPicture(_ page: Int, _ on: Bool) {
        guard on != pictures.contains(page) else { return }
        let before = pictures
        if on { pictures.insert(page) } else { pictures.remove(page) }
        register(items, values, before, on ? "Make Page a Picture" : "Keep Page as Text")
    }

    /// The pages saved as pictures: those chosen that still carry a correction.
    var picturesToSave: [Int] { pictures.intersection(correctedPages).sorted() }

    // MARK: Form fields (Phase 5c)

    /// Why the form's fields can't be filled here: the owner allows comments on the pages, not entry
    /// into the form.
    nonisolated static let noFormEntryReason = "This PDF’s owner doesn’t allow filling its form"
    /// Why nothing can be placed on a form whose owner allows filling it but not commenting.
    static let noCommentingReason = "This PDF’s owner allows filling its form but not adding text or signatures to its pages"
    static let xfaNote = "This form also carries XFA data, so Acrobat may show different values than other apps."

    /// Whether the Form Fields tool is offered: the file has a field that can be filled, and its
    /// owner allows entry into the form.
    public var offersFormFields: Bool { allowsFormEntry && !form.fillable.isEmpty }
    /// Whether Text, Date, the marks and the signatures are offered. A form's copy keeps them as
    /// annotations, which an owner who forbids commenting forbids; a flat file's copy draws them
    /// into the page, as 5b always has.
    public var offersPlacing: Bool { !usesFormPath || allowsCommenting }

    /// **Whether Save fills the form in place (`fillFormData`) rather than flattening (5b's
    /// `fillAndSignData`)**: a file with fields, where the in-place fill can carry something — a
    /// field to fill, or items its owner lets it keep as annotations. A form with neither — every
    /// field read-only or a signature, and commenting forbidden — is refused at `attach`
    /// (``nothingToFillReason``): flattening was the one way anything could be placed on it, and it
    /// went against the same "no commenting" a fillable form's refusal honours.
    public var usesFormPath: Bool { form.hasFields && (offersFormFields || allowsCommenting) }

    /// The note card's lines, under the save pill while the palette is up (Phase 6b, decided
    /// 2026-10-19): what Save would refuse, said as the reader types rather than after Save — then
    /// the file's own caveats.
    public var formNotes: [String] {
        var out: [String] = []
        if let formProblem, !Self.isNothingYet(formProblem) {
            out.append(EditorPDFToolEngine.reason(formProblem, tool: .fillForm(values: values, items: [])))
        }
        guard usesFormPath else { return out }
        if !offersPlacing { out.append(Self.noCommentingReason + ".") }
        if !allowsFormEntry, !form.fillable.isEmpty { out.append(Self.noFormEntryReason + ".") }
        if form.hasXFA { out.append(Self.xfaNote) }
        return out
    }

    /// Nothing typed or placed yet: not a problem to warn about, just nothing to save.
    static func isNothingYet(_ problem: PDFOperationError) -> Bool {
        if case .noFormValues = problem { return true }
        return false
    }

    /// **What `fillFormData` would refuse in the values and items as they stand**, or `nil` — the
    /// toolkit's own checks, run here so Save never surprises (``EditorPDFForm/problem``).
    var formProblem: PDFOperationError? {
        guard usesFormPath else { return nil }
        return EditorPDFForm.problem(values: values, items: items, form: form, boxes: boxes,
                                     allowsFormEntry: allowsFormEntry, allowsCommenting: allowsCommenting,
                                     file: URL(fileURLWithPath: path ?? "/"))
    }

    /// Whether Save Filled Copy has something to write and nothing the toolkit would refuse.
    /// **Save Filled Copy's tooltip: why it is greyed, when a form would refuse it** — the note
    /// card's sentence, where the greyed button said what it would write; otherwise what it writes.
    public var saveHelp: String {
        if let formProblem, !Self.isNothingYet(formProblem) {
            return EditorPDFToolEngine.reason(formProblem, tool: .fillForm(values: values, items: []))
        }
        if onlyCorrections { return "Write a copy with these corrections beside the original — the original isn’t changed" }
        return usesFormPath
            ? "Write a copy beside the original with these values — its form stays fillable, and the original isn’t changed"
            : "Write a copy with these items beside the original — the original isn’t changed"
    }

    public var canSave: Bool {
        // Never for a refused file — File ▸ Save Filled Copy is live exactly where the pill's is.
        guard hasUnsavedChanges, refusal == nil else { return false }
        return formProblem == nil
    }

    /// The field's value as the reader sees it now: the draft, else the file's own.
    public func value(of field: FormField) -> FormFieldValue? {
        values[field.name] ?? EditorPDFForm.original(field)
    }

    /// A text or choice field's words as they stand.
    public func text(of field: FormField) -> String {
        switch value(of: field) {
        case .text(let string)?, .choice(let string)?: return string
        default: return ""
        }
    }

    /// Whether a checkbox is ticked, or `widget` is the radio group's chosen one.
    public func isOn(_ field: FormField, widget: FormField.Widget? = nil) -> Bool {
        switch value(of: field) {
        case .checked(let on)?: return on
        case .radio(let export)?: return widget.map { $0.exportValue == export } ?? true
        default: return false
        }
    }

    /// Why `field` takes no value here, or `nil`.
    public func fieldRefusal(_ field: FormField) -> String? {
        EditorPDFForm.refusal(field, allowsFormEntry: allowsFormEntry, allowsPlacing: offersPlacing)
    }

    private func fillableField(_ name: String) -> FormField? {
        guard isOn, let field = form.field(named: name), fieldRefusal(field) == nil else { return nil }
        return field
    }

    /// Sets a field's draft — dropped again when it matches the file's own, so a field typed back
    /// to what it was is not "changed".
    private func set(_ value: FormFieldValue, for field: FormField) {
        if value == EditorPDFForm.original(field) { values[field.name] = nil } else { values[field.name] = value }
    }

    /// Puts the keyboard on a field — or on none.
    public func focusField(_ name: String?) {
        if editingField != nil, editingField != name { endFieldEditing() }
        endEditing()
        selection = nil
        focusedField = name
    }

    /// **Starts typing into a text field** — or an editable combo's own value. The whole session is
    /// one undo step, taken by ``endFieldEditing()``.
    public func beginFieldEditing(_ name: String) {
        guard let field = fillableField(name), Self.isTyped(field) else { return }
        if editingField == name { return }
        focusField(name)
        fieldEditBefore = values
        editingField = name
    }

    /// Text fields, and combos that take a value of their own.
    static func isTyped(_ field: FormField) -> Bool {
        switch field.kind {
        case .text: return true
        case .choice(_, let allowsCustom): return allowsCustom
        default: return false
        }
    }

    /// **The words as typed, every keystroke** — returned as the field accepts them: cut at the
    /// field's `/MaxLen`, and on one line unless the field is multiline. The typing field shows what
    /// comes back, so a 9-character field stops at nine.
    @discardableResult
    public func typeField(_ string: String) -> String {
        guard let name = editingField, let field = form.field(named: name) else { return string }
        var accepted = string
        if case .text(let multiline) = field.kind, !multiline {
            accepted = accepted.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        if let max = field.maxLength, accepted.count > max { accepted = String(accepted.prefix(max)) }
        if case .choice = field.kind { set(.choice(accepted), for: field) } else { set(.text(accepted), for: field) }
        return accepted
    }

    /// Ends the typing: one undo step for it when the value moved.
    public func endFieldEditing() {
        guard editingField != nil else { return }
        editingField = nil
        guard let before = fieldEditBefore else { return }
        fieldEditBefore = nil
        if values != before { register(items, before, "Typing") }
    }

    /// A checkbox clicked: ticked or not, one undo step.
    public func toggleCheckbox(_ name: String) {
        guard let field = fillableField(name), field.kind == .checkbox else { return }
        focusField(name)
        changeValues("Check Box") { $0.set(.checked(!$0.isOn(field)), for: field) }
    }

    /// A radio button clicked: its group takes its value.
    public func selectRadio(_ name: String, export: String) {
        guard let field = fillableField(name), field.kind == .radio, field.options.contains(export) else { return }
        focusField(name)
        changeValues("Choose Option") { $0.set(.radio(export), for: field) }
    }

    /// A choice picked from a combo's or a list's menu.
    public func choose(_ name: String, option: String) {
        guard let field = fillableField(name), case .choice(_, let allowsCustom) = field.kind,
              allowsCustom || field.options.contains(option) else { return }
        focusField(name)
        changeValues("Choose Option") { $0.set(.choice(option), for: field) }
    }

    /// One stop on Tab's ring.
    public enum TabStop: Equatable, Sendable {
        case field(String)
        case item(UUID)
    }

    /// **Tab's ring** (decision BB, 2026-10-20): the fillable fields in the form's own order, then
    /// what is placed, in the order it was placed. A file with no form has the items alone.
    public var tabStops: [TabStop] {
        guard isOn else { return [] }
        let fields = allowsFormEntry ? form.fillable.map { TabStop.field($0.name) } : []
        return fields + items.map { .item($0.id) }
    }

    /// Where the keyboard is on the ring: the field it is on, else the item selected.
    public var tabStop: TabStop? {
        if let name = editingField ?? focusedField { return .field(name) }
        return selection.map(TabStop.item)
    }

    /// **Tab and ⇧Tab: the next stop on the ring**, round from the last to the first. A text field
    /// takes the typing straight away, as Acrobat's does; an item is selected, for the arrows,
    /// Delete and Return. Typing in a text box ends first — an empty one goes, off the ring.
    public func focusNext(forward: Bool = true) {
        endEditing()
        let ring = tabStops
        guard !ring.isEmpty else { return }
        let next: TabStop
        if let current = tabStop, let at = ring.firstIndex(of: current) {
            next = ring[(at + (forward ? 1 : ring.count - 1)) % ring.count]
        } else {
            next = forward ? ring[0] : ring[ring.count - 1]
        }
        endFieldEditing()
        switch next {
        // Only a text field: an editable combo gets the keyboard, and its menu offers the typing.
        case .field(let name):
            if let field = form.field(named: name), case .text = field.kind {
                beginFieldEditing(name)
            } else {
                focusField(name)
            }
        case .item(let id):
            focusField(nil)
            select(id)
        }
    }

    /// Space on the field the keyboard is on: a checkbox toggles, a radio group steps to its next
    /// option. A choice's menu is the overlay's to open.
    public func activateFocused() {
        guard let name = focusedField, let field = fillableField(name) else { return }
        switch field.kind {
        case .checkbox: toggleCheckbox(name)
        case .radio:
            let options = field.options
            guard !options.isEmpty else { return }
            let current: String? = { if case .radio(let e)? = value(of: field) { return e }; return nil }()
            let at = current.flatMap { options.firstIndex(of: $0) }
            selectRadio(name, export: options[at.map { ($0 + 1) % options.count } ?? 0])
        case .text: beginFieldEditing(name)
        default: break
        }
    }

    private func changeValues(_ name: String, _ body: (EditorPDFFillSign) -> Void) {
        let before = values
        body(self)
        if values != before { register(items, before, name) }
    }

    // MARK: Changing what is placed

    public func select(_ id: UUID?) {
        if editing != nil, editing != id { endEditing() }
        if id != nil {
            // The keyboard is on the item now, not on a field.
            endFieldEditing()
            focusedField = nil
        }
        selection = id
        lastPlaced = nil
    }

    public func deleteSelection() {
        guard let id = selection else { return }
        if editing == id { editing = nil; editBefore = nil }
        change("Delete") { $0.removeAll { $0.id == id } }
        selection = nil
    }

    /// The start of a drag — what its one undo step goes back to.
    public func beginGesture() {
        endEditing()
        gestureBefore = items
    }

    /// Moves an item to `rect`, kept on its page — every step of a drag, without undo steps.
    public func moveLive(_ id: UUID, to rect: CGRect) {
        // A correction stays over the words it covers.
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isCorrection,
              let box = box(items[index].page) else { return }
        items[index].rect = FillSignGeometry.clamped(rect, in: box.displayBounds)
    }

    /// **Resizes from the corner handle** — the far corner dragged to `corner`, the other one held.
    /// Words take the point size that fills the new height; a drawn signature keeps its shape.
    public func resizeLive(_ id: UUID, anchor: CGPoint, corner: CGPoint) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isCorrection,
              let box = box(items[index].page) else { return }
        let dragged = FillSignGeometry.resizedRect(anchor: anchor, corner: corner, minimumSide: FillSignGeometry.minimumSidePt)
        var item = items[index]
        if let unitBox = item.wordsSize(fontSize: 10) {
            let unit = unitBox.height / 10
            item.fontSize = min(max(dragged.height / max(unit, 0.1), Self.fontSizes[0]), Self.fontSizes.last!)
            let size = item.wordsSize(fontSize: item.fontSize) ?? unitBox
            // Held by the top-left corner, where the words start.
            item.rect = CGRect(x: item.rect.minX, y: item.rect.maxY - size.height, width: size.width, height: size.height)
        } else {
            let aspect = item.rect.height > 0 ? item.rect.width / item.rect.height : 1
            let width = max(dragged.width, dragged.height * aspect)
            item.rect = CGRect(x: item.rect.minX, y: item.rect.maxY - width / aspect, width: width, height: width / aspect)
        }
        item.rect = FillSignGeometry.clamped(item.rect, in: box.displayBounds)
        items[index] = item
    }

    /// The end of a drag: one undo step for all of it, or none when nothing moved.
    public func endGesture(_ name: String) {
        guard let before = gestureBefore else { return }
        gestureBefore = nil
        if items != before { register(before, name) }
    }

    /// The arrow keys: a point at a time, ten with ⇧.
    public func nudge(dx: CGFloat, dy: CGFloat) {
        guard let id = selection, let item = items.first(where: { $0.id == id }), !item.isCorrection,
              let box = box(item.page) else { return }
        change("Move") { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].rect = FillSignGeometry.clamped(item.rect.offsetBy(dx: dx, dy: dy), in: box.displayBounds)
        }
    }

    /// The size the selected item's words are in, else the next item's — what Smaller and Bigger
    /// step from and what the size flyout ticks.
    public var currentFontSize: CGFloat { selected.flatMap { $0.words != nil ? $0.fontSize : nil } ?? fontSize }

    /// Smaller and Bigger: the selected item's words a step smaller or bigger — and the next item's.
    public func stepFontSize(bigger: Bool) {
        let current = currentFontSize
        let next = bigger ? Self.fontSizes.first { $0 > current + 0.01 } : Self.fontSizes.last { $0 < current - 0.01 }
        guard let next else { return }
        setFontSize(next, undoName: bigger ? "Bigger Text" : "Smaller Text")
    }

    /// A size chosen in the size flyout (Phase 6b): the selected item's words, and the next item's.
    public func setFontSize(_ size: CGFloat) {
        guard abs(size - currentFontSize) > 0.01 else { return }
        setFontSize(size, undoName: "Text Size")
    }

    private func setFontSize(_ next: CGFloat, undoName: String) {
        if let id = selection, selected?.words != nil {
            change(undoName) { items in
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].fontSize = next
                Self.resizeToWords(&items[index], in: box(items[index].page))
            }
            // A correction's size is the covered words', not the next text's — as its font is.
            if selected?.isSignature == false, selected?.isCorrection == false { fontSize = next }
        } else {
            fontSize = next
        }
    }

    public func canStepFontSize(bigger: Bool) -> Bool {
        let current = currentFontSize
        return bigger ? current < Self.fontSizes.last! - 0.01 : current > Self.fontSizes[0] + 0.01
    }

    /// An ink: the selected item's, and the next item's.
    public func setColor(_ color: EditorPDFFillColor) {
        self.color = color
        guard let id = selection else { return }
        change("Ink") { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].color = color
            if case .correction(var correction) = items[index].content {
                correction.keepsOriginalInk = false
                items[index].content = .correction(correction)
            }
        }
    }

    /// **The Ink tool's "Original" for a selected correction**: back to the covered words' ink.
    public func useOriginalInk() {
        guard let id = selection else { return }
        change("Ink") { items in
            guard let index = items.firstIndex(where: { $0.id == id }), case .correction(var correction) = items[index].content
            else { return }
            correction.keepsOriginalInk = true
            items[index].content = .correction(correction)
        }
    }

    /// **Add on the Add Signature sheet**: saved unless unticked — with initials made from a typed
    /// signature in its face when asked (TE94) — chosen, so the next click places it, and its ink
    /// the next item's (TE89). The palette's ink, not the selected item's: adding a signature
    /// recolours nothing already placed.
    /// **Opened from a signature field, it is placed in that field** (TE107) instead.
    public func add(_ signature: EditorPDFSignature, keep: Bool, makeInitials: Bool, ink: EditorPDFFillColor) {
        if keep {
            store.add(signature)
            if makeInitials, offersInitials(with: signature.kind), case .typed(let words) = signature.look {
                let initials = EditorPDFSignature.initials(of: words)
                if !initials.isEmpty {
                    store.add(EditorPDFSignature(kind: .initials, look: .typed(initials), face: signature.face))
                }
            }
        }
        color = ink
        if let target = signing {
            signing = nil
            place(signature, in: target)
        } else {
            armed = .signature(signature)
        }
    }

    /// **The Signature or Initials tool pressed, or a signature field clicked, with none of `kind`
    /// saved**: the Add sheet, straight away (TE141) — there is nothing for a menu to offer but Add.
    /// `true` when it opened. From a field, what is added is placed in it.
    @discardableResult
    public func addFirst(_ kind: EditorPDFSignature.Kind, signing target: SigningTarget? = nil) -> Bool {
        guard store.saved(kind).isEmpty else { return false }
        startAdding(kind, signing: target)
        return true
    }

    /// The Add sheet for `kind` — for a field, when `target` names one.
    public func startAdding(_ kind: EditorPDFSignature.Kind, signing target: SigningTarget? = nil) {
        addingSignature = kind
        signing = target
    }

    /// **Delete a Saved Signature asks first** (decision BE, 2026-10-20): it took effect on the
    /// choice, with no way back, and from the keyboard or VoiceOver the wrong line is easy to land on.
    public func deleteSaved(_ signature: EditorPDFSignature) {
        guard confirmDeletingSaved(signature, signature.spokenName(among: store.saved)) else { return }
        store.delete(signature.id)
    }

    /// The question, built but not run — a test reads its buttons. **Cancel is the default**, so
    /// Return keeps the signature; Delete is marked destructive.
    static func deleteSavedAlert(_ signature: EditorPDFSignature, name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Delete the saved \(signature.kind == .signature ? "signature" : "initials") “\(name)”?"
        alert.informativeText = "What you’ve already placed on a page stays. This can’t be undone."
        if let picture = EditorPDFSignatureMenu.image(signature, height: 48) { alert.icon = picture }
        let cancel = alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete")
        // Set here, not left to the alert, which hands them out only as it runs.
        cancel.keyEquivalent = "\r"
        delete.keyEquivalent = ""
        delete.hasDestructiveAction = true
        return alert
    }

    /// **Whether Add Signature offers to make initials too** (TE94): for a signature, while no
    /// initials are saved.
    public func offersInitials(with kind: EditorPDFSignature.Kind) -> Bool {
        kind == .signature && store.saved(.initials).isEmpty
    }

    public var selected: EditorPDFFillItem? { selection.flatMap { id in items.first { $0.id == id } } }

    // MARK: Style (TE92, TE93)

    /// **What the Aa tool changes now**: the selected item's face, pen or font — or, with nothing
    /// selected, the next text's font, as Size and Ink do.
    public enum StyleTarget: Equatable, Sendable {
        case nextText
        case text(UUID)
        case typedSignature(UUID)
        case drawnSignature(UUID)
        /// A ✓, ✗ or • — it keeps the system font.
        case mark
        /// A correction: its original's face while this Mac has it, or an Aa font.
        case correction(UUID)
    }

    public var styleTarget: StyleTarget {
        guard let item = selected else { return .nextText }
        if item.isMark { return .mark }
        switch item.content {
        case .text: return .text(item.id)
        case .correction: return .correction(item.id)
        case .signature(let signature):
            if case .typed = signature.look { return .typedSignature(item.id) }
            return .drawnSignature(item.id)
        }
    }

    /// The font the Aa tool ticks for text: the selected text's, else the next text's.
    public var currentTextFont: EditorPDFTextFont {
        if case .text = styleTarget, let item = selected { return item.font }
        if case .correction = styleTarget, let item = selected { return item.font }
        return textFont
    }

    /// A font for the selected text, and the next — one undo step, as Size's. A correction takes
    /// it in place of its original's face; the next text's font stays as it was.
    public func setTextFont(_ font: EditorPDFTextFont) {
        if case .correction(let id) = styleTarget {
            change("Font") { items in
                guard let index = items.firstIndex(where: { $0.id == id }), case .correction(var correction) = items[index].content
                else { return }
                correction.keepsOriginalFont = false
                items[index].content = .correction(correction)
                items[index].font = font
                Self.resizeToWords(&items[index], in: box(items[index].page))
            }
            return
        }
        if case .text(let id) = styleTarget {
            change("Font") { items in
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].font = font
                Self.resizeToWords(&items[index], in: box(items[index].page))
            }
        }
        textFont = font
    }

    /// **The Aa tool's "Original" for a selected correction**: back to the covered words' own face.
    public func useOriginalFont() {
        guard case .correction(let id) = styleTarget else { return }
        change("Font") { items in
            guard let index = items.firstIndex(where: { $0.id == id }), case .correction(var correction) = items[index].content,
                  correction.installedFont != nil else { return }
            correction.keepsOriginalFont = true
            items[index].content = .correction(correction)
            Self.resizeToWords(&items[index], in: box(items[index].page))
        }
    }

    /// **Another face for the selected typed signature**, kept at the width it was placed at (TE88).
    public func setFace(_ face: EditorPDFSignatureFace) {
        guard case .typedSignature(let id) = styleTarget, let item = selected, var signature = item.signature,
              case .typed(let words) = signature.look, signature.face != face else { return }
        let size = EditorPDFFillItem.fittedSize(words, face: face, matching: signature.face, at: item.fontSize)
        signature.face = face
        restyle(id, to: signature, name: "Face") { $0.fontSize = size }
    }

    /// Another pen for the selected drawn signature (TE92).
    public func setPen(_ pen: EditorPDFPen) {
        guard case .drawnSignature(let id) = styleTarget, var signature = selected?.signature, signature.pen != pen else {
            return
        }
        signature.pen = pen
        restyle(id, to: signature, name: "Pen") { _ in }
    }

    /// **Whether restyling the selected signature changes the saved one too** — decision AS,
    /// 2026-10-19: it does, when it was saved; one placed without saving changes on the page only.
    public var restyleChangesSaved: Bool {
        guard let id = selected?.signature?.id else { return false }
        return store.saved.contains { $0.id == id }
    }

    /// The placed signature restyled — and the saved one with it — as ONE undo step: ⌘Z puts both
    /// back, so a face tried and undone leaves the next file's signature as it was.
    private func restyle(_ id: UUID, to signature: EditorPDFSignature, name: String,
                         _ adjust: (inout EditorPDFFillItem) -> Void) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        if let saved = store.saved.first(where: { $0.id == signature.id }) {
            store.replace(signature)
            registerSaved(saved, name)
        }
        change(name) { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].content = .signature(signature)
            adjust(&items[index])
            Self.resizeToWords(&items[index], in: box(items[index].page))
        }
    }

    /// Puts `saved` back on undo, and what it replaced on redo.
    private func registerSaved(_ saved: EditorPDFSignature, _ name: String) {
        undoManager.registerUndo(withTarget: self) { fill in
            guard let now = fill.store.saved.first(where: { $0.id == saved.id }) else { return }
            fill.store.replace(saved)
            fill.registerSaved(now, name)
        }
        undoManager.setActionName(name)
    }

    private func resizeToWords(_ index: Int) {
        Self.resizeToWords(&items[index], in: box(items[index].page))
    }

    /// Fits a text item's box to its words, held by its top-left corner — a correction's by the
    /// covered words' baseline and left edge, so its words sit where theirs did at any size.
    static func resizeToWords(_ item: inout EditorPDFFillItem, in box: EditorPDFPageBox?) {
        guard let size = item.wordsSize(fontSize: item.fontSize) else { return }
        if let correction = item.correction {
            let top = correction.baseline + baselineOffset(item.nsFont(size: item.fontSize))
            item.rect = CGRect(x: correction.left, y: top - size.height, width: size.width, height: size.height)
            return
        }
        var rect = CGRect(x: item.rect.minX, y: item.rect.maxY - size.height, width: size.width, height: size.height)
        if let box { rect = FillSignGeometry.clamped(rect, in: box.displayBounds) }
        item.rect = rect
    }

    /// How far below the top of its box the toolkit draws a line's baseline: `NSStringDrawing`'s
    /// layout, which both the copy and the screen use.
    static func baselineOffset(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultBaselineOffset(for: font)
    }

    // MARK: Undo

    private func change(_ name: String, _ body: (inout [EditorPDFFillItem]) -> Void) {
        let before = items
        body(&items)
        // **Inside an open box, the box's own step takes it**: ``endEditing()`` registers one step
        // against `editBefore`, and Esc on a correction puts `editBefore` back. A step of its own
        // here — Text Size chosen while retyping — held the half-typed words, so ⌘Z after Esc
        // brought back the correction Esc had cancelled.
        if items != before, editing == nil || editBefore == nil { register(before, name) }
    }

    private func register(_ before: [EditorPDFFillItem], _ name: String) {
        register(before, values, pictures, name)
    }

    private func register(_ before: [EditorPDFFillItem], _ beforeValues: [String: FormFieldValue], _ name: String) {
        register(before, beforeValues, pictures, name)
    }

    /// **One undo step for items, field values and the pages made pictures together** — placing,
    /// filling and the note card's button share the one ⌘Z stack, so a step back is a step back
    /// whichever was done last.
    private func register(_ before: [EditorPDFFillItem], _ beforeValues: [String: FormFieldValue],
                          _ beforePictures: Set<Int>, _ name: String) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { fill in
            let after = fill.items
            let afterValues = fill.values
            let afterPictures = fill.pictures
            fill.editing = nil
            fill.editBefore = nil
            fill.editingField = nil
            fill.fieldEditBefore = nil
            fill.items = before
            fill.values = beforeValues
            fill.pictures = beforePictures
            if let selection = fill.selection, !before.contains(where: { $0.id == selection }) { fill.selection = nil }
            fill.register(after, afterValues, afterPictures, name)
        }
        undoManager.setActionName(name)
    }

    // MARK: Saving

    /// **Save Filled Copy**: the items, as the toolkit draws them, through the tools' one run. On a
    /// copy written, the items go and the palette goes down; the copy is the banner's to open.
    ///
    /// **Only if nothing changed while the copy was being written.** The run takes a lane turn and a
    /// detached write, and the pages stay live meanwhile, so an item placed or a field typed during
    /// it is not in the copy. Clearing then deleted it with no word; now everything stays, still
    /// counted as unsaved, and the leave question still asks about it.
    @discardableResult
    public func save() async -> EditorPDFToolOutcome {
        endEditing()
        endFieldEditing()
        guard let tools else { return .failed("No PDF is open.") }
        let savedItems = items, savedValues = values, savedPictures = pictures
        let placed = unsaved
        let toolkit = placed.flatMap { item in box(item.page).map { item.toolkitItems(on: $0) } ?? [] }
        let path = self.path
        let tool: EditorPDFTool
        if usesFormPath, placed.contains(where: \.isCorrection) {
            // Replace is off on a form (decision AV): a correction kept as a note would peel off. One
            // here came from before the file, reloaded, had a form.
            let reason = Self.formReplaceReason
            tools.banner = EditorPDFToolBanner(message: reason, kind: .failure)
            return .failed(reason)
        } else if usesFormPath {
            // **A file with its own form is filled in place** — `fillFormData`, so the copy's form
            // stays fillable — and what the toolkit would refuse is said before a lane turn.
            tool = .fillForm(values: values, items: toolkit)
            if let problem = formProblem, let path {
                Logger.shared.info("Edit refused \(tool.logDetail) of \(EditorPDFTools.logName(path)) — "
                                   + EditorPDFToolEngine.logReason(problem, tool: tool))
                let reason = EditorPDFToolEngine.reason(problem, tool: tool)
                tools.banner = EditorPDFToolBanner(message: reason, kind: .failure)
                return .failed(reason)
            }
        } else {
            tool = .fillAndSign(toolkit, pictures: picturesToSave)
        }
        let outcome = await tools.run(tool)
        if case .wrote = outcome, self.path == path {
            if items == savedItems, values == savedValues, pictures == savedPictures {
                clear()
                isOn = false
            } else if let path {
                Logger.shared.info("Edit kept Fill & Sign on \(EditorPDFTools.logName(path)) — it changed "
                                   + "while the filled copy was being written, so the copy does not carry everything")
            }
        }
        return outcome
    }

    /// Discard: every item goes, and the palette stays for another go.
    public func discard() {
        endEditing()
        endFieldEditing()
        let before = items, beforeValues = values, beforePictures = pictures
        items.removeAll()
        values = [:]
        pictures = []
        if items != before || values != beforeValues || pictures != beforePictures {
            register(before, beforeValues, beforePictures, "Discard")
        }
        selection = nil
        focusedField = nil
    }

    // MARK: Leaving

    /// **Asks before unsaved items are lost** — closing the PDF, opening another file, leaving
    /// Edit or quitting (``EditorPDFTools/mayLeave(thenRetry:)`` asks this).
    ///
    /// **Save Filled Copy saves, then leaves** (decision AX, 2026-10-20). The leave is a question
    /// the save cannot answer in time, and leaving while it runs would cancel it — so the answer is
    /// still "stay", and once the copy has landed with nothing changed meanwhile, `retry` asks for
    /// the leave again, which then goes: nothing is left to ask about. A save that fails, is
    /// declined or is cancelled stays on the PDF with its banner, as does one the reader placed
    /// more on while it ran; `retry` is not called.
    public func mayLeave(thenRetry retry: (@MainActor () -> Void)? = nil) -> Bool {
        endEditing()
        endFieldEditing()
        guard hasUnsavedChanges, let path else { return true }
        let answer = askLeaving((path as NSString).lastPathComponent, unsaved.count + values.count)
        let what = values.isEmpty ? "\(placed) placed"
            : unsaved.isEmpty ? "\(Self.fields(values.count)) filled"
            : "\(Self.fields(values.count)) filled and \(placed) placed"
        Logger.shared.info("Edit asked before leaving \(EditorPDFTools.logName(path)) with \(what) "
                           + "with Fill & Sign — " + {
                               switch answer {
                               case .save: return "the reader chose to save a filled copy"
                               case .discard: return "the reader chose to discard them"
                               case .cancel: return "the reader stayed"
                               }
                           }())
        switch answer {
        case .discard: return true
        case .cancel: return false
        case .save:
            Task {
                let outcome = await save()
                guard let retry, case .wrote = outcome, !hasUnsavedChanges, self.path == path else { return }
                Logger.shared.info("Edit left \(EditorPDFTools.logName(path)) once its filled copy was written")
                retry()
            }
            return false
        }
    }

    static func alertRefusal(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = reason == restrictedReason || reason == nothingToFillReason
            ? restrictedTitle : "Fill & Sign isn’t available for this PDF"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// `count` is everything unsaved, `fields` the part of it that is changed fields; `corrected`
    /// says every one of them is a correction.
    static func leaveQuestion(name: String, count: Int, fields: Int = 0, corrected: Bool = false) -> (title: String, detail: String) {
        let items = count - fields
        let what: String
        switch (fields, items) {
        case (0, _) where corrected: what = items == 1 ? "1 correction you made isn’t" : "\(items) corrections you made aren’t"
        case (0, _): what = items == 1 ? "1 item you placed isn’t" : "\(items) items you placed aren’t"
        case (_, 0): what = fields == 1 ? "1 field you filled isn’t" : "\(fields) fields you filled aren’t"
        default: what = "\(Self.fields(fields)) you filled and \(Self.count(items)) you placed aren’t"
        }
        return ("Save the \(corrected ? "corrected" : "filled") copy of “\(name)”?",
                "\(what) saved. The original file hasn’t been changed.")
    }

    static func alertLeaving(name: String, count: Int, fields: Int = 0, corrected: Bool = false) -> LeaveAnswer {
        let question = leaveQuestion(name: name, count: count, fields: fields, corrected: corrected)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.detail
        alert.addButton(withTitle: corrected ? "Save Corrected Copy" : "Save Filled Copy")
        alert.addButton(withTitle: fields == 0 ? "Discard Items" : "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
