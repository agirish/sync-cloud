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
    public static let readSize: CGFloat = 1920

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
                          read: (CGImage, Processor) throws -> [Line] = { try PictureText.read($0, on: $1) }) -> [Line] {
        guard let image = bitmap(of: page) else { return [] }
        return recognise(image, read: read)
    }

    /// `image`'s lines, read as ``recognise(_:read:)`` reads a page's; none when Vision fails on
    /// both processors.
    static func recognise(_ image: CGImage, read: (CGImage, Processor) throws -> [Line] = { try PictureText.read($0, on: $1) }) -> [Line] {
        (try? lines(in: image, reader: "Save as PDF", read: read)) ?? []
    }

    /// `image`'s lines, or the CPU's error when Vision fails on both processors.
    private static func lines(in image: CGImage, reader: String,
                              read: (CGImage, Processor) throws -> [Line]) throws -> [Line] {
        do {
            return try read(image, .any)
        } catch {
            // Said, because a Vision that fails reads exactly like slides with no words.
            Logger.shared.warning("\(reader): text recognition failed: \(error.localizedDescription); reading on the CPU")
        }
        do {
            return try read(image, .cpu)
        } catch {
            Logger.shared.warning("\(reader): text recognition failed on the CPU too: \(error.localizedDescription)")
            throw error
        }
    }

    /// The words Vision reads in `image`, a line each in Vision's order, in whatever language it
    /// finds; nil when Vision fails on both processors, so a failure isn't taken for a blank page.
    /// For a caller that draws the page itself, as Ask Claude does on the PDFKit lane.
    ///
    /// **The language is detected**, where Save as PDF reads English only, Vision's default: a
    /// scanned Chinese, Japanese or Hindi page read as nothing without it, and English pages read
    /// the same with it (99–100% of words alike on six pages of three of his scans, 2026-11-02).
    public static func text(in image: CGImage, reader: String) -> String? {
        let found = try? lines(in: image, reader: reader) { try read($0, on: $1, detectingLanguage: true) }
        return found.map { $0.map(\.text).joined(separator: "\n") }
    }

    static func read(_ image: CGImage, on processor: Processor, detectingLanguage: Bool = false) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = detectingLanguage
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
        bitmap(of: page, box: .mediaBox, longestSide: nil)
    }

    /// The page's `box` on white, as ``bitmap(of:)`` draws the media box, or with its longer side
    /// `longestSide` pixels, never above four times its size in points.
    ///
    /// **`box` and `longestSide` are for a PDF this app didn't make** (Ask Claude). A crop hides
    /// what is outside the crop box, but the media box still holds it, so drawn by the media box
    /// the words a crop hid would be read; the bitmap covers `box` alone. And a picture laid one
    /// pixel to a point makes a page of 14,400 points, which the floor turned into a bitmap of
    /// about 600 MB: `longestSide` drops the floor and caps the longer side there. Save as PDF
    /// reads only decks it drew, so its pages keep the media box and the floor.
    public static func bitmap(of page: CGPDFPage, box: CGPDFBox, longestSide: CGFloat?) -> CGImage? {
        // Within the media box, as viewers clip it: CoreGraphics gives a crop box as written, and
        // one that reaches past the media box would show what no viewer does.
        let media = page.getBoxRect(.mediaBox)
        let area = box == .mediaBox ? media : page.getBoxRect(box).intersection(media)
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        let scale = longestSide.map { min($0 / max(area.width, area.height), 4) }
            ?? min(max(readSize / max(area.width, area.height), 1), 4)
        let width = Int((area.width * scale).rounded()), height = Int((area.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
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
