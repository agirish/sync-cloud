import Testing
import Foundation
import PDFKit
@testable import FileExplorer

/// The printed document, read back out of the bytes it was rendered into.
///
/// PDFKit is the check, not a snapshot. File ▸ Print… and File ▸ Export as PDF… promise what is on
/// the page (the words, as text, with no break inside a heading), and the rendered file can be asked
/// that directly; a snapshot would pass just as happily on three blank sheets.
///
/// An `NSHostingView` handed to `NSPrintOperation` produces correctly paginated, entirely empty
/// paper. Extracted text is empty in that state, so every test reads the text back rather than
/// trusting a byte count.
@MainActor
@Suite struct DocumentPDFTests {

    /// A geometry small enough that a handful of blocks fills several pages, so pagination is
    /// exercised by documents short enough to read in a failure message.
    private static let small = DocumentPDF.PageGeometry(
        paper: CGSize(width: 400, height: 300),
        content: CGRect(x: 20, y: 20, width: 360, height: 260))

    private func render(_ text: String, isMarkdown: Bool = true,
                        geometry: DocumentPDF.PageGeometry = .letter,
                        folder: String? = nil) throws -> PDFDocument {
        let job = DocumentPDF.Job(name: "note.md", text: text, isMarkdown: isMarkdown, folder: folder)
        let data = try #require(DocumentPDF.data(for: job, geometry: geometry),
                                "the renderer produced no bytes at all")
        return try #require(PDFDocument(data: data), "the bytes are not a PDF")
    }

    /// The text on one page, as PDFKit reads it back. Empty when the page carries no real glyphs,
    /// the rasterised-or-blank failure this suite catches.
    private func text(of document: PDFDocument, page index: Int) -> String {
        document.page(at: index)?.string ?? ""
    }

    /// Every run of whitespace as one space; see `aLongParagraphWrapsRatherThanBeingTruncated`.
    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func allText(_ document: PDFDocument) -> String {
        (0..<document.pageCount).map { text(of: document, page: $0) }.joined(separator: "\n")
    }

    // MARK: The render is text

    /// The whole document reaches the page as glyphs: one of each block `MarkdownBlockView` draws
    /// (heading, paragraph, list, quote, code fence, table), each readable back out of the file.
    @Test func everyKindOfBlockReachesThePageAsRealText() throws {
        let source = """
        # Quarterly notes

        A paragraph about the **quarter**, with a [link](https://example.com) in it.

        - first item
        - second item

        > a quoted remark

        ```swift
        let answer = 42
        ```

        | Column | Other |
        |---|---|
        | cell | value |
        """
        let document = try render(source)
        let printed = allText(document)
        for expected in ["Quarterly notes", "paragraph", "quarter", "first item", "second item",
                         "quoted remark", "let answer = 42", "Column", "cell", "value"] {
            #expect(printed.contains(expected), "“\(expected)” is missing from the printed page")
        }
    }

    /// A paragraph too long for one line wraps rather than being truncated to one. A frame set on
    /// the host doesn't constrain `NSHostingView.fittingSize`, so a block measured that way comes
    /// back one line tall and prints ending in an ellipsis. The check reads the paragraph's last
    /// words, which are what truncation removes; the other tests' words sit on the first line.
    @Test func aLongParagraphWrapsRatherThanBeingTruncated() throws {
        let tail = "and this sentence ends with the unmistakable phrase margarine parliament."
        let source = "A paragraph long enough that it cannot possibly fit on a single line of a "
            + "letter-sized page, going on at some length about nothing in particular, "
            + "continuing past the width of any reasonable column, " + tail
        // Whitespace-flattened, because PDFKit's extractor puts a newline at each wrap, which
        // would split the phrase on a correct render too.
        let printed = Self.flattened(allText(try render(source)))
        #expect(printed.contains("margarine parliament"),
                "the paragraph's last words never reached the page — it was cut to one line")
        #expect(!printed.contains("…"), "the page carries a truncation ellipsis")
    }

    // MARK: Pagination, end to end

    /// A document longer than one page becomes several, in order, with every paragraph printed
    /// once: a break that skipped content would leave one out, and a block cut in half would be
    /// extracted from both sides of the break. Checked on a real render, not the paginator's model.
    @Test func aLongDocumentPaginatesWithEveryBlockOnExactlyOnePage() throws {
        let markers = (1...60).map { "Paragraph number \($0)," }
        let source = markers.map { "\($0) which is here to take up room." }.joined(separator: "\n\n")
        let document = try render(source, geometry: Self.small)
        #expect(document.pageCount > 1, "sixty paragraphs fitted on one small page")
        #expect(text(of: document, page: 0).contains("Paragraph number 1,"),
                "the first page does not start at the start")
        let printed = allText(document)
        let missing = markers.filter { !printed.contains($0) }
        #expect(missing.isEmpty, "these paragraphs never reached the paper: \(missing)")
        var seen: [String: Int] = [:]
        for index in 0..<document.pageCount {
            let page = text(of: document, page: index)
            for marker in markers where page.contains(marker) { seen[marker, default: 0] += 1 }
        }
        let split = seen.filter { $0.value > 1 }.keys.sorted()
        #expect(split.isEmpty, "these blocks were cut across a page break: \(split)")
    }

    /// An empty document, Markdown or plain text, is a blank sheet rather than a file nothing will
    /// open.
    @Test func anEmptyDocumentIsOneBlankPage() throws {
        #expect(try render("").pageCount == 1)
        #expect(try render("", isMarkdown: false).pageCount == 1)
    }

    // MARK: Plain text

    /// A plain-text file prints as text. It goes through CoreText rather than the block pipeline,
    /// so it gets its own end-to-end check.
    @Test func aPlainTextFilePrintsAsText() throws {
        let source = (1...200).map { "log line \($0): something happened" }.joined(separator: "\n")
        let document = try render(source, isMarkdown: false, geometry: Self.small)
        #expect(document.pageCount > 1, "two hundred lines fitted on one small page")
        let printed = allText(document)
        #expect(printed.contains("log line 1:"), "the first line is missing")
        #expect(printed.contains("log line 200:"), "the last line is missing")
    }

    /// Plain text is not rendered as Markdown: a line starting with `#` is a line starting with
    /// `#`, not a heading with the marker eaten.
    @Test func plainTextKeepsItsMarkdownSyntaxOnThePage() throws {
        let document = try render("# not a heading\n**not bold**\n", isMarkdown: false)
        let printed = allText(document)
        #expect(printed.contains("# not a heading"), "the plain-text page was rendered as Markdown")
        #expect(printed.contains("**not bold**"))
    }

    // MARK: Geometry

    /// The paper is the geometry's, not a hardcoded Letter: an A4 default must produce A4 pages.
    @Test func thePagesAreTheGeometrysPaper() throws {
        let a4 = DocumentPDF.PageGeometry(paper: CGSize(width: 595, height: 842),
                                          content: CGRect(x: 36, y: 36, width: 523, height: 770))
        let document = try render("# Heading\n\nProse.\n", geometry: a4)
        let bounds = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(Int(bounds.width) == 595 && Int(bounds.height) == 842,
                "the page is \(bounds.size) rather than the A4 it was asked for")
    }

    /// A print system with no printer reports an empty imageable box; the geometry falls back to
    /// half-inch margins rather than to a content box of nothing.
    @Test func anEmptyImageableBoxFallsBackToRealMargins() {
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = CGSize(width: 612, height: 792)
        info.topMargin = 396; info.bottomMargin = 396   // leaves no imageable height at all
        let geometry = DocumentPDF.PageGeometry.from(info)
        #expect(geometry.content.width > 0 && geometry.content.height > 0,
                "the fallback margins did not fire — an export would render into nothing")
    }

    // MARK: The exported name

    @Test func theExportNameSwapsTheExtension() {
        #expect(job(named: "notes.md").exportName == "notes.pdf")
        #expect(job(named: "README").exportName == "README.pdf")
        #expect(job(named: "archive.tar.gz").exportName == "archive.tar.pdf")
    }

    private func job(named name: String) -> DocumentPDF.Job {
        DocumentPDF.Job(name: name, text: "", isMarkdown: true)
    }
}
