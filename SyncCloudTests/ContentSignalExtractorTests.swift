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

    /// End-to-end OCR over a synthetic scan: huge, clean, black-on-white text that Vision's `.fast`
    /// recognizer reads reliably. A real Vision call, the extractor's one environment-dependent
    /// piece, kept easy so the test stays deterministic.
    @Test func imageTextIsExtractedViaOCR() async throws {
        let dir = FixtureDir()
        let path = dir.path("scan.png")
        try Self.writeTextImage("INVOICE 1099", to: path)
        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.uppercased().contains("INVOICE"))
        let tokens = await ContentSignalExtractor.tokens(forFileAt: path)
        #expect(tokens.contains("invoice"))
        #expect(tokens.contains("1099"))
    }

    /// A scan Vision reads must not also report that Vision failed.
    ///
    /// The "OCR failed on …" warning lets an operator tell a broken recognizer from a folder of
    /// blank scans, which works only if it stays inside the throwing branch. Logged beside the
    /// `perform` instead of in its `catch`, it would fire every time, and the extracted text would
    /// look the same.
    ///
    /// The failing direction isn't tested: `VNImageRequestHandler.perform` throws only for a
    /// recognizer that can't run, there is no seam for a stub handler, and every image CoreGraphics
    /// decodes is one Vision accepts (the corrupt fixture above fails at `CGImageSourceCreate…`).
    ///
    /// The absence is read from a `LogCapture` opened before the call ("A log assertion reading a
    /// window that has already rolled" in `docs/flaky-tests.md`): `Logger.shared.entries` is one
    /// process-wide window that can roll past the whole call and pass having examined nothing. A
    /// line written after the call is `#require`d from the capture, so a capture that heard
    /// nothing fails. No `.serialized` needed: no other test writes `clean-scan.png`.
    @MainActor
    @Test func aScanThatOCRsCleanlyReportsNoOCRFailure() async throws {
        let dir = FixtureDir()
        let path = dir.path("clean-scan.png")
        try Self.writeTextImage("INVOICE 1099", to: path)

        let log = LogCapture()

        // The fixture must really OCR, or the no-warning assertion below proves nothing.
        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.uppercased().contains("INVOICE"))

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

    // MARK: PDF extraction is serialized

    /// PDFKit's text extraction is not thread-safe, so this queue must stay serial.
    ///
    /// Read concurrently, about 1% of real documents return different text from run to run. The
    /// damage is silent (reordered or dropped blocks, still decodable prose), so nothing downstream
    /// can notice it.
    ///
    /// Asserts the outcome, peak concurrency, not the source: a `.concurrent` shared lane fails
    /// this, as does anything else that lets two parses overlap. The counter exists for this test,
    /// since serialization has no other outside signature.
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

    /// Every reader here answers `""` on failure, so a log line is the only thing that separates a
    /// read failure from an empty document. Without one, a text file the scan can't open or a PDF
    /// that won't parse goes to the classifier on its filename alone, with nothing saying why.
    ///
    /// Driven with real files, the only way to make these reads fail: `chmod 000` for the text
    /// branch, bytes that aren't a PDF for the other. Both read a `LogCapture` opened before the
    /// read, like the OCR test above, and use fixture names no other test writes.
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
