import AppKit
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SyncCloud

/// Coverage for the text→tokens step of the on-device Filing content extractor (F2). The PDF/OCR
/// readers need real files; this pins the NaturalLanguage + category-keyword tokenization that
/// turns extracted text into the tokens the FilingEngine matches on.
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

    /// Writes a real one-or-more-page PDF whose pages each draw one line of genuine text ops
    /// (so PDFKit's text extraction sees it), and returns its path.
    private static func writePDF(lines: [String], to path: String) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for line in lines {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 24)])
            context.textPosition = CGPoint(x: 72, y: 400)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
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

    /// A plain local text file: readable head comes back verbatim, and the evicted-iCloud guard
    /// (which this path always crosses) answers false for a non-ubiquitous file.
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
    /// recognizer reads reliably. (This is a real Vision call — the one environment-dependent piece
    /// of the extractor — kept deliberately easy so the test stays deterministic.)
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

    // MARK: PDF extraction is serialized

    /// **PDFKit's text extraction is not thread-safe, so this queue must stay serial.**
    ///
    /// Measured on a real 10,286-document tree, this reader six at a time returned different text
    /// for 1.69% of documents run to run; one mortgage statement read 30 times serially gave one
    /// text and 18 distinct texts once read concurrently. The damage is silent — reordered or
    /// dropped blocks, still perfectly decodable prose — so nothing downstream can notice it.
    ///
    /// Asserting the outcome (peak concurrency) rather than the source: a `.concurrent` attribute
    /// added back to `pdfQueue` fails this, and so does anything else that lets two parses overlap.
    /// The counter is instrumentation for exactly this, since serialization has no other outside
    /// signature short of the sub-2%-of-documents flake this suite has no corpus to reproduce.
    @Test func pdfExtractionNeverRunsTwoParsesAtOnce() async throws {
        let dir = FixtureDir()
        // Enough pages that a parse takes long enough to overlap with its neighbours if it can.
        let paths = try (0..<12).map { i -> String in
            let p = dir.path("doc\(i).pdf")
            // One page per line, five pages — the cap this reader stops at, so each parse is long
            // enough to overlap with its neighbours if the queue allows it.
            try Self.writePDF(lines: (0..<5).map { "Statement page \($0) of document \(i)." }, to: p)
            return p
        }
        ContentSignalExtractor.resetPeakConcurrentPDFParses()

        await withTaskGroup(of: Void.self) { group in
            for p in paths {
                group.addTask { _ = await ContentSignalExtractor.snippet(forFileAt: p) }
                group.addTask { _ = await ContentSignalExtractor.tokens(forFileAt: p) }
            }
        }

        // Non-vacuity: if nothing was parsed, the peak is trivially 1 and proves nothing.
        let peak = ContentSignalExtractor.peakConcurrentPDFParses
        #expect(peak == 1, "\(peak) PDF parses overlapped — extraction is no longer serialized")
    }

    /// The companion to the above: the parses really did happen, and really were issued
    /// concurrently. Without this, `peakConcurrentPDFParses == 1` is satisfied by a run in which
    /// the extractor read nothing at all.
    @Test func theSerializationTestActuallyParsesConcurrentlyIssuedWork() async throws {
        let dir = FixtureDir()
        let paths = try (0..<6).map { i -> String in
            let p = dir.path("doc\(i).pdf")
            try Self.writePDF(lines: ["MARKER\(i) statement policy"], to: p)
            return p
        }
        ContentSignalExtractor.resetPeakConcurrentPDFParses()
        let texts = await withTaskGroup(of: String?.self) { group -> [String] in
            for p in paths { group.addTask { await ContentSignalExtractor.snippet(forFileAt: p) } }
            var out: [String] = []
            for await t in group { if let t { out.append(t) } }
            return out
        }
        #expect(texts.count == 6, "only \(texts.count) of 6 documents were read")
        #expect(ContentSignalExtractor.peakConcurrentPDFParses >= 1,
                "the counter never moved — it is not observing the parse")
    }
}
