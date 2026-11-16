import AppKit
import CoreText
import Events
import Foundation
import ImageIO
import Sync
import Testing
import UniformTypeIdentifiers
@testable import SyncCloud

/// The on-device Filing content extractor: the NaturalLanguage and category-keyword tokenization
/// that turns text into the tokens the FilingEngine matches on, and the text, PDF and OCR readers,
/// driven with real fixture files.
@Suite struct ContentSignalExtractorTests {

    @Test func pullsCategoryKeywordsFromDocumentText() {
        let text = "Declarations Page. Your GEICO auto insurance policy for your Tesla Model 3."
        let tokens = ContentSignalExtractor.tokens(fromText: text)
        #expect(tokens.contains("tesla"))      // vehicle brand
        #expect(tokens.contains("insurance"))  // insurance keyword
        #expect(tokens.contains("policy"))
        #expect(tokens.contains("geico"))
    }

    @Test func pullsTaxFormNumbersRaw() {
        let tokens = ContentSignalExtractor.tokens(fromText: "Form 1099-INT — interest income for 2024")
        #expect(tokens.contains("1099"))
    }

    @Test func emptyForContentWithNoSignal() {
        // No entities and no category keywords → nothing to add.
        let tokens = ContentSignalExtractor.tokens(fromText: "lorem ipsum dolor sit amet")
        #expect(tokens.isEmpty)
    }

    // MARK: File readers (real fixture files in a per-test temp dir)

    /// A unique scratch directory, removed on teardown.
    private final class FixtureDir {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentSignalExtractorTests-\(UUID().uuidString)", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
        func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    }

    /// Writes a real PDF with one line of genuine text ops per page, so PDFKit's text extraction
    /// sees it. One line per page is the shape most of these tests want.
    private static func writePDF(lines: [String], to path: String) throws {
        try writePDF(pages: lines.map { [$0] }, to: path)
    }

    /// Pages of lines. A single `CTLine` is clipped at the page edge, so a long string drawn as one
    /// line extracts as about fifty characters; a page that says plenty needs many lines.
    private static func writePDF(pages: [[String]], to path: String) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for page in pages {
            context.beginPDFPage(nil)
            for (i, line) in page.enumerated() {
                let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 12)])
                context.textPosition = CGPoint(x: 36, y: 720 - CGFloat(i) * 16)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Renders large black-on-white text into a PNG (a synthetic "scan") and returns its path.
    private static func writeTextImage(_ text: String, to path: String) throws {
        let width = 1200, height = 240
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 96),
            .foregroundColor: NSColor.black,
        ])
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// A plain local text file: its head comes back verbatim, and the evicted-iCloud guard (which
    /// this path always crosses) answers false for a non-ubiquitous file.
    @Test func plainTextFileYieldsItsContentAndTokens() async {
        let dir = FixtureDir()
        let path = dir.path("note.txt")
        let content = "Your GEICO auto insurance policy renewal for the Tesla."
        try? content.write(toFile: path, atomically: true, encoding: .utf8)

        let snippet = await ContentSignalExtractor.snippet(forFileAt: path)
        #expect(snippet == content)
        let tokens = await ContentSignalExtractor.tokens(forFileAt: path)
        #expect(tokens.contains("insurance"))
        #expect(tokens.contains("geico"))
    }

    @Test func plainTextReadIsBoundedTo64KB() async throws {
        let dir = FixtureDir()
        let path = dir.path("huge.log")
        try String(repeating: "a", count: 70_000).write(toFile: path, atomically: true, encoding: .utf8)
        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.count == 64 * 1024)
    }

    @Test func unsupportedTypeYieldsNothing() async {
        let dir = FixtureDir()
        let path = dir.path("archive.zip")
        try? "GEICO insurance policy".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await ContentSignalExtractor.snippet(forFileAt: path) == nil)
        #expect(await ContentSignalExtractor.tokens(forFileAt: path).isEmpty)
    }

    @Test func pdfTextIsExtractedViaPDFKit() async throws {
        let dir = FixtureDir()
        let path = dir.path("policy.pdf")
        try Self.writePDF(lines: ["GEICO auto insurance policy declarations"], to: path)
        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.contains("GEICO"))
        #expect(snippet.contains("insurance policy"))
        let tokens = await ContentSignalExtractor.tokens(forFileAt: path)
        #expect(tokens.contains("insurance"))
    }

    @Test func pdfReadStopsAfterFivePages() async throws {
        let dir = FixtureDir()
        let path = dir.path("long.pdf")
        try Self.writePDF(lines: (1...7).map { "MARKERPAGE\($0)" }, to: path)
        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.contains("MARKERPAGE5"))
        #expect(!snippet.contains("MARKERPAGE6"))
        #expect(!snippet.contains("MARKERPAGE7"))
    }

    /// Five pages is a fallback for a thin first page, not a target. Nothing downstream reads that
    /// much (the router scores 400 characters, the on-device prompt carries 1,200, the cloud one
    /// 800), so reading on past a first page that says plenty wastes a parse on every file.
    @Test func aPageThatSaysPlentyStopsTheRead() async throws {
        let dir = FixtureDir()
        let path = dir.path("bill.pdf")
        let fatFirstPage = (0..<20).map { "AutoPay is scheduled for this account, line \($0)." }
        try Self.writePDF(pages: [fatFirstPage, ["MARKERPAGE2"], ["MARKERPAGE3"]], to: path)
        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.contains("AutoPay"))
        #expect(!snippet.contains("MARKERPAGE2"), "read past a first page that already said plenty")
    }

    @Test func corruptPDFYieldsNothing() async {
        let dir = FixtureDir()
        let path = dir.path("broken.pdf")
        try? Data([0x00, 0x01, 0x02, 0x03]).write(to: URL(fileURLWithPath: path))
        #expect(await ContentSignalExtractor.snippet(forFileAt: path) == nil)
    }

    @Test func corruptImageYieldsNothing() async {
        let dir = FixtureDir()
        let path = dir.path("broken.png")
        try? Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: URL(fileURLWithPath: path))
        #expect(await ContentSignalExtractor.snippet(forFileAt: path) == nil)
        #expect(await ContentSignalExtractor.tokens(forFileAt: path).isEmpty)
    }

    /// End-to-end OCR over a synthetic scan (huge, clean text Vision's `.fast` recognizer reads
    /// reliably), which must not also log "OCR failed on …": that warning belongs in the `catch`
    /// only, or it fires on every scan. The failing direction has no seam to drive.
    ///
    /// The absence is read from a `LogCapture` opened before the call and closed by a line of its
    /// own, under a name no other test writes (`docs/flaky-tests.md`, "A log assertion reading a
    /// window that has already rolled").
    @MainActor
    @Test func aScanThatOCRsCleanlyReportsNoOCRFailure() async throws {
        let dir = FixtureDir()
        let path = dir.path("clean-scan.png")
        try Self.writeTextImage("INVOICE 1099", to: path)

        let log = LogCapture()

        // The fixture must really OCR, or the no-warning assertion below proves nothing.
        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.uppercased().contains("INVOICE"))
        let tokens = await ContentSignalExtractor.tokens(forFileAt: path)
        #expect(tokens.contains("invoice"))
        #expect(tokens.contains("1099"))

        // After the call under test, so a capture that holds it was listening throughout.
        let marker = "ocr-failure window close \(UUID().uuidString)"
        Logger.shared.debug(marker)
        let entries = await log.entries
        // A Bool before the `#require`: requiring anything holding the entries prints every one on
        // failure, burying the sentence that explains it.
        let heard = entries.contains { $0.message == marker }
        try #require(heard, "the capture never saw this test's own line, so the absence below would have examined nothing")
        let failures = entries.filter {
            $0.level == .warning && $0.message.contains("OCR failed on “clean-scan.png”")
        }
        #expect(failures.isEmpty, "a successful OCR logged a failure: \(failures.map(\.message))")
    }

    // MARK: A garbled text layer is read with OCR

    /// A one-page PDF that draws `lines` in Helvetica while its text layer extracts as punctuation:
    /// the font's `ToUnicode` map sends every printable code to one of fifteen symbols, the way a
    /// broken map garbles every live PG&E statement on his tree. Hand-written, since CoreGraphics
    /// always writes a correct map.
    private static func writeGarbledPDF(lines: [String], to path: String) throws {
        let symbols = Array("!\"#$%&'()*+,-./".unicodeScalars)
        let codes = 0x20...0x7E
        var cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapName /Garbled def\n"
            + "/CMapType 2 def\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n\(codes.count) beginbfchar\n"
        for c in codes {
            cmap += String(format: "<%02X> <%04X>\n", c, Int(symbols[c % symbols.count].value))
        }
        cmap += "endbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        let escaped = lines.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        }
        let content = "BT /F1 14 Tf 18 TL 50 740 Td\n" + escaped.map { "(\($0)) Tj T*\n" }.joined() + "ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
            "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)endstream",
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
            + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
            + "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// A statement whose text layer is garbled is read from its page instead: the account number
    /// and dates the scan matches on come from OCR. Without the fallback the snippet is the soup.
    /// Pinned: Vision's `.accurate` recognizer fails on GitHub's hosted VMs.
    @Test(.machinePinned(.textRecognition)) func aGarbledTextLayerIsReadWithOCR() async throws {
        let dir = FixtureDir()
        let path = dir.path("garbled-statement.pdf")
        try Self.writeGarbledPDF(lines: [
            "ENERGY STATEMENT", "Account No: 1234567890-5", "Statement Date: 03/18/2026",
            "Due Date: 04/08/2026", "Your Account Summary", "Amount Due on Previous Statement $351.24",
            "Total Amount Due $330.76",
        ], to: path)

        // The fixture must be garbled, or the read below proves nothing.
        let layer = try #require(await ContentSignalExtractor.snippet(forFileAt: path, ocr: false))
        #expect(FilingSurvey.isGarbled(layer), "the fixture's text layer reads: \(layer)")
        #expect(!layer.contains("Account"))

        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.contains("Account No: 1234567890-5"), "read: \(snippet)")
        let facts = DocumentFacts(page: snippet)
        #expect(facts.ownNumbers.map(\.ending).contains("8905"))
        #expect(facts.period?.year == 2026 && facts.period?.month == 3)
    }

    // MARK: PDF extraction is serialized

    /// PDFKit's text extraction is not thread-safe, so this queue must stay serial: read
    /// concurrently, some documents silently return reordered or dropped text. Asserts peak
    /// concurrency, so a `.concurrent` lane or anything else letting two parses overlap fails it.
    @Test func pdfExtractionNeverRunsTwoParsesAtOnce() async throws {
        let dir = FixtureDir()
        let paths = try (0..<12).map { i -> String in
            let p = dir.path("doc\(i).pdf")
            // Five pages, the cap this reader stops at, so each parse is long enough to overlap
            // its neighbours if the queue allows it.
            try Self.writePDF(lines: (0..<5).map { "Statement page \($0) of document \(i)." }, to: p)
            return p
        }
        let read = await withTaskGroup(of: Bool.self) { group -> Int in
            for p in paths {
                group.addTask { await ContentSignalExtractor.snippet(forFileAt: p) != nil }
                group.addTask { await !ContentSignalExtractor.tokens(forFileAt: p).isEmpty }
            }
            var ok = 0
            for await didRead in group where didRead { ok += 1 }
            return ok
        }
        // Non-vacuity, separately: `== 1` catches a peak of 0, but a run where every parse came
        // back empty still moves the counter, so the fixture being readable is its own claim.
        #expect(read == paths.count * 2, "only \(read) of \(paths.count * 2) reads produced anything")

        let peak = PDFKitSerialAccess.peakConcurrentParses
        #expect(peak == 1, "\(peak) PDF parses overlapped — extraction is no longer serialized")
    }

    // MARK: - "Could not look" is not "nothing to say"

    /// Every reader answers `""` on failure, so a log line is all that tells a read failure from an
    /// empty document. Real files make the reads fail: `chmod 000` for text, non-PDF bytes for PDF;
    /// each read under a `LogCapture` opened first, with a fixture name no other test writes.
    @MainActor
    @Test func aFileThatCannotBeReadSaysSoRatherThanReadingAsEmpty() async throws {
        let dir = FixtureDir()
        let path = dir.path("unreadable-notes.txt")
        try "policy declarations geico".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        let log = LogCapture()
        #expect(ContentSignalExtractor.extractTextSync(URL(fileURLWithPath: path)).isEmpty,
                "the fixture is readable after chmod 000 — this test is not exercising a failed read")

        let said = await log.entries.filter {
            $0.level == .warning && $0.message.contains("unreadable-notes.txt")
        }
        #expect(!said.isEmpty,
                "a text file that could not be opened produced no text and no warning — the document is classified on its filename alone and nothing says why")
    }

    /// The same for the PDF branch. `PDFDocument(url:)` returns nil rather than throwing, so there
    /// is no error to quote and the line says only that it didn't open.
    @MainActor
    @Test func aPDFThatWillNotOpenSaysSo() async throws {
        let dir = FixtureDir()
        let path = dir.path("unparseable-statement.pdf")
        try Data("this is not a pdf".utf8).write(to: URL(fileURLWithPath: path))

        let log = LogCapture()
        #expect(ContentSignalExtractor.extractTextSync(URL(fileURLWithPath: path)).isEmpty)

        let said = await log.entries.filter {
            $0.level == .warning && $0.message.contains("unparseable-statement.pdf")
        }
        #expect(!said.isEmpty, "a PDF that will not parse read as a PDF with no text in it")
    }

    /// The guard on both: a file that reads fine logs nothing. A scan walks thousands of
    /// documents, and a per-file line on the happy path would bury the warnings above.
    @MainActor
    @Test func aFileThatReadsFineIsSilent() async throws {
        let dir = FixtureDir()
        let path = dir.path("quiet-notes.txt")
        try "Declarations Page. Your GEICO auto insurance policy."
            .write(toFile: path, atomically: true, encoding: .utf8)

        let log = LogCapture()
        #expect(ContentSignalExtractor.extractTextSync(URL(fileURLWithPath: path)).contains("GEICO"),
                "the fixture did not read — a silent log would then prove nothing")

        // After the read, so a capture that holds it was listening throughout.
        let marker = "quiet-read window close \(UUID().uuidString)"
        Logger.shared.debug(marker)
        let entries = await log.entries
        let heard = entries.contains { $0.message == marker }
        try #require(heard, "the capture never saw this test's own line, so the silence below would prove nothing")
        let said = entries.filter { $0.message.contains("quiet-notes.txt") }
        #expect(said.isEmpty, "a readable file logged \(said.map(\.message)) — the warnings above would be lost in the noise")
    }

    /// The scan's budget holds for page reads too, run several at once: past the first 20 a scan,
    /// a file that won't read is kept for the closing line, not logged on its own.
    @Test func pageReadsRunTogetherShareTheScansWarningBudget() async throws {
        let dir = FixtureDir()
        let paths = (0..<25).map { dir.path("broken-\($0).png") }
        for path in paths { try Data("not an image".utf8).write(to: URL(fileURLWithPath: path)) }
        let budget = FilingWarningBudget()
        await FilingWarningBudget.$current.withValue(budget) {
            await withTaskGroup(of: Void.self) { group in
                for path in paths { group.addTask { _ = await ContentSignalExtractor.snippet(forFileAt: path) } }
            }
        }
        let closing = budget.overflowLines().joined(separator: "\n")
        #expect(closing.contains("5 more file(s)"), "\(closing)")
    }
}
