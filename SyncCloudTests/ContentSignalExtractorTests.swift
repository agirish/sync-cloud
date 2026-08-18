import AppKit
import CoreText
import Events
import Foundation
import ImageIO
import Sync
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
    /// One line per page — the shape most of these tests want.
    private static func writePDF(lines: [String], to path: String) throws {
        try writePDF(pages: lines.map { [$0] }, to: path)
    }

    /// Pages of lines. A single `CTLine` is clipped at the page edge, so a "long" string drawn as
    /// one line extracts as about fifty characters however long it is — which is why a test about
    /// a first page that says PLENTY has to draw many lines rather than one long one.
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

    /// **Five pages is a fallback for a thin first page, not a target.** Nothing downstream reads
    /// that much — the router scores 400 characters, the on-device prompt carries 1,200, the cloud
    /// one 800 — so a 14-page phone bill was parsed five pages deep to produce 16,910 characters of
    /// which every consumer used the first few hundred, on every classifiable file in the scan.
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

    /// A scan Vision reads must not also report that Vision failed.
    ///
    /// The "OCR failed on …" warning exists so an operator can tell a broken recognizer from a
    /// folder of blank scans — which only works if it is confined to the throwing branch. A line
    /// emitted unconditionally (logged beside the `perform` rather than inside its `catch`) would
    /// destroy exactly the distinction it was added for, and nothing else in this suite would
    /// notice: the extracted text is identical either way.
    ///
    /// **The failing direction is deliberately not tested.** `VNImageRequestHandler.perform` throws
    /// only for a recognizer that cannot run at all, there is no seam to inject a stub handler, and
    /// every image this suite can construct that CoreGraphics decodes is one Vision accepts — the
    /// corrupt-image fixture above never reaches `perform`, it fails at `CGImageSourceCreate…`. So
    /// this pins the half that a test can actually reach and says so rather than pretending.
    ///
    /// **The absence is read from this test's own marker forward** — mechanism 12 in
    /// `docs/flaky-tests.md`. `Logger.shared.entries` is one process-wide 1000-line window that
    /// every suite writes into at once, and the flush marker this used to rely on was written
    /// *after* the OCR call and never asserted present. That guarantees the line is **visible** if
    /// it exists — the queue is FIFO, so awaiting a fresh entry's task drains everything enqueued
    /// before it — and says nothing about whether it **survived**. On a busy run the window can roll
    /// past the whole call, and an absence measured over a window that no longer holds the interval
    /// passes having examined nothing: the one failure shape in that file with no symptom at all.
    /// So a unique marker goes in FIRST, its index is `#require`d, and the filter reads only the
    /// slice from it onward. A rolled window now fails, loudly, saying the reading was vacuous.
    ///
    /// No `.serialized` is needed: the fragment carries `clean-scan.png`, a fixture name no other
    /// test in this suite or this repo writes (`imageTextIsExtractedViaOCR` uses `scan.png`), so a
    /// sibling running concurrently cannot drop the asserted line inside the window.
    @MainActor
    @Test func aScanThatOCRsCleanlyReportsNoOCRFailure() async throws {
        let dir = FixtureDir()
        let path = dir.path("clean-scan.png")
        try Self.writeTextImage("INVOICE 1099", to: path)

        // Before the call under test, so it is older than anything the OCR could write: if this is
        // still in the window, so is everything after it.
        let marker = "ocr-failure window open \(UUID().uuidString)"
        await Logger.shared.debug(marker).value

        // The fixture must really OCR, or the no-warning assertion below proves nothing.
        let snippet = try #require(await ContentSignalExtractor.snippet(forFileAt: path))
        #expect(snippet.uppercased().contains("INVOICE"))

        await Logger.shared.debug("ocr-failure-log flush marker").value
        let entries = Logger.shared.entries
        // The INDEX is computed before the `#require`, deliberately. `#require`ing anything that
        // holds the entries themselves prints the whole buffer on failure — measured at 152KB of
        // `LogEntry` — which buries the one sentence that explains what went wrong.
        let opened = entries.lastIndex { $0.message == marker }
        let start = try #require(opened,
                                 "the 1000-line log window rolled past this test's own marker, so the absence below would have examined nothing — see mechanism 12 in docs/flaky-tests.md")
        let failures = entries[start...].filter {
            $0.level == .warning && $0.message.contains("OCR failed on “clean-scan.png”")
        }
        #expect(failures.isEmpty, "a successful OCR logged a failure: \(failures.map(\.message))")
    }

    // MARK: PDF extraction is serialized

    /// **PDFKit's text extraction is not thread-safe, so this queue must stay serial.**
    ///
    /// Measured on a real 10,286-document tree, this reader six at a time returned different text
    /// for 0.83% of documents run to run; one mortgage statement read 30 times serially gave one
    /// text and 18 distinct texts once read concurrently. The damage is silent — reordered or
    /// dropped blocks, still perfectly decodable prose — so nothing downstream can notice it.
    ///
    /// Asserting the outcome (peak concurrency) rather than the source: a `.concurrent` attribute
    /// added back to the shared lane fails this, and so does anything else that lets two overlap.
    /// The counter is instrumentation for exactly this, since serialization has no other outside
    /// signature short of the sub-2%-of-documents flake this suite has no corpus to reproduce.
    @Test func pdfExtractionNeverRunsTwoParsesAtOnce() async throws {
        let dir = FixtureDir()
        let paths = try (0..<12).map { i -> String in
            let p = dir.path("doc\(i).pdf")
            // One page per line, five pages — the cap this reader stops at, so each parse is long
            // enough to overlap with its neighbours if the queue allows it.
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
        // Non-vacuity, asserted separately: nothing parsed leaves the peak at 0, which `== 1` does
        // catch — but a run where every parse came back EMPTY would still move the counter, so the
        // fixture being readable is its own claim.
        #expect(read == paths.count * 2, "only \(read) of \(paths.count * 2) reads produced anything")

        let peak = PDFKitSerialAccess.peakConcurrentParses
        #expect(peak == 1, "\(peak) PDF parses overlapped — extraction is no longer serialized")
    }

    /// The companion to the above: the parses really did happen, and really were issued
    /// concurrently. Without this, `peakConcurrentParses == 1` is satisfied by a run in which
    /// the extractor read nothing at all.
    @Test func theSerializationTestActuallyParsesConcurrentlyIssuedWork() async throws {
        let dir = FixtureDir()
        let paths = try (0..<6).map { i -> String in
            let p = dir.path("doc\(i).pdf")
            try Self.writePDF(lines: ["MARKER\(i) statement policy"], to: p)
            return p
        }
        let texts = await withTaskGroup(of: String?.self) { group -> [String] in
            for p in paths { group.addTask { await ContentSignalExtractor.snippet(forFileAt: p) } }
            var out: [String] = []
            for await t in group { if let t { out.append(t) } }
            return out
        }
        #expect(texts.count == 6, "only \(texts.count) of 6 documents were read")
        #expect(PDFKitSerialAccess.peakConcurrentParses >= 1,
                "the counter never moved — it is not observing the parse")
        #expect(texts.allSatisfy { $0.contains("MARKER") },
                "a document came back without its marker — the reads are not returning real text")
    }

    // MARK: - "Could not look" is not "nothing to say"

    /// **Every reader here answers `""` on failure, so a log line is the only thing that separates a
    /// read failure from a document with nothing in it.** Two of the three branches had none: a text
    /// file the scan cannot open, and a PDF that will not parse, each contributed no tokens and no
    /// excerpt, and the document then went to the classifier on its filename alone with nothing
    /// anywhere saying why. The OCR branch beside them already argues exactly that case in prose.
    ///
    /// Driven with real files, because that is the only way to make these reads fail: `chmod 000`
    /// for the text branch and bytes that are not a PDF for the other. Both are read through the
    /// marker-and-slice discipline the OCR test above establishes — see mechanism 12 in
    /// `docs/flaky-tests.md` — and the fixture names are unique to this test for the same reason.
    @MainActor
    @Test func aFileThatCannotBeReadSaysSoRatherThanReadingAsEmpty() async throws {
        let dir = FixtureDir()
        let path = dir.path("unreadable-notes.txt")
        try "policy declarations geico".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

        let marker = "unreadable-text window open \(UUID().uuidString)"
        await Logger.shared.debug(marker).value

        #expect(ContentSignalExtractor.extractTextSync(URL(fileURLWithPath: path)).isEmpty,
                "the fixture is readable after chmod 000 — this test is not exercising a failed read")

        // FIFO, so awaiting a later entry drains everything the read enqueued before it.
        await Logger.shared.debug("unreadable-text flush marker").value
        let entries = Logger.shared.entries
        let opened = entries.lastIndex { $0.message == marker }
        let from = try #require(opened,
                                "the 1000-line log window rolled past this test's own marker, so the reading below examined nothing — see mechanism 12 in docs/flaky-tests.md")
        let said = entries[from...].filter {
            $0.level == .warning && $0.message.contains("unreadable-notes.txt")
        }
        #expect(!said.isEmpty,
                "a text file that could not be opened produced no text and no warning — the document is classified on its filename alone and nothing says why")
    }

    /// The same for the PDF branch. `PDFDocument(url:)` returns nil rather than throwing, so there
    /// is no error to quote and the line says the one thing that is known — it did not open.
    @MainActor
    @Test func aPDFThatWillNotOpenSaysSo() async throws {
        let dir = FixtureDir()
        let path = dir.path("unparseable-statement.pdf")
        try Data("this is not a pdf".utf8).write(to: URL(fileURLWithPath: path))

        let marker = "unparseable-pdf window open \(UUID().uuidString)"
        await Logger.shared.debug(marker).value

        #expect(ContentSignalExtractor.extractTextSync(URL(fileURLWithPath: path)).isEmpty)

        await Logger.shared.debug("unparseable-pdf flush marker").value
        let entries = Logger.shared.entries
        let from = try #require(entries.lastIndex { $0.message == marker },
                                "the 1000-line log window rolled past this test's own marker — see mechanism 12 in docs/flaky-tests.md")
        let said = entries[from...].filter {
            $0.level == .warning && $0.message.contains("unparseable-statement.pdf")
        }
        #expect(!said.isEmpty, "a PDF that will not parse read as a PDF with no text in it")
    }

    /// **The guard on both.** A file that reads fine logs nothing, so the two tests above are about
    /// the failure rather than about this reader narrating every file it touches — a scan walks
    /// thousands of documents, and a per-file line on the happy path would bury the warnings it is
    /// there to surface.
    @MainActor
    @Test func aFileThatReadsFineIsSilent() async throws {
        let dir = FixtureDir()
        let path = dir.path("quiet-notes.txt")
        try "Declarations Page. Your GEICO auto insurance policy."
            .write(toFile: path, atomically: true, encoding: .utf8)

        let marker = "quiet-read window open \(UUID().uuidString)"
        await Logger.shared.debug(marker).value

        #expect(ContentSignalExtractor.extractTextSync(URL(fileURLWithPath: path)).contains("GEICO"),
                "the fixture did not read — a silent log would then prove nothing")

        await Logger.shared.debug("quiet-read flush marker").value
        let entries = Logger.shared.entries
        let from = try #require(entries.lastIndex { $0.message == marker },
                                "the 1000-line log window rolled past this test's own marker — see mechanism 12 in docs/flaky-tests.md")
        let said = entries[from...].filter { $0.message.contains("quiet-notes.txt") }
        #expect(said.isEmpty, "a readable file logged \(said.map(\.message)) — the warnings above would be lost in the noise")
    }
}
