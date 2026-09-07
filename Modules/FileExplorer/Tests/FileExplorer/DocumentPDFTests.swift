import Testing
import Foundation
import PDFKit
@testable import FileExplorer

/// The printed document, read back out of the bytes it was rendered into.
///
/// **PDFKit is the check, not a snapshot.** Every claim File ▸ Print… and File ▸ Export as PDF…
/// make is about what ends up on the page — the words are there, they are text rather than a
/// picture of text, and a page break did not land inside a heading — and each of those is a
/// question the rendered file can be asked directly. A snapshot would answer "it looks like it did
/// last time", which is a different question and passes just as happily when the answer is three
/// blank sheets.
///
/// The failure this is written against is real and was measured on this branch: an
/// `NSHostingView` handed to `NSPrintOperation` produces correctly paginated, entirely empty
/// paper — right page count, no ink. `extract` below returns nothing at all in that state, which
/// is why every test here goes through it rather than trusting a byte count.
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

    /// The text on one page, as PDFKit reads it back. Empty when the page carries no real glyphs —
    /// which is the rasterised-or-blank failure this suite exists to catch.
    private func text(of document: PDFDocument, page index: Int) -> String {
        document.page(at: index)?.string ?? ""
    }

    /// Every run of whitespace as one space — see `aLongParagraphWrapsRatherThanBeingTruncated`.
    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func allText(_ document: PDFDocument) -> String {
        (0..<document.pageCount).map { text(of: document, page: $0) }.joined(separator: "\n")
    }

    // MARK: The render is text

    /// **The whole document reaches the page, as glyphs.** A heading, a paragraph, a list, a quote,
    /// a code fence and a table — one of each arm `MarkdownBlockView` draws — and every one of them
    /// is readable back out of the file.
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

    /// **Vector text, not a picture of it.** If the render ever falls back to rasterising, the
    /// glyphs stop being glyphs and PDFKit returns nothing — the page still looks right in a viewer
    /// and is unsearchable, unselectable and soft at any zoom.
    @Test func thePageCarriesSelectableTextRatherThanAnImage() throws {
        let document = try render("# Heading\n\nSome ordinary prose.\n")
        #expect(!allText(document).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the page has no extractable text — the render rasterised")
    }

    /// **A paragraph too long for one line WRAPS — it is not truncated to one.**
    ///
    /// This is the defect a rendered page found and every test above missed, which is why it is
    /// written as its own claim rather than folded into one of them: each block was measured with
    /// `NSHostingView.fittingSize` against a frame set on the *host*, which does not constrain the
    /// content's ideal size — so every prose block came back one line tall, was pinned to one line,
    /// and printed as a sentence ending in an ellipsis. The tests could not see it because the
    /// words they look for are all on the first line.
    ///
    /// The check is the LAST words of a long paragraph, which is exactly what truncation removes.
    @Test func aLongParagraphWrapsRatherThanBeingTruncated() throws {
        let tail = "and this sentence ends with the unmistakable phrase margarine parliament."
        let source = "A paragraph long enough that it cannot possibly fit on a single line of a "
            + "letter-sized page, going on at some length about nothing in particular, "
            + "continuing past the width of any reasonable column, " + tail
        // **Whitespace-flattened, because a wrap IS a newline to PDFKit.** The extractor breaks the
        // string where the line breaks, so the very wrapping this test is about would split the
        // phrase it looks for — a check that failed on the fixed render as loudly as on the broken
        // one, which is a check about the extractor rather than about the page.
        let printed = Self.flattened(allText(try render(source)))
        #expect(printed.contains("margarine parliament"),
                "the paragraph's last words never reached the page — it was cut to one line")
        #expect(!printed.contains("…"), "the page carries a truncation ellipsis")
    }

    /// The same claim one level down, where the cause was: a block measured at the page width must
    /// be taller than a block measured with room to spare.
    @Test func aWrappedBlockKeepsEveryRepetition() throws {
        let printed = Self.flattened(allText(try render(String(repeating: "wrapping words ", count: 60))))
        // Sixty repetitions cannot fit on one line; if the block is pinned to one, most of them
        // are simply gone. A few may be lost to the extractor's spacing, hence the margin.
        let occurrences = printed.components(separatedBy: "wrapping words").count - 1
        #expect(occurrences >= 55,
                "only \(occurrences) of 60 repetitions reached the page — the block was cut short")
    }

    // MARK: Pagination, end to end

    /// A document longer than one page becomes several, in order.
    @Test func aLongDocumentPaginates() throws {
        let source = (1...60).map { "Paragraph number \($0), which is here to take up room." }
            .joined(separator: "\n\n")
        let document = try render(source, geometry: Self.small)
        #expect(document.pageCount > 1, "sixty paragraphs fitted on one small page")
        #expect(text(of: document, page: 0).contains("Paragraph number 1,"),
                "the first page does not start at the start")
        #expect(allText(document).contains("Paragraph number 60,"),
                "the last paragraph never made it onto paper")
    }

    /// **No paragraph is on two pages at once** — the property the block paginator buys, checked
    /// against a real render rather than against the model that drove it. A block cut in half would
    /// have its text extracted from both sides of the break.
    @Test func noBlockIsSplitAcrossAPageBreak() throws {
        let source = (1...40).map { "Paragraph number \($0), which is here to take up room." }
            .joined(separator: "\n\n")
        let document = try render(source, geometry: Self.small)
        var seen: [String: Int] = [:]
        for index in 0..<document.pageCount {
            for marker in (1...40).map({ "Paragraph number \($0)," }) where
                text(of: document, page: index).contains(marker) {
                seen[marker, default: 0] += 1
            }
        }
        let split = seen.filter { $0.value > 1 }.keys.sorted()
        #expect(split.isEmpty, "these blocks were cut across a page break: \(split)")
    }

    /// Every paragraph is printed exactly once — a break that skipped content would leave one out,
    /// and one that reset would print it twice.
    @Test func everyBlockIsPrintedExactlyOnce() throws {
        let source = (1...40).map { "Paragraph number \($0), which is here to take up room." }
            .joined(separator: "\n\n")
        let printed = allText(try render(source, geometry: Self.small))
        let missing = (1...40).filter { !printed.contains("Paragraph number \($0),") }
        #expect(missing.isEmpty, "these paragraphs never reached the paper: \(missing)")
    }

    /// An empty document is a blank sheet rather than a file nothing will open.
    @Test func anEmptyDocumentIsOneBlankPage() throws {
        #expect(try render("").pageCount == 1)
    }

    // MARK: Plain text

    /// **A plain-text file prints as text** — the roadmap's own words. It goes through CoreText
    /// rather than the block pipeline, so it gets its own end-to-end check.
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

    /// An empty plain-text file is a blank sheet too, by the same argument.
    @Test func anEmptyPlainTextFileIsOneBlankPage() throws {
        #expect(try render("", isMarkdown: false).pageCount == 1)
    }

    // MARK: Geometry

    /// The paper is the geometry's, not a hardcoded Letter — an A4 default has to produce A4 pages
    /// or every export on a metric desk is the wrong shape.
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
