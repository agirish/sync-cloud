import Testing
import AppKit
import Design
import SwiftUI
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

    /// **Every refusal has a menu line** (PD14): one clause under 40 characters with no full stop,
    /// for the right-click menu's row, which does not wrap — the page's reasons and each sentence
    /// the file's refusal can be. The long sentence stays for the note card and the tooltip.
    @Test func everyRefusalHasAShortMenuLine() {
        func isMenuLine(_ line: String) -> Bool { line.count < 40 && !line.contains(".") && !line.isEmpty }
        for refusal in EditorPDFReplaceRefusal.allCases {
            #expect(isMenuLine(refusal.menuReason) && refusal.menuReason != refusal.reason,
                    "\(refusal): “\(refusal.menuReason)” (\(refusal.menuReason.count))")
        }
        let fileReasons = [EditorPDFTools.lockedReason, EditorPDFFillSign.restrictedReason,
                           EditorPDFFillSign.nothingToFillReason, EditorPDFFillSign.formReplaceReason]
        for reason in fileReasons {
            let line = EditorPDFFillSign.replaceMenuLine(reason)
            #expect(isMenuLine(line) && line != reason, "“\(reason)” → “\(line)” (\(line.count))")
        }
        #expect(EditorPDFFillSign.replaceMenuLine(EditorPDFTools.lockedReason) == "Remove the password first")
        #expect(EditorPDFReplaceRefusal.brokenTextLayer.menuReason == "This page’s text doesn’t line up")
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
        // Right-click on its words: greyed, with the short reason — a menu row does not wrap (PD14).
        let formPage = try #require(form.document?.page(at: 0))
        let all = try #require(formPage.selection(for: formPage.bounds(for: .mediaBox)))
        try #require(!(all.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the form has no words to select")
        let row = try #require(ReaderPDFView.replaceItems(fill: form.fill, selection: all, document: form.document))
        #expect(row.map(\.title) == [ReaderPDFView.replaceTitle, EditorPDFFillSign.formReplaceMenuReason])
        #expect(row.allSatisfy { $0.action == nil })
        // The short line's whole sentence is its tooltip, and the greyed item's (F-E4).
        #expect(row.map(\.toolTip) == [EditorPDFFillSign.formReplaceReason, EditorPDFFillSign.formReplaceReason])
        #expect(EditorPDFFillSign.formReplaceMenuReason.count < 40 && !EditorPDFFillSign.formReplaceMenuReason.contains(". "))
        // A file locked to open, and one whose owner restricted editing: short too, not the
        // refusal's two sentences.
        let flatPage = try #require(flat.document?.page(at: 0))
        let words = try #require(flatPage.selection(for: flatPage.bounds(for: .mediaBox)))
        for (encryption, line) in [(PDFEncryptionState.lockedToOpen, "Remove the password first"),
                                   (.restrictedOnly, EditorPDFFillSign.restrictedTitle)] {
            let refused = EditorPDFFillSign(store: EditorPDFSignatureStore(defaults: defaults))
            refused.attach(path: flat.path!, boxes: flat.fill.boxes, encryption: encryption, allowsFilling: false)
            try #require(refused.replaceRefusal != nil, "\(encryption) did not refuse Replace")
            let row = try #require(ReaderPDFView.replaceItems(fill: refused, selection: words, document: flat.document))
            #expect(row.map(\.title) == [ReaderPDFView.replaceTitle, line], "\(encryption)")
            #expect(row.allSatisfy { $0.toolTip == refused.replaceRefusal }, "\(encryption): \(row.map(\.toolTip))")
        }
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

    /// **The line under a corrected one is a line of its own**, in tightly set text. A pick
    /// reopened any correction whose cover touched its words' box — a box the font's size tall,
    /// which in lines set under about 1.1 em apart, as invoices and forms often are, reaches the
    /// cover above — so the second line could never be corrected.
    @Test func theLineUnderACorrectedOneIsCorrectedOnItsOwn() async throws {
        let file = path("Tight.pdf")
        ReplaceFixtures.write(file, lines: [
            .init(text: "14 March 2026", at: CGPoint(x: 260, y: 600), font: "Helvetica", color: Self.dark),
            .init(text: "15 April 2026", at: CGPoint(x: 260, y: 585.5), font: "Helvetica", color: Self.dark),
        ], ground: .none)
        let (pdf, first, _) = try await correcting(file)
        let fill = pdf.fill
        fill.type("21 March 2026", into: first)
        fill.endEditing()
        guard case .success(let below) = try pick(file, at: CGPoint(x: 300, y: 589)) else { Issue.record("refused"); return }
        #expect(below.words == "15 April 2026", "the click picked other words — this tests nothing")
        try #require(fill.items.first?.correction?.cover.intersects(below.wordsRect) == true,
                     "the lines are not close enough to touch — this tests nothing")
        let second = fill.beginCorrection(below)
        #expect(second != nil && second != first, "the line below reopened the one above")
        #expect(fill.items.count == 2)
    }

    /// **Esc after a style change while retyping leaves nothing to undo.** Text Size chosen with the
    /// box open took an undo step of its own, holding the half-typed words, so ⌘Z after Esc brought
    /// back the correction Esc had cancelled.
    @Test func escAfterAStyleChangeLeavesNoStepThatBringsItBack() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let fill = pdf.fill
        fill.type("21", into: id)
        fill.setFontSize(18)
        fill.cancelEditing()
        #expect(fill.items.isEmpty)
        #expect(!fill.undoManager.canUndo, "an undo step outlived the Esc: \(fill.undoManager.undoActionName)")
        if fill.undoManager.canUndo { fill.undoManager.undo() }
        #expect(fill.items.isEmpty, "⌘Z after Esc brought the cancelled correction back")
    }

    /// **A reload that now has a form drops the corrections, and says so.** Replace is off on a
    /// form, so the save refused them on every try and only Discard got out.
    @Test func aReloadThatGainsAFormDropsTheCorrections() async throws {
        let (pdf, id, _) = try await correcting(invoice())
        let fill = pdf.fill
        fill.type("21 March 2026", into: id)
        fill.endEditing()
        try #require(fill.items.count == 1)
        let path = try #require(pdf.path)
        let field = FormField(name: "name", kind: .text(multiline: false), value: nil,
                              widgets: [FormField.Widget(pageIndex: 0, rect: CGRect(x: 10, y: 10, width: 100, height: 20))])
        let log = LogCapture()
        fill.attach(path: path, boxes: fill.boxes, encryption: .none, allowsFilling: true,
                    form: EditorPDFForm(fields: [field]))
        #expect(fill.items.isEmpty && !fill.hasUnsavedChanges)
        #expect(pdf.tools.banner?.message == "The file changed on disk and now has a fillable form, so your corrections were dropped.")
        #expect(await log.holds(containing: "Edit dropped 1 correction with Fill & Sign on Invoice.pdf"))
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

        let nextTextSize = fill.fontSize
        fill.setFontSize(18)
        #expect(item().fontSize == 18)
        #expect(abs(baseline() - 600) < 0.01 && abs(item().rect.minX - pick.left) < 0.01, "a new size moved the words")
        #expect(fill.fontSize == nextTextSize, "a correction's size became the next text's")

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

    /// **With Replace chosen and nothing selected, Style, Text Size and Ink grey out** — in the
    /// palette and in File ▸ Fill & Sign Tool — since the next correction starts in the covered
    /// words' face, size and ink whatever they say. A correction selected, they change it again.
    @Test func replaceWithNothingSelectedGreysStyleSizeAndInk() async throws {
        typealias P = EditorPDFFillPalette
        let file = invoice()
        let pdf = try await open(file)
        let fill = pdf.fill
        fill.toggle()
        let styling: [P.Tool] = [.style, .size, .ink]
        // The menu bar's Ink and Text Size lines, live or not, as AppKit builds them.
        func menuLive() throws -> [String: Bool] {
            let menu = NSHostingMenu(rootView: EditorPDFFillSignMenuItems(fill: fill, tools: pdf.tools))
            menu.update()
            let tool = try #require(menu.items.first { $0.title == EditorPDFFillToolMenu.title }?.submenu)
            tool.update()
            var live: [String: Bool] = [:]
            for name in ["Ink", "Text Size"] {
                let lines = try #require(tool.items.first { $0.title == name }?.submenu)
                lines.update()
                // Smaller and Bigger grey at the ends of the sizes; the choices never do.
                let choices = lines.items.filter { !$0.isSeparatorItem && $0.title != EditorPDFFillFlyouts.smallerTitle
                    && $0.title != EditorPDFFillFlyouts.biggerTitle }
                try #require(choices.count == (name == "Ink" ? EditorPDFFillColor.allCases.count : EditorPDFFillSign.fontSizes.count),
                             "\(name): \(choices.map(\.title))")
                live[name] = choices.allSatisfy(\.isEnabled) ? true : choices.contains(where: \.isEnabled) ? nil : false
            }
            return live
        }

        fill.armed = .text
        #expect(styling.allSatisfy { P.refusal($0, fill: fill) == nil }, "Text's next item takes them")
        #expect(try menuLive() == ["Ink": true, "Text Size": true])

        fill.armed = .replace
        #expect(P.refusal(.style, fill: fill) == "Style — a correction starts in the covered words’ font, or a stand-in for it; select one to change it")
        #expect(P.refusal(.size, fill: fill) == "Text Size — a correction starts at the covered words’ size; select one to change it")
        #expect(P.refusal(.ink, fill: fill) == "Ink — a correction starts in the covered words’ ink; select one to change it")
        #expect(try menuLive() == ["Ink": false, "Text Size": false])

        // The premise: what they would have set reaches no correction.
        fill.setColor(.black)
        fill.setFontSize(30)
        fill.setTextFont(.mono)
        guard case .success(let pick) = try pick(file, at: CGPoint(x: 300, y: 604)) else { throw CancellationError() }
        let id = try #require(fill.beginCorrection(pick))
        let item = try #require(fill.items.first { $0.id == id })
        #expect(item.ink == pick.ink && item.fontSize == pick.fontSize && item.toolkitFont == .named("Helvetica"))

        // Selected — retyping, then clicked again — the tools are the correction's.
        #expect(styling.allSatisfy { P.refusal($0, fill: fill) == nil }, "the open correction's tools stayed greyed")
        #expect(try menuLive() == ["Ink": true, "Text Size": true])
        fill.type("21 March 2026", into: id)
        fill.endEditing()
        fill.select(nil)
        #expect(P.refusal(.ink, fill: fill) != nil)
        fill.select(id)
        #expect(styling.allSatisfy { P.refusal($0, fill: fill) == nil }, "a selected correction's tools stayed greyed")
        #expect(try menuLive() == ["Ink": true, "Text Size": true])
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

    /// **The line under the box follows View ▸ Text Size, and its chip's words read on their wash**
    /// (PD4, DS13). Fixed 10 and 11 points ignored the setting. The chip's words are drawn in the
    /// label's ink, its hue kept to the wash: the bare system green and orange on their own 16% wash
    /// measured 1.95:1 and 2.02:1 on the light window ground (white), and the hue made readable
    /// (`ChromeInk.bodyText`) fell short of AA on a 0.96 sheet.
    @Test func theLineUnderTheBoxFollowsTextSizeAndItsChipReads() throws {
        let one = EditorPDFRetypeHint.fonts(scale: 1), larger = EditorPDFRetypeHint.fonts(scale: 1.5)
        #expect(one.font.pointSize == 11 && one.chip.pointSize == 10 && one.keys.pointSize == 10)
        #expect(larger.font.pointSize > 15 && larger.chip.pointSize > 14 && larger.keys.pointSize > 14,
                "\(larger.font.pointSize), \(larger.chip.pointSize), \(larger.keys.pointSize)")
        let hint = EditorPDFRetypeHint()
        hint.lines = .init(font: "Helvetica · 14 pt · red", chip: EditorPDFRetypeHint.sameFontChip, sameFont: true,
                           keys: EditorPDFRetypeHint.keysLine)
        let small = hint.fittingSize
        hint.scale = 1.5
        // The words grow by half; the card's fixed padding does not. Measured 199×44 → 266×56.
        #expect(hint.fittingSize.height > small.height * 1.2 && hint.fittingSize.width > small.width * 1.25,
                "\(small) → \(hint.fittingSize)")

        // The ink the draw uses, read off the chip's own line.
        let drawn = try #require(hint.chipLine.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        func srgb(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB) ?? color }
        /// `top` over `ground` at `alpha` times its own alpha — the label's ink carries one.
        func over(_ top: NSColor, _ alpha: CGFloat, _ ground: NSColor) -> NSColor {
            let (t, g) = (srgb(top), srgb(ground))
            let a = alpha * t.alphaComponent
            func mix(_ h: CGFloat, _ b: CGFloat) -> CGFloat { h * a + b * (1 - a) }
            return NSColor(srgbRed: mix(t.redComponent, g.redComponent), green: mix(t.greenComponent, g.greenComponent),
                           blue: mix(t.blueComponent, g.blueComponent), alpha: 1)
        }
        func luminance(_ c: NSColor) -> CGFloat {
            let s = srgb(c)
            return AccentLabel.relativeLuminance(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent)
        }
        func contrast(_ x: NSColor, _ y: NSColor) -> CGFloat {
            let (l1, l2) = (luminance(x), luminance(y))
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        // The card's own ground in each appearance, and in light a 0.96 sheet too.
        let sheet = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            for sameFont in [true, false] {
                var ratios: [(String, CGFloat)] = []
                appearance.performAsCurrentDrawingAppearance {
                    let grounds: [(String, NSColor)] = dark ? [("window", .windowBackgroundColor)]
                        : [("window", .windowBackgroundColor), ("0.96", sheet)]
                    for (name, ground) in grounds {
                        let hue = EditorPDFRetypeHint.chipHue(sameFont: sameFont)
                        let wash = over(hue, EditorPDFRetypeHint.chipWashAlpha, ground)
                        ratios.append((name, contrast(over(drawn, 1, wash), wash)))
                    }
                }
                #expect(ratios.count == (dark ? 1 : 2))
                for (ground, ratio) in ratios {
                    #expect(ratio >= 4.5, "\(dark ? "dark" : "light") \(ground) \(sameFont ? "Same font" : "Stand-in"): \(ratio):1")
                }
            }
        }
    }

    /// **The text size reaches the hint from the card's environment** — the page view hands it to
    /// the overlay, and the overlay to the hint it lays out.
    @Test func theTextSizeReachesTheLineUnderTheBox() async throws {
        let pdf = try await open(invoice())
        let host = NSHostingView(rootView: EditorPDFPageView(document: pdf.document, state: pdf.view)
            .environment(\.appFontScale, 1.5).frame(width: 600, height: 500))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> ReaderPDFView? {
            (view as? ReaderPDFView) ?? view.subviews.lazy.compactMap(find).first
        }
        let mounted = try #require(find(host))
        #expect(mounted.fillOverlay.textScale == 1.5)

        let (_, reader) = reader(pdf)
        reader.fillOverlay.textScale = 1.5
        pdf.fill.toggle()
        pdf.fill.armed = .replace
        guard case .success(let pick) = try pick(pdf.path!, at: CGPoint(x: 300, y: 604)) else { Issue.record("refused"); return }
        _ = try #require(pdf.fill.beginCorrection(pick))
        for _ in 0..<20 { await Task.yield() }
        let hint = try #require(reader.fillOverlay.retypeHint, "no line under the box")
        #expect(hint.scale == 1.5)
        reader.fillOverlay.textScale = 1
        #expect(hint.scale == 1, "a change of text size left the open hint at the old size")
    }

    /// **The line under the box wraps inside the reader** — at the largest text size, with a
    /// stand-in's long line, in a reader 260 points wide, the card stays 4 points in from each edge.
    /// Pinned at the box's left and never wrapped, it ran past the right edge.
    @Test func theLineUnderTheBoxWrapsInsideANarrowReader() async throws {
        let largest = CGFloat(FontSize.maximumPercent) / 100
        let missing = invoice("Adelle narrow.pdf")
        try ReplaceFixtures.rename(missing, font: "Helvetica", to: "Adelle-Rg")
        let pdf = try await open(missing)
        let (window, reader) = reader(pdf)
        window.setContentSize(NSSize(width: 260, height: 500))
        reader.frame = CGRect(x: 0, y: 0, width: 260, height: 500)
        reader.layoutDocumentView()
        reader.layoutSubtreeIfNeeded()
        reader.fillOverlay.textScale = largest
        pdf.fill.toggle()
        pdf.fill.armed = .replace
        guard case .success(let pick) = try pick(missing, at: CGPoint(x: 100, y: 604)) else { Issue.record("refused"); return }
        _ = try #require(pdf.fill.beginCorrection(pick))
        for _ in 0..<20 { await Task.yield() }
        let hint = try #require(reader.fillOverlay.retypeHint, "no line under the box")
        let overlay = reader.fillOverlay.bounds
        try #require(overlay.width == 260, "the overlay is \(overlay.width) wide")
        #expect(hint.lines.font.hasPrefix("Adelle isn’t on this Mac") && hint.scale == largest, "\(hint.lines.font)")

        // Unbounded, the card is wider than the reader — so the bound is what keeps it in.
        let open = EditorPDFRetypeHint()
        open.scale = largest
        open.lines = hint.lines
        try #require(open.fittingSize.width > overlay.width, "the fixture's line fits unwrapped: \(open.fittingSize)")
        #expect(hint.frame.minX >= overlay.minX + 4 && hint.frame.maxX <= overlay.maxX - 4,
                "the card spans \(hint.frame.minX)…\(hint.frame.maxX) in a reader 0…\(overlay.width)")
        // Wrapped, not squeezed: the font line takes more than one line, and every part sits
        // inside the card, the chip beside the words and level with their first line.
        let parts = hint.placement(), oneLine = EditorPDFRetypeHint.measure(
            NSAttributedString(string: "Ag", attributes: [.font: EditorPDFRetypeHint.fonts(scale: largest).font]),
            width: .greatestFiniteMagnitude).height
        #expect(parts.font.height > oneLine * 1.5, "the font line is \(parts.font.height) tall, one line \(oneLine)")
        #expect(parts.size == hint.frame.size)
        for (name, rect) in [("font", parts.font), ("chip", parts.chip), ("keys", parts.keys)] {
            #expect(rect.minX >= 0 && rect.maxX <= parts.size.width && rect.minY >= 0 && rect.maxY <= parts.size.height,
                    "\(name) \(rect) in a card \(parts.size)")
        }
        #expect(parts.chip.minX >= parts.font.maxX && parts.chip.maxY >= parts.font.maxY - 1, "chip \(parts.chip), font \(parts.font)")

        // Drawn as placed: the words reach the font line's last line, under the chip's row.
        let rep = try #require(hint.bitmapImageRepForCachingDisplay(in: hint.bounds))
        hint.cacheDisplay(in: hint.bounds, to: rep)
        let px = CGFloat(rep.pixelsWide) / hint.bounds.width
        // The card's own ground, inside its border, in whichever appearance the host runs.
        let ground = try #require(rep.colorAt(x: Int(4 * px), y: rep.pixelsHigh / 2)).brightnessComponent
        func ink(in rect: CGRect) -> Int {
            var count = 0
            for y in Int(rect.minY * px)..<Int(rect.maxY * px) {
                for x in Int(rect.minX * px)..<Int(rect.maxX * px) {
                    // Bitmap rows run down from the top; the card's y runs up.
                    guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - y) else { continue }
                    if abs(c.brightnessComponent - ground) > 0.4 { count += 1 }
                }
            }
            return count
        }
        let lastLine = CGRect(x: parts.font.minX, y: parts.font.minY, width: parts.font.width, height: oneLine)
        #expect(ink(in: lastLine) > 20, "no words drawn on the font line's last line, \(lastLine)")
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

    /// **A correction over a link says the link still opens where it did (FR56)** — the toolkit puts
    /// the page's links back on the copy, so the old address stays live under the new words. Both
    /// halves measured: the copy keeps the link when the page stays text, and loses it when the page
    /// is made a picture, whose note therefore doesn't say it.
    @Test func aCorrectionOverALinkSaysTheLinkStillOpens() async throws {
        let file = invoice("Linked.pdf")
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        let link = PDFAnnotation(bounds: CGRect(x: 258, y: 598, width: 100, height: 12), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/old")
        try #require(document.page(at: 0)).addAnnotation(link)
        try #require(document.write(to: URL(fileURLWithPath: file)))
        func links(_ copy: String) -> [String] {
            (PDFDocument(url: URL(fileURLWithPath: copy))?.page(at: 0)?.annotations ?? [])
                .filter { $0.type == "Link" }.compactMap { $0.url?.absoluteString }
        }
        try #require(links(file) == ["https://example.com/old"], "the fixture has no link — this tests nothing")
        // The line under it has no link under its patch.
        guard case .success(let clear) = try pick(file, at: CGPoint(x: 100, y: 584)) else { Issue.record("refused"); return }
        #expect(!clear.overLink, "a patch with no link under it said it has one")

        let (pdf, id, pick) = try await correcting(file)
        #expect(pick.overLink, "the link under the words was not seen")
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        #expect(fill.correctionNotes.first?.line == "“14 March 2026” is still in the copy, under the patch. "
                + "Search and copy will find it. " + EditorPDFFillSign.linkUnderPatchNote)
        fill.setPicture(0, true)
        #expect(fill.correctionNotes.first?.line.contains(EditorPDFFillSign.linkUnderPatchNote) == false,
                "a page made a picture loses its links, yet its note says one stays")
        guard case .wrote(let pictured) = await fill.save() else { Issue.record("the pictured copy was not written"); return }
        #expect(links(pictured).isEmpty, "the picture kept the link — its note should say so")

        let (again, againID, _) = try await correcting(file)
        again.fill.type("21 Apr", into: againID)
        again.fill.endEditing()
        guard case .wrote(let copy) = await again.fill.save() else { Issue.record("the copy was not written"); return }
        #expect(links(copy) == ["https://example.com/old"], "the copy dropped the link — the note says it stays")
    }

    /// **"Also remove links under corrections" leaves no link under a patch in the copy (FR56,
    /// decided 2026-10-25)** — off by default, offered only for a correction over a link, and for
    /// that save only. A link elsewhere on the page stays.
    @Test func removingLinksUnderCorrectionsLeavesNoneUnderAPatch() async throws {
        let file = invoice("Unlinked.pdf")
        let document = try #require(PDFDocument(url: URL(fileURLWithPath: file)))
        let original = try #require(document.page(at: 0))
        for (rect, address) in [(CGRect(x: 258, y: 598, width: 100, height: 12), "https://example.com/old"),
                                (CGRect(x: 70, y: 716, width: 160, height: 24), "https://example.com/kept")] {
            let link = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
            link.url = URL(string: address)
            original.addAnnotation(link)
        }
        try #require(document.write(to: URL(fileURLWithPath: file)))
        func links(_ copy: String) -> [PDFAnnotation] {
            (PDFDocument(url: URL(fileURLWithPath: copy))?.page(at: 0)?.annotations ?? []).filter { $0.type == "Link" }
        }
        try #require(links(file).count == 2, "the fixture has no links — this tests nothing")

        // Not offered for a correction with no link under it.
        let (plain, plainID, plainPick) = try await correcting(file, at: CGPoint(x: 100, y: 584))
        try #require(!plainPick.overLink)
        plain.fill.type("Client Harbour & Pike Inc", into: plainID)
        plain.fill.endEditing()
        #expect(!plain.fill.offersUnlinking, "offered with no link under the patch")

        let (pdf, id, pick) = try await correcting(file)
        try #require(pick.overLink, "the link under the words was not seen")
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        #expect(fill.offersUnlinking && !fill.unlinksCorrections, "not offered, or on by default")
        // **The checkbox is in the note card and bound to the choice**: ticked, the card draws
        // differently along its last row, where the box sits — under the corrections' line, which
        // also changes, and its button, which doesn't. A fresh host each time, so nothing waits on
        // an observation to land.
        func box() throws -> [NSColor?] {
            let host = NSHostingView(rootView: EditorPDFFillSaveStack(fill: fill, tools: pdf.tools))
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let px = CGFloat(rep.pixelsWide) / host.bounds.width
            // Bitmap rows run down from the top: the stack's last 22pt, the width of it.
            let rows = Int((host.bounds.height - 22) * px)..<rep.pixelsHigh
            return rows.flatMap { y in (0..<rep.pixelsWide).map { rep.colorAt(x: $0, y: y) } }
        }
        let unticked = try box()
        fill.unlinksCorrections = true
        let ticked = try box()
        #expect(zip(unticked, ticked).filter { $0 != $1 }.count > 20,
                "the card's last row draws the same ticked and unticked — no checkbox bound to the choice")
        #expect(fill.correctionNotes.first?.line.hasSuffix(" " + EditorPDFFillSign.linkRemovedNote) == true,
                "the note still says the link stays: \(fill.correctionNotes.first?.line ?? "none")")
        guard case .wrote(let copy) = await fill.save() else { Issue.record("the copy was not written"); return }
        let left = links(copy)
        #expect(!left.contains { $0.bounds.intersects(pick.cover) }, "a link under the patch is still in the copy")
        #expect(left.compactMap { $0.url?.absoluteString } == ["https://example.com/kept"],
                "the link away from the patch went too, or the old one stayed")
        #expect(!fill.unlinksCorrections, "the choice outlived its save")
    }

    /// **"Keep comments as comments" is in the note card, bound to the choice, and greyed while a
    /// page is saved as a picture (FR57)** — the picture pass would rewrite them — saying why.
    /// Unticked then, whatever was chosen: ticking it draws nothing different; making the page text
    /// again gives the choice back.
    @Test func keepingCommentsIsGreyedWhileAPageIsAPicture() async throws {
        let file = invoice("Commented.pdf")
        // In the PDFKit lane, as the app's reads and writes are: off it, they race the package's
        // other PDF suites.
        let written = await PDFKitSerialAccess.perform { () -> Bool in
            guard let document = PDFDocument(url: URL(fileURLWithPath: file)), let page = document.page(at: 0) else { return false }
            let marker = PDFAnnotation(bounds: CGRect(x: 70, y: 716, width: 160, height: 24), forType: .highlight, withProperties: nil)
            marker.color = .yellow
            page.addAnnotation(marker)
            return document.write(to: URL(fileURLWithPath: file))
        }
        try #require(written, "the fixture was not written")
        let (pdf, id, _) = try await correcting(file)
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        try #require(fill.offersKeepingComments, "not offered — this tests nothing")
        #expect(fill.keepCommentsRefusal == nil)
        // The stack drawn whole, in a fresh host each time: at the size SwiftUI asks for, since a
        // host's `fittingSize` comes up short of the card's wrapped lines and clips its last row.
        func render() throws -> (NSBitmapImageRep, CGFloat) {
            let stack = EditorPDFFillSaveStack(fill: fill, tools: pdf.tools)
            let size = NSHostingController(rootView: stack).sizeThatFits(in: CGSize(width: 2000, height: 4000))
            let host = NSHostingView(rootView: stack)
            host.frame = CGRect(origin: .zero, size: CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up)))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return (rep, CGFloat(rep.pixelsWide) / host.bounds.width)
        }
        func drawn() throws -> [NSColor?] {
            let (rep, _) = try render()
            return (0..<rep.pixelsHigh).flatMap { y in (0..<rep.pixelsWide).map { rep.colorAt(x: $0, y: y) } }
        }
        // **The checkbox is the card's last row, bound to the choice**: ticked, the card's last 22pt
        // draw differently — under the correction's button, which doesn't change. Measured from the
        // bottom, since the comments' line at the top changes too.
        func lastRow() throws -> [NSColor?] {
            let (rep, px) = try render()
            return (rep.pixelsHigh - Int(22 * px)..<rep.pixelsHigh).flatMap { y in (0..<rep.pixelsWide).map { rep.colorAt(x: $0, y: y) } }
        }
        let unticked = try lastRow()
        fill.keepsComments = true
        let tickedRow = try lastRow()
        #expect(unticked.count == tickedRow.count && zip(unticked, tickedRow).filter { $0 != $1 }.count > 20,
                "the card's last row draws the same ticked and unticked — no checkbox bound to the choice")
        #expect(fill.keepsCommentsOnSave && fill.formNotes.contains(EditorPDFComments.commentsKeptNote))

        fill.setPicture(0, true)
        #expect(fill.keepCommentsRefusal == EditorPDFFillSign.keepCommentsPictureReason)
        #expect(!fill.keepsCommentsOnSave, "kept with a page saved as a picture")
        #expect(fill.formNotes.contains(EditorPDFComments.commentsFlattenedNote), "the card says they stay comments: \(fill.formNotes)")
        let ticked = try drawn()
        fill.keepsComments = false
        #expect(ticked == (try drawn()), "the greyed checkbox shows the reader's tick, which the save won't follow")

        fill.keepsComments = true
        fill.setPicture(0, false)
        #expect(fill.keepCommentsRefusal == nil && fill.keepsCommentsOnSave, "keeping the page as text did not give the choice back")
    }

    /// The invoice with a link under "14 March 2026" and a yellow highlight over its title — written
    /// in the PDFKit lane, as the app's reads and writes are.
    private func linkedAndCommented(_ name: String) async throws -> String {
        let file = invoice(name)
        let written = await PDFKitSerialAccess.perform { () -> Bool in
            guard let document = PDFDocument(url: URL(fileURLWithPath: file)), let page = document.page(at: 0) else { return false }
            let link = PDFAnnotation(bounds: CGRect(x: 258, y: 598, width: 100, height: 12), forType: .link, withProperties: nil)
            link.url = URL(string: "https://example.com/old")
            page.addAnnotation(link)
            let marker = PDFAnnotation(bounds: CGRect(x: 70, y: 716, width: 160, height: 24), forType: .highlight, withProperties: nil)
            marker.color = .yellow
            page.addAnnotation(marker)
            return document.write(to: URL(fileURLWithPath: file))
        }
        try #require(written, "the fixture was not written")
        return file
    }

    /// Page 1's annotation subtypes, as the file holds them — read by CoreGraphics, in the lane.
    private func subtypes(_ data: Data) async -> [String] {
        await PDFKitSerialAccess.perform { () -> [String] in
            guard let document = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init),
                  let page = document.page(at: 1)?.dictionary else { return ["unreadable"] }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(page, "Annots", &annots), let annots else { return [] }
            return (0..<CGPDFArrayGetCount(annots)).compactMap { i in
                var annotation: CGPDFDictionaryRef?
                var name: UnsafePointer<CChar>?
                guard CGPDFArrayGetDictionary(annots, i, &annotation), let annotation,
                      CGPDFDictionaryGetName(annotation, "Subtype", &name), let name else { return nil }
                return String(cString: name)
            }.sorted()
        }
    }

    /// **"Keep comments as comments" is greyed while "Also remove links under corrections" is
    /// ticked over a link (F1)** — taking the link out rewrites the copy through PDFKit, which
    /// rewrites a kept comment and, on macOS 26, drops what the keep tooltip says stays — saying
    /// why, and the save with both ticked draws the comments in and takes the link out. Unticking
    /// the links gives the choice back. The log names what was done, not what was asked (F4).
    @Test func keepingCommentsIsGreyedWhileLinksUnderCorrectionsAreRemoved() async throws {
        let file = try await linkedAndCommented("Both.pdf")
        let (pdf, id, pick) = try await correcting(file)
        try #require(pick.overLink, "the link under the words was not seen — this tests nothing")
        let fill = pdf.fill
        fill.type("21 Apr", into: id)
        fill.endEditing()
        try #require(fill.offersKeepingComments && fill.offersUnlinking, "not both offered — this tests nothing")
        fill.keepsComments = true
        #expect(fill.keepCommentsRefusal == nil && fill.keepsCommentsOnSave, "refused with the links left in")
        fill.unlinksCorrections = true
        #expect(fill.keepCommentsRefusal == EditorPDFFillSign.keepCommentsUnlinkReason)
        #expect(!fill.keepsCommentsOnSave, "kept with a link under a patch to take out")
        #expect(fill.formNotes.contains(EditorPDFComments.commentsFlattenedNote), "the card says they stay comments: \(fill.formNotes)")
        // Greyed and unticked on screen: the reader's tick draws nothing, as the picture case's.
        func drawn() throws -> [NSColor?] {
            let stack = EditorPDFFillSaveStack(fill: fill, tools: pdf.tools)
            let size = NSHostingController(rootView: stack).sizeThatFits(in: CGSize(width: 2000, height: 4000))
            let host = NSHostingView(rootView: stack)
            host.frame = CGRect(origin: .zero, size: CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up)))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return (0..<rep.pixelsHigh).flatMap { y in (0..<rep.pixelsWide).map { rep.colorAt(x: $0, y: y) } }
        }
        let ticked = try drawn()
        fill.keepsComments = false
        #expect(ticked == (try drawn()), "the greyed checkbox shows the reader's tick, which the save won't follow")
        fill.unlinksCorrections = false
        fill.keepsComments = true
        #expect(fill.keepCommentsRefusal == nil && fill.keepsCommentsOnSave, "unticking the links did not give the choice back")
        fill.unlinksCorrections = true

        let log = LogCapture()
        guard case .wrote(let copy) = await fill.save() else { Issue.record("the copy was not written"); return }
        let data = try Data(contentsOf: URL(fileURLWithPath: copy))
        #expect(await subtypes(data).isEmpty, "the highlight was kept, or the link stayed")
        let addresses = await PDFKitSerialAccess.perform { () -> [String] in
            (PDFDocument(data: data)?.page(at: 0)?.annotations ?? []).filter { $0.type == "Link" }.compactMap { $0.url?.absoluteString }
        }
        #expect(!addresses.contains("https://example.com/old"), "the link under the patch is still in the copy")
        let wrote = try #require(await log.entries.first { $0.message.contains("Edit wrote Both") }, "the save was not logged")
        // The save asked for nothing it couldn't do, and the log claims nothing kept.
        #expect(wrote.message.contains("links under corrections removed") && !wrote.message.contains("comments kept")
                && !wrote.message.contains("keep comments"), "\(wrote.message)")
    }

    /// **The engine draws the comments in when a link under a patch is taken out (F1)**, for any
    /// caller — and keeps them when asked to take links out with none under the patch, which
    /// would rewrite nothing. The fixture can tell the two apart. Called in the lane.
    @Test func theEngineDrawsCommentsInWhenALinkUnderAPatchGoes() async throws {
        let file = try await linkedAndCommented("Engine.pdf")
        let input = URL(fileURLWithPath: file)
        let staging = URL(fileURLWithPath: folder)
        func copy(patchAt rect: CGRect) async throws -> (data: Data, comments: FillSignAnnotations?) {
            let patch = FillSignItem(pageIndex: 0, rect: rect, content: .patch(FillSignPatch(red: 1, green: 1, blue: 1)))
            let result = await PDFKitSerialAccess.perform { () -> (Data, FillSignAnnotations?)? in
                guard case .bytes(let data, _, let comments)? = try? EditorPDFToolEngine.output(
                    of: .fillAndSign([patch], unlinksPatches: true, keepsComments: true), input: input,
                    staging: staging, progress: nil, isCancelled: nil) else { return nil }
                return (data, comments)
            }
            let (data, comments) = try #require(result, "the engine wrote nothing")
            return (data, comments)
        }
        let clear = try await copy(patchAt: CGRect(x: 70, y: 400, width: 100, height: 20))
        try #require(await subtypes(clear.data) == ["Highlight", "Link"], "kept with no link to take out — this tests nothing")
        #expect(clear.comments == .keep)
        let over = try await copy(patchAt: CGRect(x: 256, y: 596, width: 104, height: 18))
        #expect(await subtypes(over.data).isEmpty, "the highlight was kept beside a link taken out, or the link stayed")
        #expect(over.comments == .flatten, "the run says they were kept")
    }

    /// **The engine finds a link under a patch on a turned page** — the toolkit puts links back
    /// upright, so the patch's page rect is mapped before the test — and, from macOS 27, the copy
    /// keeps the page labels the toolkit carried. Assembled by hand: a page turned 90° labelled "i",
    /// with one link under the patch and one away from it.
    @Test func linksUnderAPatchGoOnATurnedPageAndTheLabelsStay() async throws {
        let file = path("Turned.pdf")
        let stream = "BT /F1 14 Tf 100 305 Td (Old address) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 /Contents 4 0 R"
                + " /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R 7 0 R] >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Link /Rect [100 300 200 320] /Border [0 0 0] /A << /S /URI /URI (https://example.com/old) >> >>",
            "<< /Type /Annot /Subtype /Link /Rect [400 600 500 620] /Border [0 0 0] /A << /S /URI /URI (https://example.com/kept) >> >>",
        ]
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: URL(fileURLWithPath: file))

        let patch = FillSignItem(pageIndex: 0, rect: CGRect(x: 100, y: 300, width: 100, height: 20),
                                 content: .patch(FillSignPatch(red: 1, green: 1, blue: 1)))
        // **In the PDFKit lane, as the app runs it** (`output(of:)` is "called from the lane"): run
        // beside the package's other PDFKit suites, a write here raced their reads — PDF find and
        // the picture-deck OCR went red in full runs. Only Sendable facts leave the lane.
        struct Seen: Sendable { var kept: [String]; var keptLabel: String?; var unlinked: [String]; var unlinkedLabel: String? }
        let input = URL(fileURLWithPath: file)
        let seen: Seen? = await PDFKitSerialAccess.perform {
            // The document, not its page: a page outliving its document reads nothing.
            func copy(unlinking: Bool) -> PDFDocument? {
                guard case .bytes(let data, _, _)? = try? EditorPDFToolEngine.output(
                    of: .fillAndSign([patch], unlinksPatches: unlinking), input: input,
                    progress: nil, isCancelled: nil),
                    let document = PDFDocument(data: data), document.pageCount == 1 else { return nil }
                return document
            }
            func addresses(_ document: PDFDocument) -> [String] {
                (document.page(at: 0)?.annotations ?? []).filter { $0.type == "Link" }.compactMap { $0.url?.absoluteString }.sorted()
            }
            guard let kept = copy(unlinking: false), let unlinked = copy(unlinking: true) else { return nil }
            return Seen(kept: addresses(kept), keptLabel: kept.page(at: 0)?.label,
                        unlinked: addresses(unlinked), unlinkedLabel: unlinked.page(at: 0)?.label)
        }
        let facts = try #require(seen, "the engine wrote no one-page copy")
        try #require(facts.kept == ["https://example.com/kept", "https://example.com/old"],
                     "the toolkit did not put both links back — this tests nothing")
        try #require(facts.keptLabel == "i", "the toolkit did not carry the page label — this tests nothing")
        #expect(facts.unlinked == ["https://example.com/kept"], "the link under the patch on a turned page stayed")
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            #expect(facts.unlinkedLabel == "i", "the rewrite dropped the page label on macOS 27 too — the tooltip says only 26")
        }
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
        // A mix is filled, as the button says — Save Filled Copy (decided 2026-10-21).
        #expect(EditorPDFTool.fillAndSign([patch, words, words]).suffix == "filled")
        #expect(EditorPDFTool.fillForm(values: [:], items: [patch, words]).suffix == "filled")
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
        // VoiceOver's action is the menu's word, not the text box's Edit Text (PD5).
        let spoken = (reader.fillOverlay.accessibilityChildren() ?? []).compactMap { $0 as? EditorPDFFillAccessibilityElement }
        let element = spoken.first { $0.accessibilityLabel() == "Correction, 21 Apr" }
        #expect(element?.accessibilityCustomActions()?.first?.name == EditorPDFFillFlyouts.retypeTitle,
                "\(spoken.map { ($0.accessibilityLabel() ?? "", $0.accessibilityCustomActions()?.map(\.name) ?? []) })")
        #expect(pdf.fill.editing == nil)
        #expect(reader.fillOverlay.returnPressed(), "Return on a selected correction did nothing")
        #expect(pdf.fill.editing == id)
        pdf.fill.cancelEditing()
        reader.fillSign = nil
    }

    /// **Return with Replace chosen and nothing selected says how to pick words** — in the note card
    /// and to VoiceOver. It did nothing at all: Replace has no spot of its own, as the other tools do.
    @Test func returnWithReplaceAndNothingSelectedSaysHowToPick() async throws {
        let pdf = try await open(invoice())
        let (_, reader) = reader(pdf)
        pdf.fill.toggle()
        pdf.fill.armed = .replace
        var heard: [String] = []
        reader.fillOverlay.announce = { heard.append($0) }
        #expect(reader.fillOverlay.returnPressed(), "Return with Replace chosen was not taken")
        #expect(pdf.fill.replaceNotes == ["Click or drag across the words to replace."])
        #expect(heard == ["Click or drag across the words to replace."])
        #expect(pdf.fill.items.isEmpty)
        pdf.fill.armed = .text
        #expect(pdf.fill.replaceNotes.isEmpty, "the note outlived Replace")
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
        #expect(greyed.map(\.title) == [ReaderPDFView.replaceTitle, "Pick words on one line"])
        #expect(greyed.allSatisfy { $0.action == nil }, "a refused Replace Text… is live")
        #expect(greyed.allSatisfy { $0.toolTip == EditorPDFReplaceRefusal.severalLines.reason },
                "a short refusal row has no tooltip with its whole sentence: \(greyed.map(\.toolTip))")
        #expect(items.first?.toolTip == nil, "a live Replace Text… carries a refusal's tooltip")
    }
}
