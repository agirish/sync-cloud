import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import SyncCloud

/// Scanned PDFs drawn here: a picture of words, laid on a page as an image, and pages of real text
/// beside it.
enum ScanFixture {

    enum Page {
        /// Words drawn into a bitmap, and the bitmap laid on the page: no text layer. `below` is a
        /// second line near the foot of the page; `cropTop` crops the page to its top half.
        case picture(String, below: String? = nil, font: String = "Helvetica", cropTop: Bool = false)
        /// Words drawn as text: a text layer.
        case text(String)
    }

    /// A letter-size PDF of `pages`, in a scratch folder the caller removes; locked with a password
    /// when `password` is given.
    static func pdf(_ pages: [Page], password: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Scan.pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let locks = password.map { [kCGPDFContextUserPassword as String: $0, kCGPDFContextOwnerPassword as String: $0] }
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, locks as CFDictionary?))
        for page in pages {
            switch page {
            case .picture(let words, let below, let font, let cropTop):
                var crop = CGRect(x: 0, y: 396, width: 612, height: 396)
                let info = cropTop ? [kCGPDFContextCropBox as String: Data(bytes: &crop, count: MemoryLayout<CGRect>.size)] : nil
                context.beginPDFPage(info as CFDictionary?)
                // At 2×, as a 144 dpi scan would be.
                let bitmap = try #require(CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0,
                                                   space: CGColorSpaceCreateDeviceRGB(),
                                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
                bitmap.scaleBy(x: 2, y: 2)
                draw(words, at: 680, font: font, in: bitmap)
                if let below { draw(below, at: 100, font: font, in: bitmap) }
                context.draw(try #require(bitmap.makeImage()), in: media)
            case .text(let words):
                context.beginPDFPage(nil)
                draw(words, at: 680, font: "Helvetica", in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func draw(_ words: String, at y: CGFloat, font name: String, in context: CGContext) {
        let font = CTFontCreateWithName(name as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: words, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 72, y: y)
        CTLineDraw(line, context)
    }
}

/// **Ask Claude reads a scanned PDF by OCR** (TE264, gap G13): a page that is only a picture has no
/// text layer, and `read_text` gave the on-device model nothing for it. These read with Vision.
///
/// **Three minutes to read in, not `ocrTimeout`'s 30 seconds:** Vision's first request under a new
/// bundle id, or after macOS recompiles its models, waits 60–90 s, and these check what is read,
/// not how fast.
@Suite(.serialized, .machinePinned(.textRecognition)) struct AskClaudeScanReadingTests {

    private static let patience: Duration = .seconds(180)

    /// **A picture page is read by OCR; a page with a text layer is left as it reads.** The
    /// fixture's picture page has no text layer — `extract`, which reads no picture, gets nothing
    /// from it — so only OCR can put its words in.
    @Test func aPicturePageIsReadByOCR() async throws {
        let url = try ScanFixture.pdf([.picture("Parking space number 17 is assigned to apartment 4B"),
                                       .text("Monthly rent of 2400 dollars is due on the first of the month")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let layer = try #require(await AskClaudeReading.extract(url.path))
        #expect(layer[0].isEmpty && layer[1].contains("Monthly rent"))

        let read = try #require(await AskClaudeReading.read(url.path, ocrWithin: Self.patience))
        #expect(read.recognized == [0] && read.timedOut.isEmpty && read.pastLimit.isEmpty)
        #expect(read.pages[0].contains("Parking space number 17"), "OCR read: \(read.pages[0])")
        #expect(read.pages[1] == layer[1])
        #expect(read.ocrNote == "Page 1 of 2 has little or no text layer, so it was read by OCR on this Mac: a word may be misread.")
    }

    /// **OCR stops at its page limit, and says which pages it left.** Eleven picture pages around
    /// one of text: the first ten pictures are read, the last is named as unread.
    @Test func ocrStopsAtItsPageLimit() async throws {
        var pages = (1...12).map { ScanFixture.Page.picture("This is scanned page number \($0) of the lease") }
        pages[1] = .text("This page has a real text layer with plenty of words in it")
        let url = try ScanFixture.pdf(pages)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try #require(await AskClaudeReading.read(url.path, ocrWithin: Self.patience))
        #expect(read.recognized == [0] + Array(2...10))
        #expect(read.pastLimit == [11] && read.timedOut.isEmpty)
        #expect(read.pages[10].contains("page number 11"), "OCR read: \(read.pages[10])")
        #expect(read.pages[11].isEmpty)
        #expect(read.ocrNote == "Pages 1 and 3–11 of 12 have little or no text layer, so they were read by OCR on this Mac: a word may be misread. OCR reads at most 10 pages of a file, so page 12 wasn’t read.")
    }

    /// **What a page's crop hides is not read.** The page is cropped to its top half, with a line in
    /// each half of the picture: a viewer, and the text layer, show only the first. Drawn by the
    /// media box, OCR read the hidden one too.
    @Test func aCroppedAwayLineIsNotRead() async throws {
        let url = try ScanFixture.pdf([.picture("Statement for the month of October", below: "Account number 4417 9921 0006", cropTop: true)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try #require(await AskClaudeReading.read(url.path, ocrWithin: Self.patience))
        #expect(read.pages[0].contains("Statement for the month"), "OCR read: \(read.pages[0])")
        #expect(!read.pages[0].contains("4417"), "OCR read the cropped-away line: \(read.pages[0])")
    }

    /// **A page in another script is read.** Vision reads English only unless asked to detect the
    /// language, and read this Chinese line as nothing.
    @Test func aChinesePageIsRead() async throws {
        let url = try ScanFixture.pdf([.picture("租赁合同第十七号停车位", font: "PingFang SC")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try #require(await AskClaudeReading.read(url.path, ocrWithin: Self.patience))
        #expect(read.pages[0].contains("停车位"), "OCR read: \(read.pages[0])")
    }
}

/// **What `read` makes of what OCR gives**, with the reading injected: no Vision, so these run on
/// any Mac. The PDFs and the PDFKit lane are real.
@Suite struct AskClaudeScanResultTests {

    /// **OCR stops when its time runs out, and keeps what it read.** The second page's reading is
    /// held past the limit; the first page's words are kept, and the rest are named as unread. Ten
    /// seconds, so a PDF lane busy with another suite can't make the first page late too.
    @Test func ocrStopsWhenItsTimeRunsOut() async throws {
        let url = try ScanFixture.pdf((1...3).map { .picture("Scanned page \($0) of the insurance policy") })
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let calls = Calls()
        let read = try #require(await AskClaudeReading.read(url.path, ocrWithin: .seconds(10)) { _ in
            if calls.next() > 1 { Thread.sleep(forTimeInterval: 15) }
            return "Words read from page one"
        })
        #expect(read.recognized == [0] && read.timedOut == [1, 2] && read.secondsAllowed == 10)
        #expect(read.pages[0] == "Words read from page one")
        #expect(read.ocrNote == "Page 1 of 3 has little or no text layer, so it was read by OCR on this Mac: a word may be misread. OCR stopped after 10 seconds, so pages 2–3 weren’t read. Text recognition can take a minute or two to get ready, so asking again shortly may read them.")
    }

    /// **When nothing is read in time, Claude is told to ask again**, for the pages a second ask
    /// would read: the first ten. Those past the limit are said apart, as never read at all.
    @Test func nothingReadInTimeSaysAskAgain() async throws {
        let url = try ScanFixture.pdf((1...12).map { .picture("Scanned page \($0)") })
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try #require(await AskClaudeReading.read(url.path, ocrWithin: .seconds(1)) { _ in
            Thread.sleep(forTimeInterval: 4)
            return "Too late"
        })
        #expect(!read.hasText && read.recognized.isEmpty && read.timedOut == Array(0..<10) && read.pastLimit == [10, 11])
        #expect(read.ocrNote == "Pages 1–10 of 12 have little or no text layer, and OCR stopped after 1 second, before reading them. Text recognition can take a minute or two to get ready, so asking again shortly may read them. OCR reads at most 10 pages of a file, so pages 11–12 weren’t read.")
    }

    /// **Stopping the question stops the reading**: no page is read after it, and it answers at
    /// once rather than at the time limit.
    @Test func stoppingTheQuestionStopsOCR() async throws {
        let url = try ScanFixture.pdf((1...5).map { .picture("Scanned page \($0)") })
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let calls = Calls()
        let reading = Task {
            await AskClaudeReading.read(url.path, ocrWithin: .seconds(120)) { _ in
                _ = calls.next()
                Thread.sleep(forTimeInterval: 1)
                return "Words"
            }
        }
        let deadline = Date().addingTimeInterval(60)
        while calls.count == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(calls.count == 1, "the first page never began")
        let stoppedAt = Date()
        reading.cancel()
        #expect(await reading.value == nil)
        #expect(Date().timeIntervalSince(stoppedAt) < 10)
        // The page under way finishes on its own; none starts after it.
        try await Task.sleep(for: .seconds(2))
        #expect(calls.count == 1)
    }

    /// **What `read` draws for Vision is the crop box, capped**: the top half of a letter page is
    /// 612 by 396 points, so 1920 by 1242 pixels. A media box would be 1484 by 1920.
    @Test func ocrIsGivenTheCropBoxAtTheReadSize() async throws {
        let url = try ScanFixture.pdf([.picture("Statement for the month of October", cropTop: true)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sizes = Sizes()
        _ = await AskClaudeReading.read(url.path) { image in
            sizes.add(image.width, image.height)
            return "Statement for the month of October"
        }
        #expect(sizes.all.count == 1 && sizes.all.first?.0 == 1920 && sizes.all.first?.1 == 1242)
    }

    /// **A short real text layer stands when OCR reads no more**, and the page isn't said to be
    /// read by OCR: a cover page's “Lease 2025” is under the near-empty count but is its words.
    @Test func aShortTextLayerStandsWhenOCRReadsNoMore() async throws {
        let url = try ScanFixture.pdf([.text("Lease 2025")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try #require(await AskClaudeReading.read(url.path) { _ in "Lease" })
        #expect(read.pages[0].contains("Lease 2025"))
        #expect(read.recognized.isEmpty && read.blank.isEmpty && read.failed.isEmpty && read.ocrNote == nil)
    }

    /// **A blank page and a failed reading are said as such**, not as pages read by OCR.
    @Test func blankAndFailedPagesAreSaid() async throws {
        let url = try ScanFixture.pdf((1...3).map { .picture("Scanned page \($0)") })
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let calls = Calls()
        let read = try #require(await AskClaudeReading.read(url.path) { _ in
            switch calls.next() {
            case 1: ""
            case 2: nil
            default: "Words on the third page"
            }
        })
        #expect(read.blank == [0] && read.failed == [1] && read.recognized == [2])
        #expect(read.ocrNote == "Page 3 of 3 has little or no text layer, so it was read by OCR on this Mac: a word may be misread. OCR found no words on page 1. Text recognition failed on page 2.")
    }

    /// **A scan whose first ten pages hold no words still says why**, and that pages were left:
    /// it once came back as a file with no text to read at all.
    @Test func aScanOCRFindsNothingInStillSaysWhy() async throws {
        let url = try ScanFixture.pdf((1...12).map { .picture("Scanned page \($0)") })
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try #require(await AskClaudeReading.read(url.path) { _ in "" })
        #expect(!read.hasText && read.blank == Array(0..<10) && read.pastLimit == [10, 11])
        #expect(read.ocrNote == "OCR found no words on pages 1–10. OCR reads at most 10 pages of a file, so pages 11–12 weren’t read.")
    }

    /// **A PDF locked with a password says so**, and nothing is read from it.
    @Test func aLockedPDFIsSaidToBeLocked() async throws {
        let url = try ScanFixture.pdf([.picture("Scanned page")], password: "secret")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try #require(await AskClaudeReading.read(url.path) { _ in
            Issue.record("read a locked PDF")
            return nil
        })
        #expect(read.locked && !read.hasText)
        // Not tried: a locked page draws as nothing, which would read as a failed recognition.
        #expect(read.failed.isEmpty && read.blank.isEmpty && read.timedOut.isEmpty && read.pastLimit.isEmpty && read.ocrNote == nil)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        var count: Int { lock.withLock { made } }
        func next() -> Int { lock.withLock { made += 1; return made } }
    }

    private final class Sizes: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(Int, Int)] = []
        var all: [(Int, Int)] { lock.withLock { seen } }
        func add(_ width: Int, _ height: Int) { lock.withLock { seen.append((width, height)) } }
    }
}
