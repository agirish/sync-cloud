import Testing
import AppKit
import PDFKit
import PDFToolkitCore
import Sync
import EventsTestSupport
@testable import FileExplorer

/// **A PDF with words where a test says**, drawn by CoreText the way real producers draw: an
/// embedded subset font, a fill colour, a baseline at a known point.
enum ReplaceFixtures {
    struct Line {
        var text: String
        var at: CGPoint
        var font = "Helvetica"
        var size: CGFloat = 14
        var color = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    }

    /// A ground drawn under the words: a flat colour, or stripes — a pattern no patch hides.
    enum Ground {
        case none
        case flat(CGRect, CGColor)
        case stripes(CGRect)
        /// Light grey dots on white: white is most of it, but a third is a shade between.
        case dots(CGRect)
    }

    static func write(_ path: String, lines: [Line], ground: Ground = .none, invisible: Bool = false, coverWith: CGRect? = nil) {
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let context = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        switch ground {
        case .none: break
        case .flat(let rect, let color):
            context.setFillColor(color)
            context.fill(rect)
        case .dots(let rect):
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1))
            for x in stride(from: rect.minX, to: rect.maxX, by: 2.5) {
                for y in stride(from: rect.minY, to: rect.maxY, by: 2.5) { context.fill(CGRect(x: x, y: y, width: 1.5, height: 1.5)) }
            }
        case .stripes(let rect):
            for (i, x) in stride(from: rect.minX, to: rect.maxX, by: 4).enumerated() {
                context.setFillColor(i % 2 == 0 ? CGColor(srgbRed: 0.75, green: 0.85, blue: 0.95, alpha: 1)
                                                : CGColor(srgbRed: 0.95, green: 0.8, blue: 0.7, alpha: 1))
                context.fill(CGRect(x: x, y: rect.minY, width: 4, height: rect.height))
            }
        }
        if invisible { context.setTextDrawingMode(.invisible) }
        for line in lines {
            let font = CTFontCreateWithName(line.font as CFString, line.size, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): line.color,
            ])
            context.textPosition = line.at
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        if let coverWith {
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(coverWith)
        }
        context.endPDFPage()
        context.closePDF()
    }

    /// The same file with a font renamed in place, byte for byte — "Helvetica" to "Adelle-Rg",
    /// both nine letters, so no offset moves — a face this Mac doesn't have.
    static func rename(_ path: String, font: String, to name: String) throws {
        precondition(font.utf8.count == name.utf8.count)
        var data = try Data(contentsOf: URL(fileURLWithPath: path))
        let old = Data(("+" + font).utf8), new = Data(("+" + name).utf8)
        var replaced = 0
        while let range = data.range(of: old) {
            data.replaceSubrange(range, with: new)
            replaced += 1
        }
        precondition(replaced > 0, "no \(font) in the file")
        try data.write(to: URL(fileURLWithPath: path))
    }
}

/// **Cover and Retype (TE82–TE87)** — Replace in Fill & Sign: the words picked off the page, the
/// box that retypes them, the patch that covers them in the copy, and the refusals.
@MainActor
@Suite(.serialized) final class EditorPDFReplaceTests {

    let folder = NSTemporaryDirectory() + "editor-pdf-replace-" + UUID().uuidString
    private let defaults = ScratchDefaults("EditorPDFReplaceTests")

    init() throws {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private func path(_ name: String) -> String { (folder as NSString).appendingPathComponent(name) }

    private func open(_ file: String) async throws -> EditorPDFDocument {
        let pdf = EditorPDFDocument(isCloudOnly: { _ in false }, defaults: defaults)
        pdf.tools.isCloudOnly = { _ in false }
        pdf.open(path: file, log: { _ in })
        for _ in 0..<1000 where pdf.phase == .loading { await PDFKitSerialAccess.perform {} }
        try #require(pdf.phase == .open)
        return pdf
    }

    static let dark = CGColor(srgbRed: 0.6, green: 0.05, blue: 0.1, alpha: 1)

    /// The invoice of the mockup: a label and its value on one baseline, a column apart.
    private func invoice(_ name: String = "Invoice.pdf", font: String = "Helvetica", ground: ReplaceFixtures.Ground = .none)
        -> String {
        let file = path(name)
        ReplaceFixtures.write(file, lines: [
            .init(text: "Invoice 2026-031", at: CGPoint(x: 72, y: 720), font: font, size: 20),
            .init(text: "Payment due", at: CGPoint(x: 72, y: 600), font: font, color: Self.dark),
            .init(text: "14 March 2026", at: CGPoint(x: 260, y: 600), font: font, color: Self.dark),
            .init(text: "Client Harbour & Pike Ltd", at: CGPoint(x: 72, y: 580), font: font),
        ], ground: ground)
        return file
    }

    private func page(_ file: String) throws -> (PDFPage, EditorPDFPageBox) {
        let page = try #require(PDFDocument(url: URL(fileURLWithPath: file))?.page(at: 0))
        return (page, EditorPDFPageBox(cropBox: page.bounds(for: .cropBox), rotation: page.rotation))
    }

    /// The pick for the line under `point` (page space).
    private func pick(_ file: String, at point: CGPoint) throws -> Result<EditorPDFReplacePick, EditorPDFReplaceRefusal> {
        let (page, box) = try page(file)
        let line = try #require(EditorPDFReplace.line(at: point, on: page, box: box), "no line at \(point)")
        return EditorPDFReplace.pick(line, page: page, index: 0, box: box)
    }

    // MARK: Fonts (TE86)

    @Test func aSubsetTagGoesAndTheMacsOwnFaceIsFound() {
        #expect(EditorPDFFontMatch.dropSubsetTag("ABCDEF+ArialMT") == "ArialMT")
        #expect(EditorPDFFontMatch.dropSubsetTag("ArialMT") == "ArialMT")
        #expect(EditorPDFFontMatch.dropSubsetTag("ABCDE+ArialMT") == "ABCDE+ArialMT")
        #expect(EditorPDFFontMatch.installed("Helvetica") == "Helvetica")
        // Installed and opened by name, though no font list shows them.
        #expect(EditorPDFFontMatch.installed("Times-Roman") == "Times-Roman")
        #expect(EditorPDFFontMatch.installed("Courier-Bold") == "Courier-Bold")
        // TrueType names: the family, in the style after the comma.
        #expect(EditorPDFFontMatch.installed("Arial") == "ArialMT")
        #expect(EditorPDFFontMatch.installed("Arial,Bold") == "Arial-BoldMT")
        #expect(EditorPDFFontMatch.installed("TimesNewRoman,Italic") == "TimesNewRomanPS-ItalicMT")
        #expect(EditorPDFFontMatch.installed("Times New Roman") == "TimesNewRomanPSMT")
        // A face this Mac lacks — and a family it has, named in a weight it hasn't.
        #expect(EditorPDFFontMatch.installed("Adelle-Regular") == nil)
        #expect(EditorPDFFontMatch.installed("Helvetica-Hairline") == nil)
    }

    @Test func aMissingFaceStandsInAsTheNearestAaFont() {
        #expect(EditorPDFFontMatch.standIn(for: "Whatever", flags: EditorPDFTextRun.fixedPitchFlag) == .mono)
        #expect(EditorPDFFontMatch.standIn(for: "Whatever", flags: EditorPDFTextRun.serifFlag) == .serif)
        #expect(EditorPDFFontMatch.standIn(for: "Whatever", flags: EditorPDFTextRun.scriptFlag) == .handwritten)
        #expect(EditorPDFFontMatch.standIn(for: "Adelle-Regular", flags: 0) == .serif)
        #expect(EditorPDFFontMatch.standIn(for: "OCRAStd", flags: 0) == .mono)
        #expect(EditorPDFFontMatch.standIn(for: "OpenSans-Bold", flags: 0) == .sans)
        #expect(EditorPDFFontMatch.standIn(for: "Whatever", flags: 0) == .sans)
    }

    // MARK: The page's runs

    /// **The content stream's runs: the real font, its size, where its baseline starts, its ink.**
    @Test func theRunsSayTheFontSizeBaselineAndInk() throws {
        let file = invoice()
        let (page, _) = try page(file)
        let runs = EditorPDFTextRunReader.runs(of: try #require(page.pageRef))
        let due = try #require(runs.first { abs($0.start.x - 260) < 0.5 && abs($0.start.y - 600) < 0.5 }, "\(runs)")
        #expect(due.fontName == "Helvetica")
        #expect(abs(due.fontSize - 14) < 0.01)
        let ink = try #require(due.color)
        #expect(ink.distance(to: EditorPDFRGB(red: 0.6, green: 0.05, blue: 0.1)) < 0.02, "\(ink)")
        // Its end: the glyphs' widths, as wide as the words are set.
        let set = NSAttributedString(string: "14 March 2026", attributes: [.font: NSFont(name: "Helvetica", size: 14)!]).size().width
        #expect(abs((due.end.x - due.start.x) - set) < 1, "the run is \(due.end.x - due.start.x) wide, the words \(set)")
        #expect(runs.contains { $0.fontName == "Helvetica" && abs($0.fontSize - 20) < 0.01 })
    }

    /// **A form XObject's runs are read too**, through its matrix.
    @Test func aFormsRunsAreReadThroughItsMatrix() throws {
        let file = path("Form.pdf")
        // A page whose words are drawn into a form XObject: the original made by CoreText, then
        // drawn as a page into another — `drawPDFPage` writes the page as a form.
        let inner = path("Inner.pdf")
        ReplaceFixtures.write(inner, lines: [.init(text: "Inside a form", at: CGPoint(x: 100, y: 400))])
        var box = CGRect(origin: .zero, size: PDFFixtures.letter)
        let context = CGContext(URL(fileURLWithPath: file) as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.translateBy(x: 50, y: -100)
        context.drawPDFPage(try #require(CGPDFDocument(URL(fileURLWithPath: inner) as CFURL)?.page(at: 1)))
        context.endPDFPage()
        context.closePDF()
        let runs = EditorPDFTextRunReader.runs(of: try #require(CGPDFDocument(URL(fileURLWithPath: file) as CFURL)?.page(at: 1)))
        #expect(runs.contains { $0.fontName == "Helvetica" && abs($0.start.x - 150) < 0.5 && abs($0.start.y - 300) < 0.5 }, "\(runs)")
    }

    // MARK: Picking (TE82)

    /// **A click picks the words under it — the piece of the line a column's gap sets apart.**
    @Test func aClickPicksTheWordsBetweenTheColumnsGaps() throws {
        let file = invoice()
        guard case .success(let value) = try pick(file, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        #expect(value.words == "14 March 2026")
        guard case .success(let label) = try pick(file, at: CGPoint(x: 90, y: 604)) else { Issue.record("refused"); return }
        #expect(label.words == "Payment due")
        guard case .success(let client) = try pick(file, at: CGPoint(x: 90, y: 584)) else { Issue.record("refused"); return }
        #expect(client.words == "Client Harbour & Pike Ltd", "a word's gap split the line")
        let (page, box) = try page(file)
        #expect(EditorPDFReplace.line(at: CGPoint(x: 400, y: 300), on: page, box: box) == nil, "a click off any words picked some")
    }

    /// **The pick carries the original's face, size, ink and baseline — the run's, not PDFKit's.**
    @Test func thePickIsTheOriginalsFaceSizeInkAndBaseline() throws {
        guard case .success(let pick) = try pick(invoice(), at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        #expect(pick.fontName == "Helvetica" && pick.installedFont == "Helvetica")
        #expect(pick.fontSize == 14)
        #expect(abs(pick.baseline - 600) < 0.01, "baseline \(pick.baseline)")
        #expect(abs(pick.left - 260) < 1, "left \(pick.left)")
        #expect(pick.ink.distance(to: EditorPDFRGB(red: 0.6, green: 0.05, blue: 0.1)) < 0.02)
        #expect(pick.patch.distance(to: .white) < 0.02 && pick.plainBackground)
        // The cover takes in the glyphs with room to spare, and no more than a line's height.
        #expect(pick.cover.contains(pick.wordsRect))
        #expect(pick.cover.height < 2 * 14, "the cover is \(pick.cover.height)pt tall")
    }

    /// **A face this Mac lacks is named, and stands in as the nearest Aa font** — read off the
    /// page's own fonts: "Adelle-Rg" by name is a slab serif.
    @Test func aFaceThisMacLacksIsNamedAndStandsIn() throws {
        let file = invoice("Adelle.pdf")
        try ReplaceFixtures.rename(file, font: "Helvetica", to: "Adelle-Rg")
        guard case .success(let pick) = try pick(file, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        #expect(pick.fontName == "Adelle-Rg")
        #expect(pick.installedFont == nil)
        #expect(pick.standIn == .serif)
    }

    /// **The patch takes the page's colour under the words**; a striped ground is allowed and said.
    @Test func thePatchIsTheGroundsColourAndAPatternIsSaid() throws {
        let tinted = invoice("Tinted.pdf", ground: .flat(CGRect(x: 200, y: 560, width: 300, height: 80),
                                                         CGColor(srgbRed: 0.9, green: 0.95, blue: 0.8, alpha: 1)))
        guard case .success(let flat) = try pick(tinted, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        #expect(flat.patch.distance(to: EditorPDFRGB(red: 0.9, green: 0.95, blue: 0.8)) < 0.02, "\(flat.patch)")
        #expect(flat.plainBackground)
        let striped = invoice("Striped.pdf", ground: .stripes(CGRect(x: 200, y: 560, width: 300, height: 80)))
        guard case .success(let pattern) = try pick(striped, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        #expect(!pattern.plainBackground, "stripes passed for a plain ground")
        // White words on a band hardly taller than they are: the patch is the band's colour, not the
        // white of the page past it.
        let band = path("Band.pdf")
        let teal = CGColor(srgbRed: 0.2, green: 0.75, blue: 0.75, alpha: 1)
        ReplaceFixtures.write(band, lines: [.init(text: "PROPERTY ADDRESS", at: CGPoint(x: 260, y: 600),
                                                  color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))],
                              ground: .flat(CGRect(x: 200, y: 596, width: 300, height: 15), teal))
        guard case .success(let onBand) = try pick(band, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        #expect(onBand.patch.distance(to: EditorPDFRGB(red: 0.2, green: 0.75, blue: 0.75)) < 0.03, "\(onBand.patch)")
        #expect(onBand.ink.distance(to: .white) < 0.02)
        // Mostly white, yet a texture: the shades between give it away.
        let dotted = invoice("Dotted.pdf", ground: .dots(CGRect(x: 200, y: 560, width: 300, height: 80)))
        guard case .success(let dots) = try pick(dotted, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        #expect(!dots.plainBackground, "a dotted ground passed for a plain one")
    }

    // MARK: Refusals (TE87)

    @Test func wordsAcrossTwoLinesAreRefused() throws {
        let file = invoice()
        let (page, box) = try page(file)
        let across = try #require(page.selection(from: CGPoint(x: 280, y: 604), to: CGPoint(x: 120, y: 584)))
        #expect(across.string?.contains("Client") == true, "the selection is one line — this tests nothing")
        #expect(EditorPDFReplace.pick(across, page: page, index: 0, box: box) == .failure(.severalLines))
    }

    /// **Words whose layer says one place and whose print another** — here, words drawn and then
    /// painted over: the text layer still has them, the page shows nothing there.
    @Test func wordsTheLayerHasWhereNothingIsPrintedAreRefused() throws {
        let file = path("Hidden.pdf")
        ReplaceFixtures.write(file, lines: [.init(text: "Visible words", at: CGPoint(x: 72, y: 700)),
                                            .init(text: "Painted over", at: CGPoint(x: 72, y: 600))],
                              coverWith: CGRect(x: 60, y: 590, width: 200, height: 30))
        #expect(try pick(file, at: CGPoint(x: 90, y: 604)) == .failure(.brokenTextLayer))
        guard case .success = try pick(file, at: CGPoint(x: 90, y: 704)) else { Issue.record("the visible words were refused"); return }
    }

    @Test func wordsInsideAFormFieldAreRefused() throws {
        let file = invoice()
        let (page, box) = try page(file)
        let line = try #require(EditorPDFReplace.line(at: CGPoint(x: 300, y: 604), on: page, box: box))
        #expect(EditorPDFReplace.pick(line, page: page, index: 0, box: box, widgets: [CGRect(x: 250, y: 595, width: 120, height: 20)])
                == .failure(.inFormField))
        guard case .success = EditorPDFReplace.pick(line, page: page, index: 0, box: box, widgets: [CGRect(x: 400, y: 100, width: 50, height: 20)])
        else { Issue.record("a field elsewhere on the page refused the words"); return }
    }

    @Test func eachRefusalSaysWhy() {
        #expect(EditorPDFReplaceRefusal.noText.reason == "There’s no text on this page to replace.")
        #expect(EditorPDFReplaceRefusal.severalLines.reason == "Pick words on one line.")
        #expect(EditorPDFReplaceRefusal.brokenTextLayer.reason.contains("doesn’t line up with what’s printed"))
        #expect(EditorPDFFillSign.formReplaceReason.hasPrefix("This PDF has a fillable form."))
    }

    /// **A fillable form turns Replace off, with its reason** (decision AV), and so does Fill & Sign's
    /// own refusal; a flat file has it.
    @Test func aFormTurnsReplaceOff() async throws {
        let flat = try await open(invoice())
        #expect(flat.fill.replaceRefusal == nil)
        let formFile = path("Form fields.pdf")
        try PDFFixtures.writeForm(formFile)
        let form = try await open(formFile)
        #expect(form.fill.form.hasFields, "the fixture has no form — this tests nothing")
        #expect(form.fill.replaceRefusal == EditorPDFFillSign.formReplaceReason)
        form.fill.toggle()
        let (page, box) = try page(invoice("Any.pdf"))
        let line = try #require(EditorPDFReplace.line(at: CGPoint(x: 300, y: 604), on: page, box: box))
        guard case .success(let pick) = EditorPDFReplace.pick(line, page: page, index: 0, box: box) else { return }
        #expect(form.fill.beginCorrection(pick) == nil, "a correction went onto a form")
    }

    // MARK: Retyping (TE83)

    private func correcting(_ file: String, at point: CGPoint = CGPoint(x: 300, y: 604)) async throws
        -> (EditorPDFDocument, UUID, EditorPDFReplacePick) {
        let pdf = try await open(file)
        pdf.fill.toggle()
        pdf.fill.armed = .replace
        guard case .success(let pick) = try pick(file, at: point) else { throw CancellationError() }
        let id = try #require(pdf.fill.beginCorrection(pick))
        return (pdf, id, pick)
    }

    /// **The box opens over the words, holding them, in their face, size and ink.**
    @Test func theRetypeBoxOpensOverTheWordsHoldingThem() async throws {
        let (pdf, id, pick) = try await correcting(invoice())
        let fill = pdf.fill
        let item = try #require(fill.items.first { $0.id == id })
        #expect(fill.editing == id && fill.selection == id)
        #expect(item.words?.string == "14 March 2026")
        #expect(item.fontSize == 14 && item.toolkitFont == .named("Helvetica"))
        #expect(item.ink == pick.ink)
        // Its words' baseline is the old words': the box's top less the layout's baseline offset.
        let face = item.nsFont(size: 14)
        #expect(abs(item.rect.maxY - EditorPDFFillSign.baselineOffset(face) - 600) < 0.01, "box \(item.rect)")
        #expect(abs(item.rect.minX - pick.left) < 0.01)
        #expect(fill.unsavedCaption == "1 correction not saved" && fill.saveTitle == "Save Corrected Copy")
    }

    /// **Return places the correction — one undo step; Esc leaves the page as it was.**
    @Test func returnPlacesItAndEscLeavesThePageAsItWas() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let fill = pdf.fill
        fill.cancelEditing()
        #expect(fill.items.isEmpty && fill.editing == nil, "Esc kept the correction")
        #expect(!fill.undoManager.canUndo, "Esc left an undo step")

        guard case .success(let again) = try pick(pdf.path!, at: CGPoint(x: 300, y: 604)) else { return }
        let second = try #require(fill.beginCorrection(again))
        fill.type("21 March 2026", into: second)
        fill.endEditing()
        #expect(fill.items.first?.correction?.words == "21 March 2026")
        #expect(fill.undoManager.undoActionName == "Replace Text")
        fill.undoManager.undo()
        #expect(fill.items.isEmpty, "⌘Z did not take the correction back")
        fill.undoManager.redo()
        #expect(fill.items.first?.correction?.words == "21 March 2026")
        _ = id

        // Retyped again, then Esc: the words it had.
        fill.beginEditing(second)
        fill.type("28 March 2026", into: second)
        fill.cancelEditing()
        #expect(fill.items.first?.correction?.words == "21 March 2026", "Esc kept the second retyping")
    }

    /// **Words already corrected open their correction again** — a click on the old words' place
    /// past the end of shorter new ones must not lay a second patch on the first.
    @Test func wordsAlreadyCorrectedOpenTheirCorrection() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        guard case .success(let again) = try pick(pdf.path!, at: CGPoint(x: 330, y: 604)) else { Issue.record("refused"); return }
        #expect(again.words == "14 March 2026", "the click picked other words — this tests nothing")
        #expect(fill.beginCorrection(again) == id)
        #expect(fill.items.count == 1 && fill.editing == id)
        #expect(fill.items.first?.correction?.words == "21 Apr")
    }

    /// **Return with the words as they were changes nothing**: the correction goes.
    @Test func placingTheWordsAsTheyWereLeavesNothing() async throws {
        let (pdf, _, _) = try await correcting(invoice())
        pdf.fill.endEditing()
        #expect(pdf.fill.items.isEmpty)
        #expect(!pdf.fill.undoManager.canUndo)
    }

    /// **Size, Ink and Aa work as for text — and a correction keeps its baseline and place.**
    @Test func sizeInkAndFontWorkAndTheBaselineHolds() async throws {
        let (pdf, id, pick) = try await correcting(invoice())
        let fill = pdf.fill
        fill.type("21 March 2026", into: id)
        fill.endEditing()
        fill.select(id)
        func item() -> EditorPDFFillItem { fill.items.first { $0.id == id }! }
        func baseline() -> CGFloat { item().rect.maxY - EditorPDFFillSign.baselineOffset(item().nsFont(size: item().fontSize)) }

        fill.setFontSize(18)
        #expect(item().fontSize == 18)
        #expect(abs(baseline() - 600) < 0.01 && abs(item().rect.minX - pick.left) < 0.01, "a new size moved the words")

        fill.setColor(.blue)
        #expect(item().ink == EditorPDFRGB(red: 26 / 255, green: 61 / 255, blue: 143 / 255))
        fill.useOriginalInk()
        #expect(item().ink == pick.ink)

        #expect(fill.styleTarget == .correction(id))
        fill.setTextFont(.mono)
        #expect(item().toolkitFont == .systemMonospaced && !(item().correction?.isSameFont ?? true))
        #expect(fill.textFont == .sans, "a correction's font became the next text's")
        fill.useOriginalFont()
        #expect(item().toolkitFont == .named("Helvetica"))
        #expect(abs(baseline() - 600) < 0.01)

        // Not dragged, not nudged: it stays over the words it covers.
        let before = item().rect
        fill.nudge(dx: 10, dy: 0)
        fill.moveLive(id, to: before.offsetBy(dx: 40, dy: 40))
        #expect(item().rect == before)
    }

    /// **The Aa and Ink flyouts offer the original first, ticked while it is used.**
    @Test func theFlyoutsOfferTheOriginal() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let fill = pdf.fill
        fill.type("21 March 2026", into: id)
        fill.endEditing()
        fill.select(id)
        let style = EditorPDFFillFlyouts.style(for: fill).items
        #expect(style.first?.title == "Font of this correction")
        #expect(style.dropFirst().first?.title == "Original — Helvetica" && style.dropFirst().first?.state == .on)
        #expect(style.filter { $0.state == .on }.count == 1)
        let ink = EditorPDFFillFlyouts.ink(for: fill).items
        #expect(ink.first?.title == EditorPDFFillFlyouts.originalInkTitle && ink.first?.state == .on)
        #expect(ink.filter { $0.state == .on }.count == 1)
        // Chosen: the original's tick goes to the choice.
        (EditorPDFFillFlyouts.ink(for: fill).items.first { $0.title == EditorPDFFillColor.black.title } as? EditorClosureMenuItem)
            .map { _ = $0.target?.perform($0.action, with: $0) }
        #expect(EditorPDFFillFlyouts.ink(for: fill).items.first?.state == .off)
    }

    /// **The line under the box: the original's name and "Same font", or its stand-in.**
    @Test func theLineUnderTheBoxSaysSameFontOrStandIn() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let item = try #require(pdf.fill.items.first { $0.id == id })
        let same = EditorPDFRetypeHint.lines(for: item, correction: try #require(item.correction))
        #expect(same.font == "Helvetica · 14 pt · red" && same.chip == "Same font")

        let missing = invoice("Adelle line.pdf")
        try ReplaceFixtures.rename(missing, font: "Helvetica", to: "Adelle-Rg")
        let (other, otherID, _) = try await correcting(missing)
        let stand = try #require(other.fill.items.first { $0.id == otherID })
        let lines = EditorPDFRetypeHint.lines(for: stand, correction: try #require(stand.correction))
        #expect(lines.font == "Adelle isn’t on this Mac, using Serif · 14 pt · red", "\(lines.font)")
        #expect(lines.chip == "Stand-in")
    }

    // MARK: Saving (TE84, TE85)

    private func render(_ file: String, in rect: CGRect) throws -> EditorPDFReplace.Pixels {
        let (page, box) = try page(file)
        return try #require(EditorPDFReplace.render(rect, page: page, box: box))
    }

    /// Pixels in `rect` (display space) at least `far` from white.
    private func ink(_ file: String, in rect: CGRect, far: CGFloat = 0.3) throws -> Int {
        let pixels = try render(file, in: rect)
        var count = 0
        for y in 0..<pixels.height { for x in 0..<pixels.width where pixels.color(x: x, y: y).distance(to: .white) > far { count += 1 } }
        return count
    }

    /// **Save Corrected Copy writes "(corrected)": the old words hidden under the patch, the new ones
    /// drawn over it — and the original untouched.** The covered words are still in the copy's text.
    @Test func saveWritesACorrectedCopy() async throws {
        let file = invoice()
        let original = try Data(contentsOf: URL(fileURLWithPath: file))
        let (pdf, id, pick) = try await correcting(file)
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        #expect(fill.correctionNotes.first?.line == "“14 March 2026” is still in the copy, under the patch. Search and copy will find it.")
        let outcome = await fill.save()
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect((copy as NSString).lastPathComponent == "Invoice (corrected).pdf")
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == original)
        let text = PDFDocument(url: URL(fileURLWithPath: copy))?.string ?? ""
        #expect(text.contains("21 Apr"))
        #expect(text.contains("14 March 2026"), "the covered words left the copy's text — the note card says they stay")
        // "2026" was right of where "21 Apr" ends: in the copy, nothing is printed there.
        let tail = CGRect(x: pick.left + 50, y: pick.cover.minY + 1, width: pick.cover.maxX - pick.left - 51, height: pick.cover.height - 2)
        #expect(try ink(file, in: tail) > 20, "the original has no ink where its words end — this tests nothing")
        #expect(try ink(copy, in: tail) == 0, "the old words show past the new ones")
        #expect(try ink(copy, in: CGRect(x: pick.left, y: pick.baseline, width: 40, height: 10)) > 20, "the new words are not on their line")
    }

    /// **The same words retyped in the same face land on the old ones** — the copy, rendered, is
    /// the original's pixels within antialiasing. A box a point off, or a baseline, shows here.
    @Test func theSameWordsRetypedLandOnTheOldOnes() throws {
        let file = invoice()
        guard case .success(let pick) = try pick(file, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        let (_, box) = try page(file)
        var item = EditorPDFFillItem(page: 0, rect: pick.wordsRect, content: .correction(EditorPDFCorrection(pick)),
                                     fontSize: pick.fontSize, color: .black, font: pick.standIn)
        EditorPDFFillSign.resizeToWords(&item, in: box)
        let data = try PDFToolkit.fillAndSignData(inputURL: URL(fileURLWithPath: file), items: item.toolkitItems(on: box))
        let copy = path("Same words.pdf")
        try data.write(to: URL(fileURLWithPath: copy))
        let before = try render(file, in: pick.cover), after = try render(copy, in: pick.cover)
        var inked = 0, moved = 0
        for y in 0..<before.height {
            for x in 0..<before.width {
                let a = before.color(x: x, y: y), b = after.color(x: x, y: y)
                if a.distance(to: .white) > 0.3 { inked += 1 }
                if a.distance(to: b) > 0.3 { moved += 1 }
            }
        }
        #expect(inked > 100, "nothing is printed in the cover — this tests nothing")
        #expect(Double(moved) < 0.1 * Double(inked), "\(moved) of \(inked) inked pixels moved")
    }

    /// **Make Page 1 a Picture**: the copy's page is a picture — the covered words are gone, and so
    /// is its text — and the note card and ⌘Z go with it (decision AK).
    @Test func makingThePageAPictureTakesTheCoveredWordsOut() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        #expect(fill.correctionNotes.map(\.button) == ["Remove It: Make Page 1 a Picture"])
        fill.setPicture(0, true)
        #expect(fill.correctionNotes.first?.pictured == true && fill.correctionNotes.first?.button == "Keep Page 1 as Text")
        fill.undoManager.undo()
        #expect(fill.pictures.isEmpty, "⌘Z kept the page a picture")
        fill.undoManager.redo()
        #expect(fill.pictures == [0])
        let outcome = await fill.save()
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        let text = (PDFDocument(url: URL(fileURLWithPath: copy))?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!text.contains("14 March 2026") && text.isEmpty, "the page still has text: \(text)")
        #expect(try ink(copy, in: CGRect(x: 260, y: 600, width: 30, height: 10)) > 10, "the picture lost the new words")
    }

    /// **A picture chosen for a page whose correction is gone is not made.**
    @Test func aPictureGoesWithItsPagesLastCorrection() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        fill.setPicture(0, true)
        fill.select(id)
        fill.deleteSelection()
        #expect(fill.correctionNotes.isEmpty && fill.picturesToSave.isEmpty)
    }

    /// **Next to a signature, "(signed)" wins; with other items the button is Save Filled Copy.**
    @Test func aSignatureStillMakesItSigned() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        fill.armed = .signature(EditorPDFSignature(kind: .initials, look: .typed("AM")))
        fill.place(at: CGPoint(x: 400, y: 200), page: 0)
        #expect(fill.unsavedCaption == "1 item and 1 correction not saved")
        #expect(fill.saveTitle == "Save Filled Copy")
        let outcome = await fill.save()
        guard case .wrote(let copy) = outcome else { Issue.record("\(outcome)"); return }
        #expect((copy as NSString).lastPathComponent == "Invoice (signed).pdf")
    }

    @Test func theToolSaysCorrectedAndLogsCounts() {
        let patch = FillSignItem(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 20),
                                 content: .patch(FillSignPatch(red: 1, green: 1, blue: 1)))
        let words = FillSignItem(pageIndex: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 20),
                                 content: .text(FillSignText(string: "SECRET-WOMBAT", fontSize: 12, red: 0, green: 0, blue: 0)))
        #expect(EditorPDFTool.fillAndSign([patch, words]).suffix == "corrected")
        #expect(EditorPDFTool.fillAndSign([patch, words]).logDetail == "fill and sign (1 correction)")
        #expect(EditorPDFTool.fillAndSign([patch, words, words], pictures: [0]).logDetail
                == "fill and sign (1 item, 1 correction, page 1 made a picture)")
        #expect(EditorPDFToolEngine.refusal(.fillAndSign([patch, words], pictures: [3]), pageCount: 2)
                == PDFOperationError.pageOutOfBounds(4).errorDescription)
    }

    // MARK: The pages (TE82)

    private func reader(_ pdf: EditorPDFDocument) -> (NSWindow, ReaderPDFView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let reader = ReaderPDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        window.contentView = reader
        reader.autoScales = false
        reader.fit = nil
        reader.document = pdf.document
        reader.scaleFactor = 1
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        reader.fillSign = pdf.fill
        return (window, reader)
    }

    /// **A click with Replace on the page opens the box over the words under it; a click on a page
    /// with no text says why in the note card.**
    @Test func aClickOnThePagePicksAndAPageWithNoTextSaysWhy() async throws {
        let pdf = try await open(invoice())
        let (window, reader) = reader(pdf)
        pdf.fill.toggle()
        pdf.fill.armed = .replace
        let overlay = reader.fillOverlay
        let page = try #require(pdf.document?.page(at: 0))
        let at = reader.convert(CGPoint(x: 300, y: 604), from: page)
        #expect(overlay.hitTest(at) === overlay)
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: reader.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        overlay.mouseMoved(with: event(.mouseMoved, at: at))
        #expect(overlay.replaceOutline?.rect.contains(CGPoint(x: 300, y: 604)) == true, "no dashed outline under the pointer")
        overlay.mouseDown(with: event(.leftMouseDown, at: at))
        overlay.mouseUp(with: event(.leftMouseUp, at: at))
        #expect(pdf.fill.editing != nil && pdf.fill.items.first?.correction?.covered == "14 March 2026")
        for _ in 0..<20 { await Task.yield() }
        #expect(overlay.field != nil && overlay.retypeHint != nil, "no retype box, or no line under it")
        #expect(overlay.retypeHint?.lines.chip == "Same font")
        pdf.fill.cancelEditing()
        reader.fillSign = nil

        let blank = path("Scan.pdf")
        PDFFixtures.write(blank, pages: 1, text: false)
        let scan = try await open(blank)
        let (scanWindow, scanReader) = self.reader(scan)
        scan.fill.toggle()
        scan.fill.armed = .replace
        let scanPage = try #require(scan.document?.page(at: 0))
        let point = scanReader.convert(CGPoint(x: 300, y: 400), from: scanPage)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: scanReader.convert(point, to: nil), modifierFlags: [],
                                      timestamp: 0, windowNumber: scanWindow.windowNumber, context: nil, eventNumber: 0,
                                      clickCount: 1, pressure: 1)!
        scanReader.fillOverlay.mouseDown(with: down)
        scanReader.fillOverlay.mouseUp(with: down)
        #expect(scan.fill.replaceNote == EditorPDFReplaceRefusal.noText.reason)
        #expect(scan.fill.replaceNotes.contains(EditorPDFReplaceRefusal.noText.reason))
        scan.fill.armed = .text
        #expect(scan.fill.replaceNote == nil, "the note outlived Replace")
        scanReader.fillSign = nil
    }

    /// **A placed correction is reached as text is**: VoiceOver names it, its right-click menu
    /// offers Retype with its font and size, and Return on it — selected by Tab — opens its box.
    @Test func aCorrectionIsReachedAsTextIs() async throws {
        let pdf = try await open(invoice())
        let (_, reader) = reader(pdf)
        pdf.fill.toggle()
        pdf.fill.armed = .replace
        guard case .success(let pick) = try pick(pdf.path!, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        let id = try #require(pdf.fill.beginCorrection(pick))
        pdf.fill.type("21 Apr", into: id)
        pdf.fill.endEditing()
        let item = try #require(pdf.fill.items.first)
        #expect(item.spokenName(among: []) == "Correction, 21 Apr")
        pdf.fill.select(id)
        let menu = EditorPDFFillFlyouts.itemMenu(for: pdf.fill)
        #expect(menu.items.map(\.title).prefix(4) == [EditorPDFFillFlyouts.retypeTitle, "", "Font", "Text Size"], "\(menu.items.map(\.title))")
        #expect(pdf.fill.editing == nil)
        #expect(reader.fillOverlay.returnPressed(), "Return on a selected correction did nothing")
        #expect(pdf.fill.editing == id)
        pdf.fill.cancelEditing()
        reader.fillSign = nil
    }

    /// **Right-click ▸ Replace Text… turns Fill & Sign on with the words picked** — and is greyed,
    /// its reason under it, for words across two lines or on a form.
    @Test func rightClickReplaceTextTurnsFillAndSignOn() async throws {
        let pdf = try await open(invoice())
        let page = try #require(pdf.document?.page(at: 0))
        let box = try #require(pdf.fill.box(0))
        let words = try #require(EditorPDFReplace.line(at: CGPoint(x: 300, y: 604), on: page, box: box))
        let items = try #require(ReaderPDFView.replaceItems(fill: pdf.fill, selection: words, document: pdf.document))
        #expect(items.map(\.title) == [ReaderPDFView.replaceTitle] && items.first?.action != nil)
        #expect(!pdf.fill.isOn)
        let item = try #require(items.first as? EditorClosureMenuItem)
        _ = item.target?.perform(item.action, with: item)
        #expect(pdf.fill.isOn && pdf.fill.armed == .replace)
        #expect(pdf.fill.editing != nil && pdf.fill.items.first?.correction?.covered == "14 March 2026")

        let across = try #require(page.selection(from: CGPoint(x: 280, y: 604), to: CGPoint(x: 120, y: 584)))
        let greyed = try #require(ReaderPDFView.replaceItems(fill: pdf.fill, selection: across, document: pdf.document))
        #expect(greyed.map(\.title) == [ReaderPDFView.replaceTitle, EditorPDFReplaceRefusal.severalLines.reason])
        #expect(greyed.allSatisfy { $0.action == nil }, "a refused Replace Text… is live")
    }
}
