import Testing
import AppKit
import PDFKit
@testable import FileExplorer
import EventsTestSupport

/// **Save as PDF's engines, read back with PDFKit** — `DocumentPDFTests`' check: the words are on
/// the pages as text, on the page they belong on, the right number of times.
///
/// **The Office fixtures pin Quick Look's output on this Mac** (R1). `qlmanage` is Apple's tool, not
/// an API; a macOS that changes what it writes turns these red rather than shipping blank PDFs. The
/// fixtures and how each was made: `Fixtures/SaveAsPDF/README.md`.
///
/// Serialized: WebKit's print runs one operation at a time per process.
@MainActor
@Suite(.serialized) struct SaveAsPDFRenderTests {

    static func fixture(_ name: String) throws -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        return try #require(Bundle.module.url(forResource: base, withExtension: ext,
                                              subdirectory: "Fixtures/SaveAsPDF"), "no fixture \(name)").path
    }

    private func read(_ output: SaveAsPDFOutput) throws -> PDFDocument {
        let document = try #require(PDFDocument(data: output.data), "the bytes are not a PDF")
        #expect(document.pageCount == output.pageCount, "the page count reported is not the PDF's")
        return document
    }

    private func pageText(_ document: PDFDocument, _ index: Int) -> String {
        document.page(at: index)?.string ?? ""
    }

    private func allText(_ document: PDFDocument) -> String {
        (0..<document.pageCount).map { pageText(document, $0) }.joined(separator: "\n")
    }

    private func occurrences(of word: String, in text: String) -> Int {
        text.components(separatedBy: word).count - 1
    }

    // MARK: Text and Markdown — Edit's Print render

    /// **A Markdown file saves as the pages Edit's Print makes of it** — the same bytes, since it is
    /// the same render handed the same text.
    @Test func markdownIsEditsPrintRender() async throws {
        let file = NSTemporaryDirectory() + "save-as-pdf-\(UUID().uuidString).md"
        let source = "# Trip notes\n\nPack the **SAVEASPDF-MD-MARKER** charger.\n"
        try source.write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }

        let output = try await SaveAsPDFRender.render(file)
        let document = try read(output)
        #expect(output.pageCount == 1)
        #expect(allText(document).contains("SAVEASPDF-MD-MARKER"))
        // The heading's marks are rendered, not printed: this is the preview, not the source.
        #expect(!allText(document).contains("# Trip"))
        let edit = try #require(DocumentPDF.data(for: DocumentPDF.Job(
            name: (file as NSString).lastPathComponent, text: source, isMarkdown: true,
            folder: (file as NSString).deletingLastPathComponent)))
        #expect(SaveAsPDFRender.pageCount(edit) == output.pageCount)
        #expect(allText(try #require(PDFDocument(data: edit))) == allText(document))
    }

    /// A `.txt` keeps its characters as typed — Markdown's syntax and all.
    @Test func plainTextKeepsItsCharacters() async throws {
        let file = NSTemporaryDirectory() + "save-as-pdf-\(UUID().uuidString).txt"
        try "# not a heading\nSAVEASPDF-TXT-MARKER\n".write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let text = allText(try read(try await SaveAsPDFRender.render(file)))
        #expect(text.contains("# not a heading"))
        #expect(text.contains("SAVEASPDF-TXT-MARKER"))
    }

    /// A file that is not text says so rather than printing mojibake.
    @Test func binaryTextFileIsRefusedInWords() async throws {
        let file = NSTemporaryDirectory() + "save-as-pdf-\(UUID().uuidString).txt"
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0]).write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        await #expect(throws: SaveAsPDFFailure(reason: "it isn’t text")) {
            _ = try await SaveAsPDFRender.render(file)
        }
    }

    // MARK: Rich text — the text system

    @Test func richTextIsText() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Memo.rtf"))
        let text = allText(try read(output))
        #expect(output.pageCount == 1)
        #expect(text.contains("Lease Renewal Heading"))
        #expect(text.contains("SAVEASPDF-WORD-MARKER"))
    }

    // MARK: Word — Quick Look's page, printed

    /// **Quick Look still writes HTML for each Office fixture** — the premise every route below
    /// stands on, pinned on its own so a macOS that changes it names the cause.
    @Test(arguments: ["Memo.docx", "Memo.doc", "Long.docx", "Budget.xlsx", "Wide.xlsx", "Deck.pptx", "Pictures.pptx",
                     "Mixed.pptx", "FourPictures.docx", "FourPictures.xlsx"])
    func quickLookStillWritesHTML(_ name: String) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let html = try #require(await QuickLookHTML.preview(of: try Self.fixture(name), into: scratch),
                                "Quick Look made no preview of \(name)")
        #expect(html.lastPathComponent == "Preview.html")
    }

    @Test func aOnePageMemoIsOnePageOfText() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Memo.docx"))
        let document = try read(output)
        // Quick Look pads its page by the file's top and bottom margins; printed as padding, a
        // short memo ran to two.
        #expect(output.pageCount == 1)
        #expect(pageText(document, 0).contains("Lease Renewal Heading"))
        #expect(pageText(document, 0).contains("SAVEASPDF-WORD-MARKER"))
        // Letter, as the file's page is — its width came from the HTML.
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
    }

    @Test func anOldWordFileIsText() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Memo.doc"))
        #expect(allText(try read(output)).contains("SAVEASPDF-WORD-MARKER"))
    }

    /// **A long document runs onto more pages, and every paragraph is printed exactly once** — a
    /// page break that duplicated or dropped a line would show here.
    @Test func aLongMemoPaginatesWithEveryParagraphOnce() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Long.docx"))
        let document = try read(output)
        // 20 or 21 two-line paragraphs to a Letter page between one-inch margins.
        #expect(output.pageCount == 6)
        let text = allText(document)
        for index in 1...120 {
            let word = String(format: "Paragraph %03d", index)
            #expect(occurrences(of: word, in: text) == 1, "\(word) is printed \(occurrences(of: word, in: text)) times")
        }
        #expect(pageText(document, 0).contains("Paragraph 001"))
        #expect(pageText(document, output.pageCount - 1).contains("SAVEASPDF-LONG-END"))
    }

    /// The paper a Word page prints on: Letter and A4 by their width, the reader's paper for Quick
    /// Look's own 600 (a file that names no size), and the reader's proportion past it.
    @Test func aWordPagesPaperComesFromItsWidth() {
        let a4 = CGSize(width: 595, height: 842)
        #expect(WordPaper.size(forWidth: 612, fallback: a4) == CGSize(width: 612, height: 792))
        #expect(WordPaper.size(forWidth: 596, fallback: .init(width: 612, height: 792)) == a4)
        #expect(WordPaper.size(forWidth: 842, fallback: a4) == CGSize(width: 842, height: 595))
        #expect(WordPaper.size(forWidth: 600, fallback: a4) == CGSize(width: 600, height: 849), "wider than A4: its proportion")
        #expect(WordPaper.size(forWidth: 600, fallback: CGSize(width: 612, height: 792)) == CGSize(width: 612, height: 792))
        #expect(WordPaper.size(forWidth: 1000, fallback: CGSize(width: 500, height: 1000)) == CGSize(width: 1000, height: 2000))
    }

    /// **Word's second route**: with no Quick Look page, the text system reads the file itself.
    @Test func wordFallsBackToTheTextSystem() async throws {
        let data = try await SaveAsPDFRender.officePDF(try Self.fixture("Memo.docx"), kind: .word,
                                                       settings: .init(), preview: { _, _ in nil })
        let document = try #require(PDFDocument(data: data))
        #expect(allText(document).contains("SAVEASPDF-WORD-MARKER"))
    }

    /// …and only Word has one: a deck Quick Look cannot read fails, in words.
    @Test func aDeckWithNoQuickLookPageFails() async throws {
        await #expect(throws: SaveAsPDFFailure.quickLookGaveNothing) {
            _ = try await SaveAsPDFRender.officePDF(try Self.fixture("Deck.pptx"), kind: .presentation,
                                                    settings: .init(), preview: { _, _ in nil })
        }
    }

    // MARK: Excel — every sheet, cut between rows

    /// **Both sheets, in tab order, every row once.** Spring's 121 rows run past a page; Autumn
    /// follows on its own page — and nothing after it: a sheet measured by the view it was laid out
    /// in ran on to blank pages.
    @Test func everySheetInTabOrderWithEveryRowOnce() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Budget.xlsx"))
        let document = try read(output)
        // Spring's 121 rows at 39 or 40 to a page, then Autumn's own.
        #expect(output.pageCount == 5)
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792),
                "a two-column sheet turned to landscape")
        let text = allText(document)
        for index in 1...120 {
            let word = String(format: "SPRING-ROW-%03d", index)
            #expect(occurrences(of: word, in: text) == 1, "\(word) is printed \(occurrences(of: word, in: text)) times")
        }
        #expect(pageText(document, 0).contains("SPRING-ROW-001"))
        let last = pageText(document, output.pageCount - 1)
        #expect(last.contains("SAVEASPDF-AUTUMN-MARKER"))
        #expect(!last.contains("SPRING-ROW"), "Autumn shares a page with Spring")
    }

    /// **A sheet wider than the page turns to landscape and shrinks to fit** — its last column is
    /// on the page, not clipped at the margin as WebKit's print clips it.
    @Test func aWideSheetKeepsItsLastColumn() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Wide.xlsx"))
        let document = try read(output)
        #expect(output.pageCount == 1)
        #expect(pageText(document, 0).contains("SAVEASPDF-WIDE-LASTCOL"))
        let size = try #require(document.page(at: 0)?.bounds(for: .mediaBox).size)
        #expect(size == CGSize(width: 792, height: 612), "the page is \(size)")
    }

    /// The cut rule on numbers: a band ends at the last row that fits, and a row taller than a page
    /// is cut at the page.
    @Test func sheetBandsBreakBetweenRows() {
        let geometry = DocumentPDF.PageGeometry(paper: CGSize(width: 200, height: 300),
                                                content: CGRect(x: 10, y: 10, width: 180, height: 280))
        let layout = SheetLayout(contentWidth: 100, contentHeight: 700, rowBottoms: [100, 250, 290, 400, 700],
                                 geometry: geometry)
        #expect(layout.scale == 1)
        #expect(layout.paper == CGSize(width: 200, height: 300))
        #expect(layout.bands == [0..<250, 250..<400, 400..<680, 680..<700])

        let wide = SheetLayout(contentWidth: 560, contentHeight: 100, rowBottoms: [], geometry: geometry)
        #expect(wide.paper == CGSize(width: 300, height: 200), "a sheet wider than the page does not turn to landscape")
        #expect(wide.content.width == 280)
        #expect(wide.scale == 0.5)
    }

    // MARK: Pictures — drawn, not blank

    /// **Every picture lower down a Word document or a sheet is drawn, and drawn whole.** The four
    /// are the same size, each its own hue, so their areas summed over every page match however the
    /// pages fall. Before the sheet waited for its pictures to decode it drew one to three of them,
    /// changing run to run. Word's print drew all four on every run measured here, but on CI twice
    /// drew its first picture blank (2026-10-20), so it waits for them too.
    @Test(arguments: ["FourPictures.docx", "FourPictures.xlsx"])
    func everyPictureIsDrawnWhole(_ name: String) async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture(name))
        let document = try #require(PDFComposer.document(output.data))
        #expect(allText(try read(output)).contains("SAVEASPDF-FOUR-PICTURES-END"))
        var areas = [0, 0, 0, 0]
        for number in 1...document.numberOfPages {
            let bitmap = try #require(document.page(at: number).flatMap(PictureText.bitmap(of:)))
            let bytes = try #require(bitmap.dataProvider?.data as Data?)
            for y in 0..<bitmap.height {
                for x in 0..<bitmap.width {
                    let at = y * bitmap.bytesPerRow + x * 4
                    let r = Int(bytes[at]), g = Int(bytes[at + 1]), b = Int(bytes[at + 2])
                    if r > 100, r > 2 * g, r > 2 * b { areas[0] += 1 }
                    if g > 100, g > 2 * r, g > 2 * b { areas[1] += 1 }
                    if b > 100, b > 2 * r, b > 2 * g { areas[2] += 1 }
                    if r > 150, g > 150, b < 60 { areas[3] += 1 }
                }
            }
        }
        let whole = try #require(areas.max())
        #expect(whole > 10_000, "no picture was drawn: \(areas)")
        for (index, area) in areas.enumerated() {
            #expect(Double(area) > Double(whole) * 0.95, "picture \(index + 1) of \(areas) is blank or cut")
        }
    }

    // MARK: PowerPoint — one page per slide

    /// **Three slides, three pages, in order, each the slide's own size, with real text** — the
    /// route measured on real decks here, which keeps a slide's words as words.
    @Test func aDeckIsOnePagePerSlideInOrder() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Deck.pptx"))
        let document = try read(output)
        #expect(output.pageCount == 3)
        #expect(output.picturePages == 0)
        for index in 0..<3 {
            #expect(pageText(document, index).contains("SAVEASPDF-SLIDE-\(index + 1)"),
                    "page \(index + 1) reads: \(pageText(document, index))")
            // python-pptx's default slide is 10 × 7.5 in: 720 × 540.
            #expect(document.page(at: index)?.bounds(for: .mediaBox).size == CGSize(width: 720, height: 540))
        }
    }

    /// **A deck whose slides are pictures with no words says so** — the banner's note rests on this
    /// answer, and Vision, finding nothing, adds nothing.
    @Test func aDeckOfPicturesIsCalledPictures() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Pictures.pptx"))
        let document = try read(output)
        #expect(output.pageCount == 2)
        #expect(output.picturePages == 2)
        #expect(output.isPictures)
        #expect(!output.isRecognised)
        let text = allText(document)
        #expect(text.allSatisfy { $0.isWhitespace }, "the PDF reads: \(text)")
    }

    /// **A deck of pictures of words comes out searchable** — each slide's words on its own page,
    /// found by PDFKit's search where the picture shows them (R2, ``PictureText``).
    @Test(.machinePinned(.textRecognition)) func aDeckOfPicturesOfWordsIsSearchable() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("PictureWords.pptx"))
        let document = try read(output)
        #expect(output.pageCount == 2)
        #expect(output.isPictures, "the deck's slides were read as text the file holds")
        #expect(output.isRecognised)
        #expect(pageText(document, 0).contains("Harvest moon festival"), "page 1 reads: \(pageText(document, 0))")
        #expect(pageText(document, 0).contains("Tickets at the north gate"), "page 1 reads: \(pageText(document, 0))")
        #expect(pageText(document, 1).contains("Lighthouse keeper rota"), "page 2 reads: \(pageText(document, 1))")
        #expect(!pageText(document, 0).contains("Lighthouse"))

        // The fixture draws each title from 1/12 of the way in, its top a fifth of the way down,
        // and the second line two thirds down: the hidden words lie over the drawn ones.
        let found = document.findString("Lighthouse", withOptions: [])
        try #require(found.count == 1, "search found \(found.count)")
        let page = try #require(found[0].pages.first)
        #expect(document.index(for: page) == 1)
        let size = page.bounds(for: .mediaBox).size
        let title = found[0].bounds(for: page)
        #expect(title.minX > size.width * 0.06 && title.minX < size.width * 0.11, "the title is at \(title) on \(size)")
        #expect(title.midY > size.height * 0.7 && title.midY < size.height * 0.85, "the title is at \(title) on \(size)")
        let lamps = try #require(document.findString("Lamps", withOptions: []).first)
        let line = lamps.bounds(for: page)
        #expect(line.midY > size.height * 0.25 && line.midY < size.height * 0.4, "the line is at \(line) on \(size)")
    }

    /// **Every picture is `decoding = 'sync'` once the page has loaded**, before anything has asked
    /// it to decode — ``WebPDFView/syncPictures``, run as the parser adds each one, so no paint of
    /// the load's queues a background decode for `createPDF` or the print to draw blank.
    @Test func everyPictureIsSyncOnceLoaded() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let html = try #require(await QuickLookHTML.preview(of: try Self.fixture("PictureWords.pptx"), into: scratch))
        let web = await WebPDFView.make(width: 1024)
        defer { web.close() }
        try #require(await web.load(html))
        let modes = try await web.json(
            "JSON.stringify(Array.from(document.images).map(function (image) { return image.decoding; }))") as? [String]
        #expect(modes == ["sync", "sync"])
    }

    /// **A picture slide drawn seconds after its picture decoded is still drawn.** WebKit lets go of
    /// a decoded picture soon after it last drew it, and the hidden view's next paint asks for it
    /// again in the background; a `createPDF` while that is under way draws the picture blank
    /// (2026-10-20, `docs/flaky-tests.md`, "A wedge guard that counts time spent waiting for the main
    /// thread"). A loaded machine waits that long now and then; the pause waits it every time.
    ///
    /// **Five renders, because each has one chance.** Only a view's first drawing after the decode
    /// can come out blank. Without `decoding = 'sync'`, 19 of 20 renders did (2026-10-20).
    @Test(.machinePinned(.textRecognition)) func aPictureSlideDrawnLateIsStillDrawn() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let html = try #require(await QuickLookHTML.preview(of: try Self.fixture("PictureWords.pptx"), into: scratch))
        for render in 1...5 {
            let data = try await SaveAsPDFRender.slidesPDF(html, pause: .seconds(3))
            let document = try #require(PDFComposer.document(data))
            try #require(document.numberOfPages == 2)
            for number in 1...2 {
                let lines = PictureText.recognise(try #require(document.page(at: number))).map(\.text)
                #expect(lines.count == 2, "render \(render): slide \(number) reads \(lines)")
            }
        }
    }

    /// **A deck mixing a text slide with a picture of words reads the picture only** — the picture's
    /// page gets its words, and the text slide's page reads exactly as the file's text made it,
    /// with nothing recognised laid over it.
    @Test(.machinePinned(.textRecognition)) func aMixedDeckReadsOnlyItsPictureSlides() async throws {
        let path = try Self.fixture("Mixed.pptx")
        let output = try await SaveAsPDFRender.render(path)
        let document = try read(output)
        #expect(output.pageCount == 2)
        #expect(output.picturePages == 1)
        #expect(!output.isPictures)
        #expect(output.isRecognised)
        #expect(occurrences(of: "SAVEASPDF-MIXED-TEXT", in: pageText(document, 0)) == 1, "page 1 reads: \(pageText(document, 0))")
        #expect(!pageText(document, 0).contains("Orchard"))
        #expect(pageText(document, 1).contains("Orchard harvest supper"), "page 2 reads: \(pageText(document, 1))")
        #expect(pageText(document, 1).contains("Cider pressed at noon"), "page 2 reads: \(pageText(document, 1))")

        let plain = try await SaveAsPDFRender.officePDF(path, kind: .presentation, settings: SaveAsPDFRender.Settings())
        let before = PDFDocument(data: plain)?.page(at: 0)?.string ?? ""
        #expect(before.contains("SAVEASPDF-MIXED-TEXT"))
        #expect(pageText(document, 0) == before, "the text slide changed: \(pageText(document, 0))")
    }

    /// **The words are invisible** — each page draws pixel for pixel as it did without them.
    @Test(.machinePinned(.textRecognition)) func recognisedTextDrawsNothing() async throws {
        let plain = try await SaveAsPDFRender.officePDF(try Self.fixture("PictureWords.pptx"), kind: .presentation,
                                                        settings: SaveAsPDFRender.Settings())
        let read = try #require(PictureText.searchable(plain), "Vision read no words in the fixture")
        let before = try #require(PDFComposer.document(plain)), after = try #require(PDFComposer.document(read))
        #expect(after.numberOfPages == before.numberOfPages)
        let plainText = PDFDocument(data: plain)?.string ?? ""
        #expect(plainText.allSatisfy { $0.isWhitespace }, "the deck had text before: \(plainText)")
        #expect(PDFDocument(data: read)?.string?.contains("Harvest") == true)
        for number in 1...before.numberOfPages {
            let old = try #require(before.page(at: number).flatMap(PictureText.bitmap(of:)))
            let new = try #require(after.page(at: number).flatMap(PictureText.bitmap(of:)))
            #expect(old.width == new.width && old.height == new.height)
            #expect(old.dataProvider?.data as Data? == new.dataProvider?.data as Data?, "page \(number) looks different")
        }
    }

    /// **A picture Vision refuses to read is read again on the CPU**, so a Neural Engine that turns
    /// every request away while macOS recompiles its models does not leave the deck unsearchable
    /// (`docs/flaky-tests.md`, "Vision's Neural Engine refuses text requests for hours"). The
    /// refusal is made here; the CPU read is Vision's own.
    @Test(.machinePinned(.textRecognition)) func aRefusedRecognitionIsReadAgainOnTheCPU() async throws {
        let plain = try await SaveAsPDFRender.officePDF(try Self.fixture("PictureWords.pptx"), kind: .presentation,
                                                        settings: SaveAsPDFRender.Settings())
        let page = try #require(PDFComposer.document(plain)?.page(at: 1))
        struct Refused: LocalizedError { var errorDescription: String? { "the Neural Engine refused this request" } }
        var asked: [PictureText.Processor] = []
        let log = LogCapture()
        let lines = PictureText.recognise(page) { image, processor in
            asked.append(processor)
            guard processor == .cpu else { throw Refused() }
            return try PictureText.read(image, on: .cpu)
        }.map(\.text)
        #expect(asked == [.any, .cpu])
        #expect(lines.contains("Harvest moon festival"), "the CPU read: \(lines)")
        // The whole sentence, with this case's own refusal in it: a sibling's failed recognition
        // logs the same first half, and a LogCapture sees sibling cases' lines.
        #expect(await log.holds(.warning, containing:
            "Save as PDF: text recognition failed: the Neural Engine refused this request; reading on the CPU"))
    }

    // MARK: When WebKit gives nothing

    /// A folder holding `page.html`, a line of text — with `stuck`, and a picture that is a named
    /// pipe nobody writes to, so its load, and the page's, never ends on its own.
    private static func page(stuck: Bool) throws -> (html: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webpdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let html = folder.appendingPathComponent("page.html")
        try "<html><body><p>Lamps</p>\(stuck ? #"<img src="pipe.png">"# : "")</body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        if stuck { try #require(mkfifo(folder.appendingPathComponent("pipe.png").path, 0o600) == 0) }
        return (html, folder)
    }

    /// **A page reaches nothing by URL** — a picture and a stylesheet it names by `http:` never
    /// connect. The listener never answers, so a request that got out holds the load open to its
    /// guard; the connection waits in the listener's queue either way, made before the load ended.
    /// A rule list WebKit cannot compile blocks nothing, which a `|` in a pattern did.
    @Test func aPageReachesNothingByURL() async throws {
        let listener = try #require(LoopbackListener())
        defer { listener.close() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("webpdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = folder.appendingPathComponent("page.html")
        let base = "http://127.0.0.1:\(listener.port)"
        try """
            <html><head><link rel="stylesheet" href="\(base)/x.css"></head>
            <body><p>Lamps</p><img src="\(base)/x.png"></body></html>
            """.write(to: html, atomically: true, encoding: .utf8)
        #expect(await WebPDFView.offline() != nil, "the rule list didn’t compile")
        let web = await WebPDFView.make(width: 400)
        defer { web.close() }
        #expect(await web.load(html, timeout: 10), "the load waited on a request")
        #expect(listener.connections() == 0, "the page connected to \(base)")
    }

    /// A TCP socket listening on a loopback port it never answers on. The kernel queues each
    /// connection made to it, so counting them needs no thread.
    private final class LoopbackListener {
        private let socket: Int32
        let port: UInt16

        init?() {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { return nil }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socket, $0, length) == 0 && listen(socket, 16) == 0 && getsockname(socket, $0, &length) == 0
                }
            }
            guard bound, fcntl(socket, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(socket); return nil }
            self.socket = socket
            port = UInt16(bigEndian: address.sin_port)
        }

        /// How many connections are waiting, taking each.
        func connections() -> Int {
            var count = 0
            while case let peer = accept(socket, nil, nil), peer >= 0 {
                Darwin.close(peer)
                count += 1
            }
            return count
        }

        func close() { Darwin.close(socket) }
    }

    @MainActor private final class Backstop { var fired = false }

    /// Lets go of whatever WebKit has left waiting to open the pipe, and removes the folder. Opening
    /// the far end without blocking fails when nobody is waiting: then there is nothing to let go.
    private static func release(_ folder: URL) {
        let end = open(folder.appendingPathComponent("pipe.png").path, O_WRONLY | O_NONBLOCK)
        if end >= 0 { Darwin.close(end) }
        try? FileManager.default.removeItem(at: folder)
    }

    /// **A load that cannot finish gives up at its guard, and says so once** — the page's picture
    /// never arrives, so only the timer ends the wait. A second deadline closes the view, ending the
    /// wait, so a guard that never ends it fails rather than hangs — at the production guard's
    /// 120 s, far enough past the timer's that a main thread a minute behind still runs the test's
    /// resumption before it.
    @Test func aLoadThatCannotFinishGivesUpAtItsGuard() async throws {
        let (html, folder) = try Self.page(stuck: true)
        defer { Self.release(folder) }
        let web = await WebPDFView.make(width: 400)
        defer { web.close() }
        let backstopped = Backstop()
        let backstop = DispatchWorkItem { MainActor.assumeIsolated { backstopped.fired = true; web.close() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: backstop)
        defer { backstop.cancel() }
        let log = LogCapture()
        #expect(await web.load(html, timeout: 1) == false)
        #expect(!backstopped.fired, "the guard never ended the load")
        let lines = await log.entries.filter { $0.level == .warning && $0.message.contains("load in 1 s; giving up") }
        #expect(lines.count == 1, "\(lines.map(\.message))")
    }

    /// **A load that finished says nothing after its guard's budget has passed.** Ending the load
    /// stops the guard. `didFinish` is queued ahead of the guard's first tick, so the load has ended
    /// first even on a machine whose main thread is far behind — WebKit's own may come first
    /// instead, and either ends it. The wait after is past the budget.
    @Test func aLoadThatFinishedSaysNothingWhenItsGuardFires() async throws {
        let (html, folder) = try Self.page(stuck: false)
        defer { Self.release(folder) }
        let web = await WebPDFView.make(width: 400)
        defer { web.close() }
        let log = LogCapture()
        DispatchQueue.main.async { MainActor.assumeIsolated { web.webView(web.web, didFinish: nil) } }
        try #require(await web.load(html, timeout: 2))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { done.resume() }
        }
        #expect(await !log.holds(containing: "load in 2 s; giving up"))
    }

    /// **A web process that quit fails the load at once, and every draw after it refuses** rather
    /// than drawing a dead view blank. No public API ends a web process, so WebKit's report is made
    /// here directly, queued ahead of anything the load can report.
    @Test func aWebProcessThatQuitFailsTheLoadAndEveryDraw() async throws {
        let (html, folder) = try Self.page(stuck: false)
        defer { Self.release(folder) }
        let web = await WebPDFView.make(width: 400)
        defer { web.close() }
        let log = LogCapture()
        DispatchQueue.main.async { MainActor.assumeIsolated { web.webViewWebContentProcessDidTerminate(web.web) } }
        #expect(await web.load(html, timeout: 30) == false)
        #expect(await log.holds(.warning, containing: "Save as PDF: the web process drawing the file quit"))
        await #expect(throws: SaveAsPDFFailure.quickLookGaveNothing) {
            try await web.pdf(of: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let info = SaveAsPDFRender.printInfo(paper: CGSize(width: 612, height: 792), margins: NSEdgeInsets())
        await #expect(throws: SaveAsPDFFailure.quickLookGaveNothing) { try await web.print(info) }
    }

    /// **A web process that is alive but never answers fails each call in words** rather than
    /// waiting for ever. Stopping the process is that wedge on purpose: WebKit reports nothing, and
    /// `createPDF` answers only once the process runs again (`docs/flaky-tests.md`, "A hidden web
    /// view's process drops to the background band, so load starves its draws").
    @Test func aWebProcessThatNeverAnswersFailsEachCallInWords() async throws {
        let (html, folder) = try Self.page(stuck: false)
        defer { Self.release(folder) }
        let web = await WebPDFView.make(width: 400)
        defer { web.close() }
        try #require(await web.load(html))
        let pid = try #require((web.web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value)
        try #require(pid > 0 && kill(pid, SIGSTOP) == 0)
        defer { kill(pid, SIGCONT) }
        // The backstop: the process let go, so a call the guard never ends answers and fails the
        // test rather than hanging it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { kill(pid, SIGCONT) }
        let log = LogCapture()
        await #expect(throws: SaveAsPDFFailure.stalled) {
            try await web.pdf(of: CGRect(x: 0, y: 0, width: 100, height: 100), budget: 1)
        }
        await #expect(throws: SaveAsPDFFailure.stalled) {
            try await web.guarded("measuring the page", budget: 1) { (answer: @escaping @MainActor @Sendable (Result<Bool, Error>) -> Void) in
                web.web.evaluateJavaScript("1") { _, _ in answer(.success(true)) }
            }
        }
        let info = SaveAsPDFRender.printInfo(paper: CGSize(width: 612, height: 792), margins: NSEdgeInsets())
        await #expect(throws: SaveAsPDFFailure.stalled) { try await web.print(info, budget: 1) }
        // Only this suite's lines: the capture also hears every other suite running beside this
        // one, such as a preview's "could not be opened" (`docs/flaky-tests.md`, "A log assertion
        // reading a window that has already rolled", rule 4).
        let lines = await log.entries.filter { $0.level == .warning }.map { $0.message.components(separatedBy: " | ")[0] }
            .filter { $0.hasPrefix("Save as PDF:") }
        #expect(lines == ["Save as PDF: WebKit didn’t finish drawing a page in 1 s; giving up on it",
                          "Save as PDF: WebKit didn’t finish measuring the page in 1 s; giving up on it",
                          "Save as PDF: WebKit didn’t finish printing in 1 s; giving up on it"])
    }

    /// **A view's web process keeps a foreground priority after its load**, so a draw sent later
    /// is not starved by a busy machine. Without the hold, WebKit gives a hidden view's process the
    /// background role about a second after the load's last script call answers, and its task
    /// priority falls from 31 to 20 (measured 2026-10-21, no load) — under load, to 4.
    @Test func aViewsWebProcessKeepsAForegroundPriorityAfterItsLoad() async throws {
        let (html, folder) = try Self.page(stuck: false)
        defer { Self.release(folder) }
        let web = await WebPDFView.make(width: 400)
        defer { web.close() }
        try #require(await web.load(html))
        let pid = try #require((web.web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value)
        try #require(pid > 0)
        try await Task.sleep(for: .seconds(4))
        let own = try #require(Self.taskPriority(of: getpid()))
        let drawing = try #require(Self.taskPriority(of: pid), "couldn’t read the web process’s priority")
        #expect(drawing >= own, "the web process runs at \(drawing), below this process’s \(own)")
    }

    private static func taskPriority(of pid: pid_t) -> Int32? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info.pti_priority : nil
    }

    /// **A wedge guard does not count time the main thread was held elsewhere** — WebKit's answer
    /// would have been queued behind it. Held for 6 s on a 2 s budget, a wall-clock guard has run
    /// out by the time the main thread is free; this one has counted a second, and runs out a
    /// second of free main thread later.
    @Test func aWedgeGuardDoesNotCountTimeTheMainThreadWasHeld() async throws {
        let ran = Backstop()
        var ranAt = 0.0
        let wedge = WedgeGuard(budget: 2) {
            ran.fired = true
            ranAt = ProcessInfo.processInfo.systemUptime
        }
        defer { wedge.cancel() }
        Self.holdTheMainThread(for: 6)
        let freed = ProcessInfo.processInfo.systemUptime
        for _ in 0..<300 where !ran.fired { try await Task.sleep(for: .milliseconds(100)) }
        try #require(ran.fired, "the guard never ran out")
        #expect(ranAt - freed >= 0.75, "it ran out \(ranAt - freed) s after the main thread was free")
    }

    private static func holdTheMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: What converts

    @Test func theKindsAreTheMeasuredOnes() {
        let offered = ["a.txt", "a.md", "a.MARKDOWN", "a.rtf", "a.docx", "a.DOC", "a.xlsx", "a.xls", "a.pptx", "a.ppt"]
        for name in offered { #expect(SaveAsPDFKind.of(path: "/x/" + name) != nil, "\(name) is not offered") }
        let refused = ["a.pdf", "a.pages", "a.key", "a.numbers", "a.csv", "a.json", "a.png", "a", "~$Lease.docx", "~$deck.pptx"]
        for name in refused { #expect(SaveAsPDFKind.of(path: "/x/" + name) == nil, "\(name) is offered") }
    }
}
