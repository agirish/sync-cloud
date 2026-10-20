import Testing
import AppKit
import PDFKit
@testable import FileExplorer

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
    @Test(arguments: ["Memo.docx", "Memo.doc", "Long.docx", "Budget.xlsx", "Wide.xlsx", "Deck.pptx", "Pictures.pptx"])
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

    // MARK: PowerPoint — one page per slide

    /// **Three slides, three pages, in order, each the slide's own size, with real text** — the
    /// route measured on real decks here, which keeps a slide's words as words.
    @Test func aDeckIsOnePagePerSlideInOrder() async throws {
        let output = try await SaveAsPDFRender.render(try Self.fixture("Deck.pptx"))
        let document = try read(output)
        #expect(output.pageCount == 3)
        #expect(!output.isPictures)
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
        #expect(output.isPictures)
        #expect(!output.isRecognised)
        let text = allText(document)
        #expect(text.allSatisfy { $0.isWhitespace }, "the PDF reads: \(text)")
    }

    /// **A deck of pictures of words comes out searchable** — each slide's words on its own page,
    /// found by PDFKit's search where the picture shows them (R2, ``PictureText``).
    @Test func aDeckOfPicturesOfWordsIsSearchable() async throws {
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

    /// **The words are invisible** — each page draws pixel for pixel as it did without them.
    @Test func recognisedTextDrawsNothing() async throws {
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

    // MARK: What converts

    @Test func theKindsAreTheMeasuredOnes() {
        let offered = ["a.txt", "a.md", "a.MARKDOWN", "a.rtf", "a.docx", "a.DOC", "a.xlsx", "a.xls", "a.pptx", "a.ppt"]
        for name in offered { #expect(SaveAsPDFKind.of(path: "/x/" + name) != nil, "\(name) is not offered") }
        let refused = ["a.pdf", "a.pages", "a.key", "a.numbers", "a.csv", "a.json", "a.png", "a", "~$Lease.docx", "~$deck.pptx"]
        for name in refused { #expect(SaveAsPDFKind.of(path: "/x/" + name) == nil, "\(name) is offered") }
    }
}
