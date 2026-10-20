import AppKit
import CoreGraphics
import PDFKit
import Sync
import SwiftUI
import WebKit

/// What one file became.
struct SaveAsPDFOutput: Sendable, Equatable {
    var data: Data
    var pageCount: Int
    /// A deck's pages that carried no text a reader can select — slides that were pictures in the
    /// file itself, so their pages are pictures too. The banner says so (decision AO).
    var picturePages: Int
    /// Pictures whose words Vision read, now laid invisibly over them (``PictureText``) — the PDF
    /// can be searched, with a misread here and there, and the banner says that instead.
    var isRecognised: Bool

    /// Every slide a picture.
    var isPictures: Bool { pageCount > 0 && picturePages == pageCount }
}

/// Why a file could not be saved as PDF, in the reader's words — what follows "couldn't be saved
/// as PDF:" in the banner.
struct SaveAsPDFFailure: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }

    static let quickLookGaveNothing = SaveAsPDFFailure(reason: "macOS couldn’t read it")
    static let noPages = SaveAsPDFFailure(reason: "it came out with no pages")
    static let unreadable = SaveAsPDFFailure(reason: "it couldn’t be read")
}

/// **The engines behind Save as PDF** — one per ``SaveAsPDFKind``, all ending in PDF bytes and none
/// touching the original (CV6, decision AP).
///
/// - **Text and Markdown are ``DocumentPDF``**, Edit's own Print render, handed the file's text the
///   way Edit's Print is handed the buffer's — the same pages either way.
/// - **Rich text is Apple's text system**, paginated by AppKit's print system.
/// - **Word, Excel and PowerPoint go through Quick Look.** No public API hands back a document's
///   pages, but `qlmanage -p -o` writes the HTML Quick Look draws its preview from, and this app is
///   not sandboxed, so it can run it (R1). WebKit then draws that HTML to PDF, as vector text:
///   - a Word document is printed — WebKit breaks pages between lines, at the page size and margins
///     the HTML carries from the file;
///   - a sheet is cut into pages between its rows, scaled to the paper's width;
///   - a deck is one page per slide, each the slide's own `div.slide` box at the slide's size —
///     never a print, which paginates by height and gave 15 pages for 14 slides.
///   Word falls back to the text system when Quick Look gives nothing.
///
/// **No PDFKit here but one read in the lane.** Pages are counted and combined with CoreGraphics,
/// which is not PDFKit (``PDFMenuEncryption`` measures the same distinction); which of a deck's
/// pages came out as pictures is asked of PDFKit through `PDFKitSerialAccess`, like every other
/// parse. Those pages, and only those, get their words read by Vision and laid over them
/// (``PictureText``) — a deck can mix text slides with pictures.
@MainActor
enum SaveAsPDFRender {

    /// How Edit would set the page: the reader's paper, Settings ▸ Text size, the window's accent.
    struct Settings {
        var geometry: DocumentPDF.PageGeometry = .letter
        var fontScale: CGFloat = 1
        var accent: Color = .accentColor
    }

    static func render(_ path: String, settings: Settings = Settings()) async throws -> SaveAsPDFOutput {
        guard let kind = SaveAsPDFKind.of(path: path) else { throw SaveAsPDFFailure.unreadable }
        var data: Data
        switch kind {
        case .text, .markdown:
            data = try documentPDF(path, isMarkdown: kind == .markdown, settings: settings)
        case .richText:
            data = try await textSystemPDF(try attributed(path, type: .rtf), geometry: settings.geometry)
        case .word, .spreadsheet, .presentation:
            data = try await officePDF(path, kind: kind, settings: settings)
        }
        let pages = pageCount(data)
        guard pages > 0 else { throw SaveAsPDFFailure.noPages }
        var pictures: Set<Int> = [], isRecognised = false
        if kind == .presentation {
            pictures = await Self.pagesWithoutText(data)
        }
        if !pictures.isEmpty {
            // Off the main actor: Vision blocks for every slide it reads.
            let read = await Task.detached(priority: .userInitiated) { [data, pictures] in
                PictureText.searchable(data, reading: pictures)
            }.value
            if let read {
                data = read
                isRecognised = true
            }
        }
        return SaveAsPDFOutput(data: data, pageCount: pages, picturePages: pictures.count, isRecognised: isRecognised)
    }

    /// The pages, counted from 0, with no text a reader can select — a deck's slides that were
    /// pictures in the file itself. Asked of PDFKit, in its lane. A PDF PDFKit cannot open is taken
    /// as all pictures, as the whole-deck check before it took it.
    static func pagesWithoutText(_ data: Data) async -> Set<Int> {
        let texts: [String]? = await PDFKitSerialAccess.perform { [data] in
            guard let document = PDFDocument(data: data) else { return nil }
            return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        }
        guard let texts else { return Set(0..<pageCount(data)) }
        return Set(texts.indices.filter { texts[$0].allSatisfy(\.isWhitespace) })
    }

    // MARK: - Text and Markdown: Edit's Print render

    /// The file read as the compare pane reads text — bounded, lenient about bad bytes — and drawn by
    /// ``DocumentPDF`` exactly as Edit's Print draws an open note.
    static func documentPDF(_ path: String, isMarkdown: Bool, settings: Settings) throws -> Data {
        let text: String
        switch BoundedTextRead.read(path: path) {
        case .text(let read, _, _): text = read
        case .tooLarge(let bytes):
            throw SaveAsPDFFailure(reason: "it’s too large (\(FileSyncManager.formatBytes(bytes)); "
                                   + "the limit is \(FileSyncManager.formatBytes(BoundedTextRead.maxBytes)))")
        case .binary: throw SaveAsPDFFailure(reason: "it isn’t text")
        case .cloudOnly: throw SaveAsPDFFailure(reason: "it isn’t downloaded")
        case .unreadable: throw SaveAsPDFFailure.unreadable
        }
        let job = DocumentPDF.Job(name: (path as NSString).lastPathComponent, text: text,
                                  isMarkdown: isMarkdown,
                                  // Where Edit's preview reads the note's images from.
                                  folder: EditorImageImport.linkFolder(ofNote: path),
                                  fontScale: settings.fontScale, accent: settings.accent)
        guard let data = DocumentPDF.data(for: job, geometry: settings.geometry) else { throw SaveAsPDFFailure.noPages }
        return data
    }

    // MARK: - Rich text: the text system

    static func attributed(_ path: String, type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        do {
            return try NSAttributedString(url: URL(fileURLWithPath: path),
                                          options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw SaveAsPDFFailure.unreadable
        }
    }

    /// `text` laid out by an `NSTextView` at the content width and printed to a file — AppKit breaks
    /// the pages between lines, and tables and pictures the text system holds come with it.
    ///
    /// **Light, and black where the file names no colour.** A text view takes its default colour
    /// from the appearance, and a PDF saved in dark mode would otherwise be white words on white
    /// paper.
    static func textSystemPDF(_ text: NSAttributedString, geometry: DocumentPDF.PageGeometry) async throws -> Data {
        let content = geometry.content
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: content.width, height: content.height))
        view.appearance = NSAppearance(named: .aqua)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.drawsBackground = true
        view.backgroundColor = .white
        let painted = NSMutableAttributedString(attributedString: text)
        painted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: painted.length)) { value, range, _ in
            if value == nil { painted.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        view.textStorage?.setAttributedString(painted)
        view.sizeToFit()

        let info = printInfo(paper: geometry.paper,
                             margins: NSEdgeInsets(top: geometry.paper.height - content.maxY, left: content.minX,
                                                   bottom: content.minY, right: geometry.paper.width - content.maxX))
        let operation = NSPrintOperation(view: view, printInfo: info)
        return try await savePrint(operation, info: info) { operation.run() }
    }

    // MARK: - Word, Excel, PowerPoint: Quick Look's HTML, drawn by WebKit

    /// `preview` is Quick Look; a test hands in one that makes nothing, for Word's second route.
    static func officePDF(_ path: String, kind: SaveAsPDFKind, settings: Settings,
                          preview: (String, URL) async -> URL? = { await QuickLookHTML.preview(of: $0, into: $1) })
        async throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveAsPDF-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        guard let html = await preview(path, scratch) else {
            // Word's second route: the text system reads .docx and .doc itself — without pictures,
            // headers or table layout, but every word.
            if kind == .word {
                let type: NSAttributedString.DocumentType =
                    (path as NSString).pathExtension.lowercased() == "doc" ? .docFormat : .officeOpenXML
                if let text = try? attributed(path, type: type), text.length > 0 {
                    return try await textSystemPDF(text, geometry: settings.geometry)
                }
            }
            throw SaveAsPDFFailure.quickLookGaveNothing
        }
        switch kind {
        case .presentation: return try await slidesPDF(html)
        case .spreadsheet: return try await sheetsPDF(html, geometry: settings.geometry)
        default: return try await pagePDF(html, geometry: settings.geometry)
        }
    }

    /// **A Word document: printed, at the page the HTML describes.** Quick Look draws the whole
    /// document in one `div` as wide as the file's page, padded by the file's margins. The side
    /// padding stays — it is the margin, and WebKit prints it — while the top and bottom move into
    /// the print's margins, so every page gets them rather than only the first and last. Left as
    /// padding, a one-page memo printed two (measured: the fixture's `aOnePageMemoIsOnePageOfText`
    /// goes red). The `div`'s one-page minimum height is left alone: removing it changed no page
    /// count.
    static func pagePDF(_ html: URL, geometry: DocumentPDF.PageGeometry) async throws -> Data {
        let web = await WebPDFView.make(width: geometry.paper.width)
        defer { web.close() }
        guard await web.load(html) else { throw SaveAsPDFFailure.quickLookGaveNothing }
        let page = try await web.json("""
            (function () {
              var page = document.querySelector('body > div');
              if (!page) return JSON.stringify(null);
              var style = getComputedStyle(page);
              var answer = { width: page.getBoundingClientRect().width,
                             top: parseFloat(style.paddingTop) || 0,
                             bottom: parseFloat(style.paddingBottom) || 0 };
              page.style.setProperty('padding-top', '0', 'important');
              page.style.setProperty('padding-bottom', '0', 'important');
              return JSON.stringify(answer);
            })()
            """) as? [String: Double]
        var paper = geometry.paper
        var margins = NSEdgeInsets(top: 72, left: 0, bottom: 72, right: 0)
        if let page, let width = page["width"], width >= 200 {
            paper = WordPaper.size(forWidth: width, fallback: geometry.paper)
            margins.top = min(max(page["top"] ?? 72, 18), 144)
            margins.bottom = min(max(page["bottom"] ?? 72, 18), 144)
        } else {
            // Not Quick Look's Word layout — print it inside the reader's margins.
            margins = NSEdgeInsets(top: paper.height - geometry.content.maxY, left: geometry.content.minX,
                                   bottom: geometry.content.minY, right: paper.width - geometry.content.maxX)
        }
        web.resize(width: paper.width - margins.left - margins.right)
        return try await web.print(printInfo(paper: paper, margins: margins))
    }

    /// **A deck: one page per slide**, each page the slide's own box drawn as vector — the slide's
    /// text stays text, and a slide that is a picture stays the picture at its full size.
    static func slidesPDF(_ html: URL) async throws -> Data {
        let web = await WebPDFView.make(width: 1024)
        defer { web.close() }
        guard await web.load(html) else { throw SaveAsPDFFailure.quickLookGaveNothing }
        let slides = try await web.json("""
            JSON.stringify(Array.from(document.querySelectorAll('div.slide')).map(function (slide) {
              var box = slide.getBoundingClientRect();
              return [box.left + window.scrollX, box.top + window.scrollY, box.width, box.height];
            }))
            """) as? [[Double]] ?? []
        let boxes = slides.compactMap { $0.count == 4 && $0[2] > 0 && $0[3] > 0
            ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        guard !boxes.isEmpty else { throw SaveAsPDFFailure.noPages }
        web.resize(width: (boxes.map(\.maxX).max() ?? 1024) + 16, height: (boxes.map(\.maxY).max() ?? 768) + 16)
        await web.picturesDecoded()
        var composer = PDFComposer()
        for box in boxes {
            let slide = try await web.pdf(of: box)
            guard let page = PDFComposer.firstPage(of: slide) else { throw SaveAsPDFFailure.noPages }
            composer.add(page, paper: box.size, into: CGRect(origin: .zero, size: box.size))
        }
        guard let data = composer.finish() else { throw SaveAsPDFFailure.noPages }
        return data
    }

    /// **A workbook: every sheet, in tab order, each cut into pages between its rows.** A workbook
    /// of one sheet is Quick Look's page itself; of several, the page is a tab strip framing one sheet
    /// at a time, and each tab names its sheet's own page in the bundle.
    static func sheetsPDF(_ html: URL, geometry: DocumentPDF.PageGeometry) async throws -> Data {
        let sheets = QuickLookHTML.sheetPages(in: html)
        var composer = PDFComposer()
        for sheet in sheets.isEmpty ? [html] : sheets {
            try await addSheet(sheet, to: &composer, geometry: geometry)
        }
        guard let data = composer.finish() else { throw SaveAsPDFFailure.noPages }
        return data
    }

    /// One sheet, scaled so its full width fits the page — turned to landscape when it is wider than
    /// the page is tall — and broken at the last row that fits, so no row is cut in two unless it is
    /// taller than a page.
    ///
    /// **Scaled, not printed.** WebKit's print lays a sheet out at the paper's width and clips every
    /// column past it, and CSS zoom shrank the columns but not the type, so the cells wrapped into
    /// each other (both measured 2026-10-19). Each page here is `createPDF` of one band of the sheet
    /// at its own width — vector text, so a wide sheet's small print zooms sharp.
    static func addSheet(_ html: URL, to composer: inout PDFComposer, geometry: DocumentPDF.PageGeometry) async throws {
        // **Loaded into a view smaller than any sheet, so the page's scroll size is the sheet's own.**
        // A document is never smaller than the view it is laid out in: measured in a view of a
        // usual size, a two-column sheet came out landscape and a short one ran on to blank pages.
        // Measuring the tables alone instead lost text a last cell spills past the table's edge.
        // A sheet's columns are fixed widths, so the small view wraps nothing.
        let web = await WebPDFView.make(width: 100, height: 100)
        defer { web.close() }
        guard await web.load(html) else { throw SaveAsPDFFailure.quickLookGaveNothing }
        let measure = """
            (function () {
              var root = document.documentElement, body = document.body;
              var rows = Array.from(document.querySelectorAll('tr')).map(function (row) {
                return row.getBoundingClientRect().bottom + window.scrollY;
              });
              return JSON.stringify({ width: Math.max(root.scrollWidth, body ? body.scrollWidth : 0),
                                      height: Math.max(root.scrollHeight, body ? body.scrollHeight : 0),
                                      rows: rows });
            })()
            """
        let extent = try await web.json(measure) as? [String: Any]
        let width = max((extent?["width"] as? Double) ?? 0, 1)
        // Laid out again at the sheet's own size, so every band `createPDF` draws is in the view.
        web.resize(width: width, height: max((extent?["height"] as? Double) ?? 0, 1))
        let sheet = try await web.json(measure) as? [String: Any]
        guard let sheet, let height = sheet["height"] as? Double, height > 0 else { throw SaveAsPDFFailure.noPages }
        let rows = (sheet["rows"] as? [Double]) ?? []

        // The deck's race again: without the wait, a sheet of four pictures lower down drew only one
        // to three of them, which ones changing run to run.
        await web.picturesDecoded()

        let layout = SheetLayout(contentWidth: width, contentHeight: height, rowBottoms: rows, geometry: geometry)
        // A `createPDF` per band, each the band alone: one of the whole sheet came back as pages of
        // at most 14,400 points, and cutting those into bands put every clipped row's text into the
        // PDF again — a search found rows twice, and a 4,096-row sheet's file grew to 36 MB.
        // Measured 2026-10-19: 0.04 s a band in an app; the same calls from a test process with no
        // `NSApplication`, whose views WebKit throttles, took 3 s each.
        for band in layout.bands {
            let data = try await web.pdf(of: CGRect(x: 0, y: band.lowerBound, width: width,
                                                    height: band.upperBound - band.lowerBound))
            guard let page = PDFComposer.firstPage(of: data) else { throw SaveAsPDFFailure.noPages }
            let size = CGSize(width: width * layout.scale, height: (band.upperBound - band.lowerBound) * layout.scale)
            composer.add(page, paper: layout.paper,
                         into: CGRect(x: layout.content.minX, y: layout.content.maxY - size.height,
                                      width: size.width, height: size.height))
        }
    }

    // MARK: - Printing to a file

    static func printInfo(paper: CGSize, margins: NSEdgeInsets) -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = paper
        info.orientation = paper.width > paper.height ? .landscape : .portrait
        info.topMargin = margins.top
        info.bottomMargin = margins.bottom
        info.leftMargin = margins.left
        info.rightMargin = margins.right
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// Runs `operation` to a scratch file and hands back its bytes. `run` starts it — synchronously
    /// for a view AppKit prints itself, through a window for WebKit's.
    static func savePrint(_ operation: NSPrintOperation, info: NSPrintInfo,
                          run: () async -> Bool) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SaveAsPDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        // Handed over again after the disposition is set: an operation keeps its own copy.
        operation.printInfo = info
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard await run(), let data = try? Data(contentsOf: file), !data.isEmpty else { throw SaveAsPDFFailure.noPages }
        return data
    }

    nonisolated static func pageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
}

/// **A Word page's paper, from the width Quick Look gave it** — Letter and A4 either way up by
/// their width in points, which is what the HTML's pixel width is. Any other width that fits the
/// reader's paper is printed on it: a file that names no page size gets Quick Look's own 600, which
/// is no paper anyone has. Wider than that, the page keeps the reader's paper's proportion.
enum WordPaper {
    static func size(forWidth width: Double, fallback: CGSize) -> CGSize {
        let known: [(CGFloat, CGFloat)] = [(612, 792), (595, 842), (792, 612), (842, 595)]
        if let match = known.first(where: { abs(Double($0.0) - width) <= 2 }) {
            return CGSize(width: match.0, height: match.1)
        }
        if width <= Double(fallback.width) { return fallback }
        let ratio = fallback.width > 0 ? fallback.height / fallback.width : 11 / 8.5
        return CGSize(width: width, height: (width * ratio).rounded())
    }
}

/// **How a sheet is cut into pages** — pure, so the rule is tested on numbers rather than through
/// WebKit.
struct SheetLayout: Equatable {
    /// The paper, turned to landscape when the sheet is wider than the portrait page's content.
    let paper: CGSize
    let content: CGRect
    /// Sheet pixels to page points — never above 1: a narrow sheet is printed at its own size.
    let scale: CGFloat
    /// Each page's band of the sheet, top to bottom, in the sheet's own pixels.
    let bands: [Range<Double>]

    init(contentWidth: Double, contentHeight: Double, rowBottoms: [Double], geometry: DocumentPDF.PageGeometry) {
        var paper = geometry.paper
        var content = geometry.content
        if contentWidth > content.width, paper.height > paper.width {
            // Landscape, with the margins the portrait page had.
            let left = content.minX, bottom = content.minY
            let right = paper.width - content.maxX, top = paper.height - content.maxY
            paper = CGSize(width: paper.height, height: paper.width)
            content = CGRect(x: bottom, y: right, width: paper.width - bottom - top,
                             height: paper.height - left - right)
        }
        self.paper = paper
        self.content = content
        scale = min(1, content.width / CGFloat(contentWidth))
        let pageHeight = Double(content.height / scale)
        let breaks = rowBottoms.filter { $0 > 0 && $0 < contentHeight }.sorted()
        var bands: [Range<Double>] = []
        var top = 0.0
        while top < contentHeight - 0.5 {
            let limit = top + pageHeight
            var bottom = min(limit, contentHeight)
            if limit < contentHeight, let row = breaks.last(where: { $0 > top + 0.5 && $0 <= limit }) {
                bottom = row
            }
            bands.append(top..<bottom)
            top = bottom
        }
        self.bands = bands
    }
}

/// **Pages drawn into one PDF with CoreGraphics** — `drawPDFPage` copies a page's content stream,
/// so text stays text. Not PDFKit, so outside the lane.
struct PDFComposer {
    private let data = NSMutableData()
    private var context: CGContext?

    static func document(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    static func firstPage(of data: Data) -> CGPDFPage? {
        document(data)?.page(at: 1)
    }

    /// A new page of `paper`, with `page` scaled into `rect` (bottom-left origin) and white behind it.
    /// `over` draws on top, in the paper's points.
    mutating func add(_ page: CGPDFPage, paper: CGSize, into rect: CGRect, over: (CGContext) -> Void = { _ in }) {
        if context == nil, let consumer = CGDataConsumer(data: data) {
            context = CGContext(consumer: consumer, mediaBox: nil, nil)
        }
        guard let context else { return }
        var media = CGRect(origin: .zero, size: paper)
        let box = NSData(bytes: &media, length: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(media)
        let source = page.getBoxRect(.mediaBox)
        if source.width > 0, source.height > 0 {
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / source.width, y: rect.height / source.height)
            context.translateBy(x: -source.minX, y: -source.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
        over(context)
        context.endPDFPage()
    }

    mutating func finish() -> Data? {
        guard let context else { return nil }
        context.closePDF()
        self.context = nil
        return data.length > 0 ? data as Data : nil
    }
}

/// **Quick Look's preview of an Office file, as the HTML it draws from.**
///
/// `qlmanage -p -o <folder> <file>` writes `<name>.qlpreview/` — `Preview.html`, its stylesheets
/// and pictures as `AttachmentN` files — and nothing else. It is Apple's debugging tool, not an
/// API, so its output can change in any release (R1); `SaveAsPDFRenderTests` pins it on fixtures.
enum QuickLookHTML {
    static let tool = "/usr/bin/qlmanage"
    /// Measured: under a second for Word and Excel, up to ~2 s for a large deck. A file that takes a
    /// minute has wedged the generator.
    static let timeout: TimeInterval = 60

    /// The preview's `Preview.html`, or `nil` when Quick Look made none. `folder` must be empty —
    /// the bundle is found as the one thing in it.
    nonisolated static func preview(of file: String, into folder: URL) async -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-p", "-o", folder.path, file]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started: Bool = await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume(returning: true) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
        guard started else { return nil }
        let bundles = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let bundle = bundles.first(where: { $0.pathExtension == "qlpreview" }) else { return nil }
        let html = bundle.appendingPathComponent("Preview.html")
        return FileManager.default.fileExists(atPath: html.path) ? html : nil
    }

    /// A workbook's sheets, in tab order, or none for a one-sheet preview. Each tab of Quick Look's
    /// tab strip links the page its sheet is drawn on.
    static func sheetPages(in html: URL) -> [URL] {
        guard let source = try? String(contentsOf: html, encoding: .utf8) else { return [] }
        let pattern = #"<div class="TabViewItem[^"]*">.*?<a href="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        let folder = html.deletingLastPathComponent()
        return regex.matches(in: source, range: range).compactMap { match in
            guard let link = Range(match.range(at: 1), in: source) else { return nil }
            let name = String(source[link])
            // A page in the bundle, never anything outside it.
            guard !name.contains("/"), !name.contains(":") else { return nil }
            let page = folder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: page.path) ? page : nil
        }
    }
}

/// **An offscreen WebKit view that loads one file and draws it to PDF.**
///
/// In a window that is never shown — WebKit's print runs against a window, and `createPDF` draws
/// what the view lays out. **No network and no scripts**: Quick Look's own preview allows neither
/// (`AllowNetworkAccess` is false in every bundle), and a document's links are not ours to follow.
/// The measuring below is the app's own script, which a page's scripts setting does not govern.
@MainActor
final class WebPDFView: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private let window: NSWindow
    private var loading: CheckedContinuation<Bool, Never>?

    /// A view that can reach nothing but files — see ``offline()``.
    static func make(width: CGFloat, height: CGFloat = 1000) async -> WebPDFView {
        WebPDFView(width: width, height: height, rules: await offline())
    }

    private static var offlineRules: WKContentRuleList?

    /// **Every request off the disk blocked** — a navigation is refused by the policy below, and a
    /// picture or stylesheet a page names by URL by this list, which WebKit applies to every load.
    /// Compiled once per process.
    static func offline() async -> WKContentRuleList? {
        if let offlineRules { return offlineRules }
        let rules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp):"},"action":{"type":"block"}}]"#
        offlineRules = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "SaveAsPDF.offline", encodedContentRuleList: rules)
        return offlineRules
    }

    private init(width: CGFloat, height: CGFloat, rules: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        if let rules { configuration.userContentController.add(rules) }
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.shouldPrintBackgrounds = true
        let frame = NSRect(x: 0, y: 0, width: max(width, 100), height: max(height, 100))
        web = WKWebView(frame: frame, configuration: configuration)
        web.appearance = NSAppearance(named: .aqua)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = web
        super.init()
        web.navigationDelegate = self
    }

    /// Loads `file` with read access to its own folder — the bundle — and waits for it.
    func load(_ file: URL, timeout: TimeInterval = 30) async -> Bool {
        await withCheckedContinuation { continuation in
            loading = continuation
            web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finishLoading(false) }
            }
        }
    }

    private func finishLoading(_ loaded: Bool) {
        loading?.resume(returning: loaded)
        loading = nil
    }

    func resize(width: CGFloat, height: CGFloat? = nil) {
        let size = NSSize(width: max(width, 100), height: max(height ?? web.frame.height, 100))
        web.setFrameSize(size)
    }

    /// The script's string answer, parsed as JSON.
    func json(_ script: String) async throws -> Any? {
        guard let text = try await web.evaluateJavaScript(script) as? String else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// **Every picture decoded, so `createPDF` draws it** — or ten seconds, whichever is first. A
    /// page loaded is not its pictures decoded: a deck of two 1920 px slide pictures drew its second
    /// page blank on every run, and the same box drew whole two seconds later; a sheet's bands
    /// lost pictures the same way. Word's print drew every picture without it. `decode()` settles
    /// when a picture can be painted, and fails, settling too, for one that cannot.
    func picturesDecoded() async {
        _ = try? await web.callAsyncJavaScript("""
            await Promise.race([
              Promise.all(Array.from(document.images).map(function (image) {
                return image.decode().catch(function () {});
              })),
              new Promise(function (settle) { setTimeout(settle, 10000); })
            ])
            """, contentWorld: .defaultClient)
    }

    func pdf(of rect: CGRect) async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        return try await web.pdf(configuration: configuration)
    }

    /// WebKit's print of the page, to a file, against the hidden window.
    func print(_ info: NSPrintInfo) async throws -> Data {
        let operation = web.printOperation(with: info)
        operation.view?.frame = web.bounds
        return try await SaveAsPDFRender.savePrint(operation, info: info) {
            await withCheckedContinuation { continuation in
                let done = PrintDone(continuation)
                operation.runModal(for: window, delegate: done,
                                   didRun: #selector(PrintDone.operationDidRun(_:success:contextInfo:)),
                                   contextInfo: nil)
                // Held by the operation until it ends — the selector is all AppKit keeps.
                objc_setAssociatedObject(operation, &PrintDone.key, done, .OBJC_ASSOCIATION_RETAIN)
            }
        }
    }

    func close() {
        web.stopLoading()
        web.navigationDelegate = nil
        window.contentView = nil
        window.close()
        finishLoading(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finishLoading(false)
    }

    /// Files only: a link in the document is never followed off the disk.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

/// The print operation's end, back to the `await` that started it.
private final class PrintDone: NSObject {
    nonisolated(unsafe) static var key = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @objc func operationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        continuation?.resume(returning: success)
        continuation = nil
    }
}

