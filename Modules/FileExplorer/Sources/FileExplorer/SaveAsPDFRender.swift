import AppKit
import CoreGraphics
import os
import Design
import Events
import PDFKit
import Sync
import SwiftUI
import WebKit

/// What one file became.
struct SaveAsPDFOutput: Sendable, Equatable {
    var data: Data
    var pageCount: Int
    /// A deck's pages that carried no selectable text: slides that were pictures in the file
    /// itself, so their pages are pictures too. The banner says so.
    var picturePages: Int
    /// Pictures whose words Vision read, now laid invisibly over them (``PictureText``): the PDF
    /// can be searched, with the odd misread, and the banner says that instead.
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
    /// WebKit stopped answering part-way: its web process alive but not running (``WedgeGuard``).
    static let stalled = SaveAsPDFFailure(reason: "macOS stopped answering while drawing it")
}

/// The engines behind Save as PDF, one per ``SaveAsPDFKind``, all ending in PDF bytes and none
/// touching the original.
///
/// - Text and Markdown are ``DocumentPDF``, Edit's own Print render, so the pages match Edit's.
/// - Rich text is Apple's text system, paginated by AppKit's print system.
/// - Word, Excel and PowerPoint go through Quick Look. No public API hands back a document's
///   pages, but `qlmanage -p -o` writes the HTML Quick Look previews from, and this app is not
///   sandboxed, so it can run it. WebKit then draws that HTML to PDF as vector text:
///   - a Word document is printed, WebKit breaking pages between lines at the HTML's page size
///     and margins;
///   - a sheet is cut into pages between its rows, scaled to the paper's width;
///   - a deck is one page per slide, each the slide's own `div.slide` box, never a print, which
///     paginates by height and miscounts slides.
///   Word falls back to the text system when Quick Look gives nothing.
///
/// One PDFKit read, in the lane: pages are counted and combined with CoreGraphics, which is not
/// PDFKit (see ``PDFMenuEncryption``), and which deck pages came out as pictures is asked of PDFKit
/// through `PDFKitSerialAccess`. Only those pages get their words read by Vision and laid over
/// them (``PictureText``), since a deck can mix text slides with pictures.
@MainActor
enum SaveAsPDFRender {

    /// How Edit would set the page: the reader's paper, Settings ▸ Text size, the window's accent.
    struct Settings {
        var geometry: DocumentPDF.PageGeometry = .letter
        var fontScale: CGFloat = 1
        var accent: Color = LiquidGlassHue.stored().accentColor
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

    /// The pages, counted from 0, with no selectable text: a deck's slides that were pictures in
    /// the file itself. Asked of PDFKit, in its lane. A PDF PDFKit can't open counts as all
    /// pictures.
    static func pagesWithoutText(_ data: Data) async -> Set<Int> {
        let texts: [String]? = await PDFKitSerialAccess.perform { [data] in
            guard let document = PDFDocument(data: data) else { return nil }
            return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        }
        guard let texts else { return Set(0..<pageCount(data)) }
        return Set(texts.indices.filter { texts[$0].allSatisfy(\.isWhitespace) })
    }

    // MARK: - Text and Markdown: Edit's Print render

    /// The file read as the compare pane reads text (bounded, lenient about bad bytes) and drawn by
    /// ``DocumentPDF`` as Edit's Print draws an open note.
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

    /// `text` laid out by an `NSTextView` at the content width and printed to a file: AppKit breaks
    /// pages between lines, and the text system's tables and pictures come with it.
    ///
    /// Light, and black where the file names no colour: a text view takes its default colour from
    /// the appearance, so a PDF saved in dark mode would be white on white.
    ///
    /// Laid out on the page AppKit will print, not the one asked for: the print system moves a
    /// margin the printer can't reach inward, so the page is smaller than `geometry.content`. A
    /// view sized to the asked-for page would spill a few points onto an extra blank page (with no
    /// printer, the bottom 40 points are out of reach).
    static func textSystemPDF(_ text: NSAttributedString, geometry: DocumentPDF.PageGeometry) async throws -> Data {
        let info = printInfo(paper: geometry.paper, margins: NSEdgeInsets())
        let content = printable(geometry.content, reach: info.imageablePageBounds)
        (info.topMargin, info.leftMargin) = (info.paperSize.height - content.maxY, content.minX)
        (info.bottomMargin, info.rightMargin) = (content.minY, info.paperSize.width - content.maxX)
        // Rounded down: the paper can come back a fraction short of what was set (611.99997 for 612).
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: content.width, height: content.height.rounded(.down)))
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

        let operation = NSPrintOperation(view: view, printInfo: info)
        return try await savePrint(operation, info: info) { operation.run() }
    }

    /// `content` cut to what the printer reaches, the page AppKit prints on. An empty reach, which a
    /// print system with no printers can report, leaves `content` whole.
    nonisolated static func printable(_ content: CGRect, reach: CGRect) -> CGRect {
        guard reach.width > 0, reach.height > 0 else { return content }
        let page = content.intersection(reach)
        return page.isNull ? content : page
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
            // Word's second route: the text system reads .docx and .doc itself, without pictures,
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

    /// A Word document, printed at the page the HTML describes. Quick Look draws it in one `div` as
    /// wide as the file's page, padded by its margins. The side padding stays (WebKit prints it as
    /// the margin); the top and bottom move into the print's margins, so every page gets them, not
    /// just the first and last, and a one-page memo stays one page (`aOnePageMemoIsOnePageOfText`).
    /// The `div`'s one-page minimum height is left alone: it changes no page count.
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
        // The print draws a picture still decoding blank too: on CI, a document's first picture.
        try await web.picturesDecoded()
        return try await web.print(printInfo(paper: paper, margins: margins))
    }

    /// A deck: one page per slide, each the slide's own box drawn as vector, so its text stays text
    /// and a picture slide stays the picture at full size.
    ///
    /// `pause` waits between the decode and the drawing, so tests can stand in for a loaded
    /// machine's delays.
    static func slidesPDF(_ html: URL, pause: Duration = .zero) async throws -> Data {
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
        try await web.picturesDecoded()
        if pause > .zero { try await Task.sleep(for: pause) }
        var composer = PDFComposer()
        for box in boxes {
            let slide = try await web.pdf(of: box)
            guard let page = PDFComposer.firstPage(of: slide) else { throw SaveAsPDFFailure.noPages }
            composer.add(page, paper: box.size, into: CGRect(origin: .zero, size: box.size))
        }
        guard let data = composer.finish() else { throw SaveAsPDFFailure.noPages }
        return data
    }

    /// A workbook: every sheet, in tab order, each cut into pages between its rows. With one sheet
    /// the page is Quick Look's page itself; with several it is a tab strip framing one sheet at a
    /// time, each tab naming its sheet's page in the bundle.
    static func sheetsPDF(_ html: URL, geometry: DocumentPDF.PageGeometry) async throws -> Data {
        let sheets = QuickLookHTML.sheetPages(in: html)
        var composer = PDFComposer()
        for sheet in sheets.isEmpty ? [html] : sheets {
            try await addSheet(sheet, to: &composer, geometry: geometry)
        }
        guard let data = composer.finish() else { throw SaveAsPDFFailure.noPages }
        return data
    }

    /// One sheet, scaled so its full width fits the page (landscape when it is wider than the page
    /// is tall), and broken at the last row that fits, so no row is cut unless taller than a page.
    ///
    /// Scaled, not printed: WebKit's print clips columns past the paper's width, and CSS zoom
    /// shrinks the columns but not the type, so cells overlap. Each page is `createPDF` of one band
    /// at the sheet's own width, as vector text, so small print zooms sharp.
    static func addSheet(_ html: URL, to composer: inout PDFComposer, geometry: DocumentPDF.PageGeometry) async throws {
        // Loaded into a view smaller than any sheet, so the scroll size is the sheet's own: a
        // document is never smaller than its view, so a usual-size view would pad a small sheet
        // into landscape or blank pages. Measuring the tables alone would lose text a last cell
        // spills past the table's edge. Columns are fixed widths, so the small view wraps nothing.
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

        // The deck's race again: without the wait, pictures lower down a sheet can draw blank.
        try await web.picturesDecoded()

        let layout = SheetLayout(contentWidth: width, contentHeight: height, rowBottoms: rows, geometry: geometry)
        // A `createPDF` per band, each the band alone. One of the whole sheet comes back as pages
        // of at most 14,400 points, and cutting those up would put every clipped row's text into
        // the PDF again, so search finds rows twice and the file balloons. A band takes ~0.04 s in
        // the app; in a test process with no `NSApplication`, WebKit throttles it to seconds.
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

    /// Runs `operation` to a scratch file and hands back its bytes. `run` starts it: synchronously
    /// for a view AppKit prints itself, through a window for WebKit's.
    static func savePrint(_ operation: NSPrintOperation, info: NSPrintInfo,
                          run: () async throws -> Bool) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SaveAsPDF-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
        // Handed over again after the disposition is set: an operation keeps its own copy.
        operation.printInfo = info
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard try await run(), let data = try? Data(contentsOf: file), !data.isEmpty else { throw SaveAsPDFFailure.noPages }
        return data
    }

    nonisolated static func pageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return 0 }
        return document.numberOfPages
    }
}

/// A Word page's paper, from the width Quick Look gave it: Letter and A4 either way up, by width
/// in points (the HTML's pixel width). Any other width that fits the reader's paper prints on it,
/// since a file naming no page size gets Quick Look's 600, which is no real paper. Wider than that,
/// the page keeps the reader's paper's proportion.
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

/// How a sheet is cut into pages. Pure, so the rule is tested on numbers rather than through
/// WebKit.
struct SheetLayout: Equatable {
    /// The paper, turned to landscape when the sheet is wider than the portrait page's content.
    let paper: CGSize
    let content: CGRect
    /// Sheet pixels to page points, never above 1: a narrow sheet prints at its own size.
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

/// Pages drawn into one PDF with CoreGraphics. `drawPDFPage` copies a page's content stream, so
/// text stays text. Not PDFKit, so outside the lane.
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

/// Quick Look's preview of an Office file, as the HTML it draws from.
///
/// `qlmanage -p -o <folder> <file>` writes `<name>.qlpreview/` (`Preview.html`, its stylesheets,
/// and pictures as `AttachmentN` files) and nothing else. It is Apple's debugging tool, not an
/// API, so its output can change in any release; `SaveAsPDFRenderTests` pins it on fixtures.
enum QuickLookHTML {
    static let tool = "/usr/bin/qlmanage"
    /// Under a second for Word and Excel, up to ~2 s for a large deck, and under 10 s even twenty
    /// at a time on a loaded machine. A run that takes 30 s has wedged.
    static let timeout: TimeInterval = 30
    /// A wedged `qlmanage` is killed and run once more. Rarely a run never finishes, its
    /// file-coordination thread parked in `-[QLPreview synchronousGetData]` for a reply that never
    /// comes; it doesn't recover, but the next run of the same file works (`docs/flaky-tests.md`,
    /// "A Quick Look run that waits for ever on its own reply").
    static let attempts = 2

    /// The preview's `Preview.html`, or `nil` when Quick Look made none. `folder` must be empty:
    /// the bundle is found as the one thing in it. `tool` and `timeout` are for tests.
    nonisolated static func preview(of file: String, into folder: URL, tool: String = tool,
                                    timeout: TimeInterval = timeout) async -> URL? {
        for attempt in 1...attempts {
            guard let killed = await run(tool, file, into: folder, timeout: timeout) else { return nil }
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            if let bundle = items.first(where: { $0.pathExtension == "qlpreview" }),
               FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Preview.html").path) {
                return bundle.appendingPathComponent("Preview.html")
            }
            guard killed else { return nil }
            Logger.shared.warning("Save as PDF: Quick Look didn’t finish in \(Int(timeout)) s (try \(attempt) of \(attempts))")
            // Whatever the wedged run left would be taken for the next one's bundle.
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
        return nil
    }

    /// Runs `qlmanage` once: whether the guard had to kill it, or `nil` if it couldn't start.
    nonisolated private static func run(_ tool: String, _ file: String, into folder: URL,
                                        timeout: TimeInterval) async -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-p", "-o", folder.path, file]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Set by the guard: a wedged qlmanage handles SIGTERM and exits 0, so its status can't say.
        let killed = OSAllocatedUnfairLock(initialState: false)
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
                guard process.isRunning else { return }
                killed.withLock { $0 = true }
                process.terminate()
                // qlmanage ends on SIGTERM; anything that doesn't must not hold the caller for ever.
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        guard started else { return nil }
        return killed.withLock { $0 }
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

/// An offscreen WebKit view that loads one file and draws it to PDF.
///
/// In a window that is never shown: WebKit's print runs against a window, and `createPDF` draws
/// what the view lays out. No network and no scripts: Quick Look's preview allows neither
/// (`AllowNetworkAccess` is false in every bundle), and a document's links are not ours to follow.
/// The measuring is the app's own script, which a page's scripts setting does not govern.
@MainActor
final class WebPDFView: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private let window: NSWindow
    private var loading: CheckedContinuation<Bool, Never>?
    private var loadGuard: WedgeGuard?
    /// The web process died: nothing it draws from here on can be trusted, so the draws refuse.
    private var terminated = false

    /// A view that can reach nothing but files — see ``offline()``.
    static func make(width: CGFloat, height: CGFloat = 1000) async -> WebPDFView {
        WebPDFView(width: width, height: height, rules: await offline())
    }

    private static var offlineRules: WKContentRuleList?

    /// Every picture `decoding = 'sync'` from the moment the parser adds it, before anything is
    /// painted. A large picture at `auto` decodes in the background when painted (and again after
    /// WebKit lets it go), and a background decode still queued when `createPDF` or the print draws
    /// it makes it draw blank, since WebKit never decodes one picture on two threads. It must be set
    /// before the load's paints: `decode()` settles when any decode finishes, so it could settle on
    /// a paint's while its own was queued (`docs/flaky-tests.md`, "A wedge guard that counts time
    /// spent waiting for the main thread"). The app's own script, which the page's scripts setting
    /// does not govern.
    static let syncPictures = """
        new MutationObserver(function (changes) {
          changes.forEach(function (change) {
            change.addedNodes.forEach(function (node) {
              if (node.nodeType !== 1) return;
              if (node.tagName === 'IMG') node.decoding = 'sync';
              node.querySelectorAll('img').forEach(function (image) { image.decoding = 'sync'; });
            });
          });
        }).observe(document, { childList: true, subtree: true });
        """

    /// Every request off the disk blocked: a navigation by the policy below, and a picture or
    /// stylesheet a page names by URL by this list, which WebKit applies to every load. Compiled
    /// once per process. **One rule per scheme**: WebKit's patterns have no `|`, and a list using
    /// one fails to compile, leaving nothing blocked.
    static func offline() async -> WKContentRuleList? {
        if let offlineRules { return offlineRules }
        let rules = ["^https?:", "^wss?:", "^ftp:"]
            .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        let list = "[" + rules.joined(separator: ",") + "]"
        offlineRules = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "SaveAsPDF.offline", encodedContentRuleList: list)
        return offlineRules
    }

    private init(width: CGFloat, height: CGFloat, rules: WKContentRuleList?) {
        let configuration = WKWebViewConfiguration()
        if let rules { configuration.userContentController.add(rules) }
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.syncPictures, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
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

    /// Loads `file` with read access to its own folder (the bundle) and waits for it.
    ///
    /// The timeout is a wedge guard, not a measure of a slow load: a crashed web process ends the
    /// wait at once, and a file with nothing to fetch never hangs on its own. It is counted by
    /// ``WedgeGuard``, so time `didFinish` spends queued for a busy main thread doesn't count
    /// (`docs/flaky-tests.md`, "A wedge guard that counts time spent waiting for the main thread").
    func load(_ file: URL, timeout: TimeInterval = WedgeGuard.budget) async -> Bool {
        let loaded = await withCheckedContinuation { continuation in
            loading = continuation
            web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            loadGuard = WedgeGuard(budget: timeout) { [weak self] in
                guard let self, self.loading != nil else { return }
                Logger.shared.warning("Save as PDF: the page didn’t load in \(Int(timeout)) s; giving up on it")
                self.finishLoading(false)
            }
        }
        if loaded { holdForeground() }
        return loaded
    }

    /// Keeps the web process at foreground priority from the load to ``close()``, through a call
    /// of the app's own script that doesn't answer until then; WebKit holds a foreground activity
    /// for each script call until it answers.
    ///
    /// A hidden view's web process drops to the background band about a second after its last
    /// script call answers, and `createPDF` and the print take no foreground activity of their
    /// own, so on a busy machine a draw could starve for minutes (`docs/flaky-tests.md`, "A hidden
    /// web view's process drops to the background band, so load starves its draws").
    private func holdForeground() {
        web.callAsyncJavaScript("""
            return await new Promise(function (release) { window.saveAsPDFRelease = release; })
            """, in: nil, in: .defaultClient) { _ in }
    }

    private func finishLoading(_ loaded: Bool) {
        loadGuard?.cancel()
        loadGuard = nil
        loading?.resume(returning: loaded)
        loading = nil
    }

    /// One call into WebKit, given up on if WebKit stops answering. `start` makes the call and
    /// hands its answer to the closure it is given; the first of that answer and ``WedgeGuard``
    /// running out wins, and a late answer is dropped.
    ///
    /// WebKit has no deadline of its own: a web process alive but not running (stopped, or never
    /// given the processor) leaves `createPDF` waiting with no answer and no
    /// `webViewWebContentProcessDidTerminate` for as long as that lasts (`docs/flaky-tests.md`,
    /// "A hidden web view's process drops to the background band, so load starves its draws").
    func guarded<T: Sendable>(_ what: String, budget: TimeInterval = WedgeGuard.budget,
                              _ start: (@escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Void)
        async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let answer = Answer(continuation)
            answer.wedge = WedgeGuard(budget: budget) {
                guard answer.resume(with: .failure(SaveAsPDFFailure.stalled)) else { return }
                Logger.shared.warning("Save as PDF: WebKit didn’t finish \(what) in \(Int(budget)) s; giving up on it")
            }
            start { answer.resume(with: $0) }
        }
    }

    func resize(width: CGFloat, height: CGFloat? = nil) {
        let size = NSSize(width: max(width, 100), height: max(height ?? web.frame.height, 100))
        web.setFrameSize(size)
    }

    /// The script's string answer, parsed as JSON.
    func json(_ script: String) async throws -> Any? {
        let text: String? = try await guarded("measuring the page") { answer in
            web.evaluateJavaScript(script) { value, error in
                answer(error.map { .failure($0) } ?? .success(value as? String))
            }
        }
        guard let text else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// Every picture decoded, so `createPDF` and the print draw it, or a minute, whichever is
    /// first. A loaded page is not its pictures decoded, and an undecoded picture draws blank.
    /// `decode()` settles when a picture can be painted, and fails, settling too, for one that
    /// can't.
    ///
    /// The minute guards against a decode that never settles; when it fires, pictures still
    /// decoding draw blank, so it is logged. Shorter caps proved too short on a loaded machine.
    ///
    /// Not enough on its own: a decode WebKit queued in the background still draws blank after
    /// this settles. ``syncPictures`` keeps any from being queued.
    ///
    /// The minute is the web process's own clock, so it guards nothing once that process stops
    /// running; ``guarded(_:budget:_:)`` does.
    func picturesDecoded() async throws {
        let decoded: Bool? = try await guarded("decoding the pictures") { answer in
            web.callAsyncJavaScript("""
                return await Promise.race([
                  Promise.all(Array.from(document.images).map(function (image) {
                    return image.decode().catch(function () {});
                  })).then(function () { return true; }),
                  new Promise(function (settle) { setTimeout(function () { settle(false); }, 60000); })
                ])
                """, in: nil, in: .defaultClient) { result in
                answer(.success((try? result.get()) as? Bool))
            }
        }
        if decoded == false {
            Logger.shared.warning("Save as PDF: pictures still decoding after a minute; drawing without them")
        } else if decoded == nil {
            Logger.shared.warning("Save as PDF: couldn’t ask the page whether its pictures were decoded")
        }
    }

    func pdf(of rect: CGRect, budget: TimeInterval = WedgeGuard.budget) async throws -> Data {
        guard !terminated else { throw SaveAsPDFFailure.quickLookGaveNothing }
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        return try await guarded("drawing a page", budget: budget) { answer in
            web.createPDF(configuration: configuration) { answer($0) }
        }
    }

    /// WebKit's print of the page, to a file, against the hidden window.
    func print(_ info: NSPrintInfo, budget: TimeInterval = WedgeGuard.budget) async throws -> Data {
        guard !terminated else { throw SaveAsPDFFailure.quickLookGaveNothing }
        let operation = web.printOperation(with: info)
        operation.view?.frame = web.bounds
        return try await SaveAsPDFRender.savePrint(operation, info: info) {
            try await guarded("printing", budget: budget) { answer in
                let done = PrintDone { answer(.success($0)) }
                operation.runModal(for: window, delegate: done,
                                   didRun: #selector(PrintDone.operationDidRun(_:success:contextInfo:)),
                                   contextInfo: nil)
                // Held by the operation until it ends; the selector is all AppKit keeps.
                objc_setAssociatedObject(operation, &PrintDone.key, done, .OBJC_ASSOCIATION_RETAIN)
            }
        }
    }

    func close() {
        web.evaluateJavaScript("window.saveAsPDFRelease && window.saveAsPDFRelease()", in: nil, in: .defaultClient)
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

    /// A web process that died never reports the load either way, so fail now, not at the guard.
    /// One that dies after the load leaves a view that would draw blank, so the draws refuse too.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.shared.warning("Save as PDF: the web process drawing the file quit")
        terminated = true
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
    private let done: @MainActor @Sendable (Bool) -> Void

    init(_ done: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.done = done
    }

    /// Called on the print's own thread, not the main one.
    @objc func operationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let done = done
        DispatchQueue.main.async { MainActor.assumeIsolated { done(success) } }
    }
}

/// A call's one answer, from WebKit or its guard, whichever comes first.
@MainActor
private final class Answer<T: Sendable> {
    private var continuation: CheckedContinuation<T, Error>?
    var wedge: WedgeGuard?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// Whether this was the answer: `false` once one has been given.
    @discardableResult func resume(with result: Result<T, Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        wedge?.cancel()
        wedge = nil
        continuation.resume(with: result)
        return true
    }
}

/// A wedge guard that counts only time the main thread was free to hear the answer, which WebKit
/// hands back on the main thread.
///
/// A wall-clock deadline would count time an answer spends queued behind other main-thread work
/// as WebKit's (`docs/flaky-tests.md`, "A wedge guard that counts time spent waiting for the main
/// thread"). This one ticks on the main run loop and counts each gap between ticks only up to two
/// ticks, so a main thread held elsewhere for a minute costs the budget a second.
@MainActor
final class WedgeGuard {
    /// How long WebKit may take over one answer. Not a measure of a slow draw: with the web
    /// process in the foreground, draws on a heavily loaded machine take under 3 s.
    static let budget: TimeInterval = 120
    static let tick: TimeInterval = 0.5

    private var counted: TimeInterval = 0
    private var last = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private let budget: TimeInterval
    private let expired: @MainActor () -> Void

    /// `expired` runs once, on the main thread, when `budget` has been counted, unless ``cancel()``
    /// comes first.
    init(budget: TimeInterval, expired: @escaping @MainActor () -> Void) {
        self.budget = budget
        self.expired = expired
        // A guard let go of without `cancel()` stops its timer at the next tick.
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.ticked() }
        }
        timer.tolerance = Self.tick / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func ticked() {
        let now = ProcessInfo.processInfo.systemUptime
        counted += min(now - last, 2 * Self.tick)
        last = now
        guard counted >= budget else { return }
        cancel()
        expired()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
