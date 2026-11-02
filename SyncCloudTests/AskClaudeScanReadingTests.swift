import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import SyncCloud

/// **Ask Claude reads a scanned PDF by OCR** (TE264, gap G13): a page that is only a picture has no
/// text layer, and `read_text` gave the on-device model nothing for it. The fixtures are drawn
/// here: a picture of words, laid on a page as an image, and a page of real text beside it.
@Suite(.serialized, .machinePinned(.textRecognition)) struct AskClaudeScanReadingTests {

    enum Page {
        /// Words drawn into a bitmap, and the bitmap laid on the page: no text layer.
        case picture(String)
        /// Words drawn as text: a text layer.
        case text(String)
    }

    /// A letter-size PDF of `pages`, in a scratch folder the caller removes.
    static func pdf(_ pages: [Page]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Scan.pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .picture(let words):
                // At 2×, as a 144 dpi scan would be.
                let bitmap = try #require(CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0,
                                                   space: CGColorSpaceCreateDeviceRGB(),
                                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
                bitmap.scaleBy(x: 2, y: 2)
                draw(words, in: bitmap)
                context.draw(try #require(bitmap.makeImage()), in: media)
            case .text(let words):
                draw(words, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func draw(_ words: String, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: words, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 72, y: 680)
        CTLineDraw(line, context)
    }

    /// **A picture page is read by OCR; a page with a text layer is left as it reads.** The
    /// fixture's picture page has no text layer — `extract`, which reads no picture, gets nothing
    /// from it — so only OCR can put its words in.
    @Test func aPicturePageIsReadByOCR() async throws {
        let url = try Self.pdf([.picture("Parking space number 17 is assigned to apartment 4B"),
                                .text("Monthly rent of 2400 dollars is due on the first of the month")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let layer = try #require(await AskClaudeReading.extract(url.path))
        #expect(layer[0].isEmpty && layer[1].contains("Monthly rent"))

        let read = try #require(await AskClaudeReading.read(url.path))
        #expect(read.recognized == [0] && read.unread.isEmpty && read.stoppedBy == nil)
        #expect(read.pages[0].contains("Parking space number 17"), "OCR read: \(read.pages[0])")
        #expect(read.pages[1] == layer[1])
        #expect(read.ocrNote == "Page 1 of 2 has no text layer, so it was read by OCR on this Mac: a word may be misread.")
    }

    /// **OCR stops at its page limit, and says which pages it left.** Eleven picture pages around
    /// one of text: the first ten pictures are read, the last is named as unread.
    @Test func ocrStopsAtItsPageLimit() async throws {
        var pages = (1...12).map { Page.picture("This is scanned page number \($0) of the lease") }
        pages[1] = .text("This page has a real text layer with plenty of words in it")
        let url = try Self.pdf(pages)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let read = try #require(await AskClaudeReading.read(url.path))
        #expect(read.recognized == [0] + Array(2...10))
        #expect(read.unread == [11] && read.stoppedBy == .pageLimit)
        #expect(read.pages[10].contains("page number 11"), "OCR read: \(read.pages[10])")
        #expect(read.pages[11].isEmpty)
        #expect(read.ocrNote == "Pages 1 and 3–11 of 12 have no text layer, so they were read by OCR on this Mac: a word may be misread. OCR stopped at its 10-page limit, so page 12 wasn’t read.")
    }

    /// **OCR stops when its time runs out, and keeps what it read.** The second page's reading is
    /// held past the limit; the first page's words are kept, and the rest are named as unread. Five
    /// seconds, so a PDF lane busy with another suite can't make the first page late too.
    @Test func ocrStopsWhenItsTimeRunsOut() async throws {
        let url = try Self.pdf((1...3).map { .picture("Scanned page \($0) of the insurance policy") })
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let calls = Calls()
        let read = try #require(await AskClaudeReading.read(url.path, ocrWithin: .seconds(5)) { image in
            if calls.next() > 1 { Thread.sleep(forTimeInterval: 8) }
            return "Words read from page one"
        })
        #expect(read.recognized == [0] && read.unread == [1, 2] && read.stoppedBy == .time(seconds: 5))
        #expect(read.pages[0] == "Words read from page one")
        #expect(read.ocrNote == "Page 1 of 3 has no text layer, so it was read by OCR on this Mac: a word may be misread. OCR stopped after 5 seconds, so pages 2–3 weren’t read.")
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }
}
