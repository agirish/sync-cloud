import CoreGraphics
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
/// blocks for the whole deck: call it off the main actor.
enum PictureText {
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

    static func recognise(_ page: CGPDFPage) -> [Line] {
        guard let image = bitmap(of: page) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            // Said, because a Vision that fails reads exactly like slides with no words.
            Logger.shared.warning("Save as PDF: text recognition failed: \(error.localizedDescription)")
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first,
                  !best.string.allSatisfy(\.isWhitespace) else { return nil }
            return Line(text: best.string, box: observation.boundingBox)
        }
    }

    /// The page on white, its longer side ``readSize`` pixels — never below its own size in points,
    /// never above four times it.
    static func bitmap(of page: CGPDFPage) -> CGImage? {
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
