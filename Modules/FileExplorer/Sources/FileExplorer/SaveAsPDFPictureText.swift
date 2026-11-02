import CoreGraphics
import CoreML
import CoreText
import Events
import Foundation
import Vision

/// **The words in a deck's slide pictures, read by Vision and laid invisibly over each page** — so a
/// deck whose slides are pictures, all or some of them, can still be searched and selected (R2,
/// decision AO's "searchable text later").
///
/// Each page is drawn to a bitmap and read with `VNRecognizeTextRequest`; then the page is drawn
/// again into a new PDF, its own content first and each recognised line over it in text render mode
/// 3 — invisible — at the line's box, stretched to the box's width so a selection covers the words
/// it names. The page looks exactly as it did.
///
/// **Measured 2026-10-19** on the three picture decks in ~/Documents (35 slides, 3750 px each):
/// 0.07–0.22 s a slide at 1920 px once Vision's model is loaded; the first request on the Mac took
/// 28 s. Titles, sentences and table figures read right — on a 99-line table slide, two slips — and
/// logos and the small print inside screenshots do not, hence the banner's "may have mistakes".
/// `.fast` lost 40 of 111 lines on a table slide; 1280 px read the same as 1920.
///
/// CoreGraphics and Vision only, no PDFKit, so nothing here is in `PDFKitSerialAccess`'s lane. It
/// blocks for the whole deck: call it off the main actor. Ask Claude's `read_text` reads scanned
/// PDF pages with ``text(in:)`` (TE264).
public enum PictureText {
    /// The bitmap Vision reads, by its longer side.
    static let readSize: CGFloat = 1920

    /// One recognised line: its words, and its box as a fraction of the page, origin bottom-left —
    /// Vision's own coordinates, which are the page's turned to fractions.
    struct Line {
        var text: String
        var box: CGRect
    }

    /// `pdf` with the recognised words of the pages in `reading` — counted from 0, every page when
    /// `nil` — laid over them, or `nil` when none had any: nothing to add, and the caller keeps the
    /// PDF it has. The other pages are carried over as they are, unread.
    static func searchable(_ pdf: Data, reading: Set<Int>? = nil) -> Data? {
        guard let document = PDFComposer.document(pdf), document.numberOfPages > 0 else { return nil }
        var composer = PDFComposer()
        var found = false
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { return nil }
            let paper = page.getBoxRect(.mediaBox).size
            // CoreGraphics counts pages from 1.
            let isRead = reading?.contains(number - 1) ?? true
            let lines = isRead ? recognise(page) : []
            found = found || !lines.isEmpty
            composer.add(page, paper: paper, into: CGRect(origin: .zero, size: paper)) { context in
                draw(lines, in: context, paper: paper)
            }
        }
        return found ? composer.finish() : nil
    }

    /// Which processor Vision may read on: its own choice, the Neural Engine when it has one, or
    /// the CPU alone.
    enum Processor: Sendable { case any, cpu }

    /// The page's lines, read on Vision's own choice of processor and, **when that fails, read
    /// again on the CPU**. The Neural Engine can refuse every request for hours while macOS
    /// recompiles its models: from 09:27 to 12:04 on 2026-10-25 every text request on this Mac
    /// failed with `e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options
    /// call failed (Code: 13)`, macOS's own `mediaanalysisd` included, while the same picture read
    /// on the CPU in 0.1–0.4 s. `read` is injectable so a test can be the refusal.
    static func recognise(_ page: CGPDFPage,
                          read: (CGImage, Processor) throws -> [Line] = read(_:on:)) -> [Line] {
        guard let image = bitmap(of: page) else { return [] }
        return recognise(image, read: read)
    }

    /// `image`'s lines, read as ``recognise(_:read:)`` reads a page's.
    ///
    /// **`cpuFirst` reads on the CPU and only falls back to Vision's own choice.** A binary's
    /// first request on the Neural Engine compiles its models: 70.5 s and 73.3 s for two fresh
    /// copies of one probe on 2026-11-02, against 0.29 s on the CPU and 0.13–0.14 s warm on
    /// either. Every install is a fresh binary, and a question can't wait a minute.
    static func recognise(_ image: CGImage, cpuFirst: Bool = false, reader: String = "Save as PDF",
                          read: (CGImage, Processor) throws -> [Line] = read(_:on:)) -> [Line] {
        let first: Processor = cpuFirst ? .cpu : .any
        let then: Processor = cpuFirst ? .any : .cpu
        do {
            return try read(image, first)
        } catch {
            // Said, because a Vision that fails reads exactly like slides with no words.
            Logger.shared.warning("\(reader): text recognition failed: \(error.localizedDescription); reading on \(then == .cpu ? "the CPU" : "Vision’s own choice")")
        }
        do {
            return try read(image, then)
        } catch {
            Logger.shared.warning("\(reader): text recognition failed on \(then == .cpu ? "the CPU" : "Vision’s own choice") too: \(error.localizedDescription)")
            return []
        }
    }

    /// The words Vision reads in `image`, a line each in Vision's order, on the CPU first; empty
    /// when it reads none. For a caller that draws the page itself, as Ask Claude does on the
    /// PDFKit lane.
    public static func text(in image: CGImage, reader: String) -> String {
        recognise(image, cpuFirst: true, reader: reader).map(\.text).joined(separator: "\n")
    }

    static func read(_ image: CGImage, on processor: Processor) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if processor == .cpu {
            for (stage, devices) in try request.supportedComputeStageDevices {
                guard let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) else { continue }
                request.setComputeDevice(cpu, for: stage)
            }
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first,
                  !best.string.allSatisfy(\.isWhitespace) else { return nil }
            return Line(text: best.string, box: observation.boundingBox)
        }
    }

    /// The page on white, its longer side ``readSize`` pixels — never below its own size in points,
    /// never above four times it.
    public static func bitmap(of page: CGPDFPage) -> CGImage? {
        let media = page.getBoxRect(.mediaBox)
        guard media.width > 0, media.height > 0 else { return nil }
        let scale = min(max(readSize / max(media.width, media.height), 1), 4)
        let width = Int((media.width * scale).rounded()), height = Int((media.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -media.minX, y: -media.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Each line in Helvetica, invisible, sized so its ascent and descent fill the box's height and
    /// stretched so its width fills the box's width. Characters Helvetica lacks fall back as Core
    /// Text picks.
    static func draw(_ lines: [Line], in context: CGContext, paper: CGSize) {
        guard !lines.isEmpty else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(x: line.box.minX * paper.width, y: line.box.minY * paper.height,
                             width: line.box.width * paper.width, height: line.box.height * paper.height)
            guard box.width > 0, box.height > 0 else { continue }
            let probe = CTFontCreateWithName("Helvetica" as CFString, box.height, nil)
            let font = CTFontCreateCopyWithAttributes(
                probe, box.height * box.height / (CTFontGetAscent(probe) + CTFontGetDescent(probe)), nil, nil)
            let text = NSAttributedString(string: line.text,
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let typeset = CTLineCreateWithAttributedString(text)
            let width = CTLineGetTypographicBounds(typeset, nil, nil, nil)
            guard width > 0 else { continue }
            context.textMatrix = CGAffineTransform(scaleX: box.width / width, y: 1)
            context.textPosition = CGPoint(x: box.minX, y: box.minY + CTFontGetDescent(font))
            CTLineDraw(typeset, context)
        }
        context.restoreGState()
    }
}
