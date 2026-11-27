import CoreGraphics
import Events
import Foundation
import PDFToolkitCore

/// The words in a deck's slide pictures, read by Vision and laid invisibly over each page, so a
/// deck whose slides are pictures can still be searched and selected.
///
/// Each page is drawn to a bitmap and read by pdf-toolkit's `recognizeTextLines`, then drawn again
/// into a new PDF with each recognised line over it by pdf-toolkit's `drawInvisibleTextLine`: in
/// invisible text (render mode 3) at the line's box, stretched to the box's width. The page looks as
/// it did. pdf-toolkit's own `ocrData` is built from the same two pieces, but opens the PDF with
/// PDFKit and reads inside that section; this loop is CoreGraphics, so Vision stays off
/// `PDFKitSerialAccess`'s lane, as that lane's rule asks.
///
/// About 0.1–0.2 s a slide at 1920 px once Vision's model is loaded. Titles, sentences and table
/// figures read well; logos and small print in screenshots don't, hence the banner's "may have
/// mistakes". `.fast` drops many lines on tables.
///
/// It blocks for the whole deck: call it off the main actor. Ask Claude's `read_text` and Filing
/// read scanned pages with ``text(in:reader:)``.
public enum PictureText {
    /// The bitmap Vision reads, by its longer side.
    public static let readSize: CGFloat = 1920

    /// What Save as PDF reads in: Vision's default English, the language its decks were read in
    /// before the read moved to pdf-toolkit, which detects the language when given none.
    static let saveAsPDFLanguages = ["en-US"]

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

    /// The page's lines, read on Vision's choice of processor and, **when that fails, again on the
    /// CPU** (pdf-toolkit's retry: the Neural Engine can refuse every request for hours while macOS
    /// recompiles its models). `read` is injectable so a test can be the refusal.
    static func recognise(_ page: CGPDFPage,
                          read: ((CGImage, OCRProcessor) throws -> [RecognizedTextLine])? = nil) -> [RecognizedTextLine] {
        guard let image = bitmap(of: page) else { return [] }
        let read = read ?? { try PDFToolkit.recognizeTextLines(in: $0, languages: saveAsPDFLanguages, on: $1) }
        return (try? lines(in: image, reader: "Save as PDF", read: read)) ?? []
    }

    /// `image`'s lines, or the CPU's error when Vision fails on both processors; each failure said,
    /// because a Vision that fails reads exactly like slides with no words.
    private static func lines(in image: CGImage, reader: String,
                              read: (CGImage, OCRProcessor) throws -> [RecognizedTextLine]) throws -> [RecognizedTextLine] {
        do {
            return try PDFToolkit.recognizeTextLines(in: image, onRetry: { error in
                Logger.shared.warning("\(reader): text recognition failed: \(error.localizedDescription); reading on the CPU")
            }, read: read)
        } catch {
            Logger.shared.warning("\(reader): text recognition failed on the CPU too: \(error.localizedDescription)")
            throw error
        }
    }

    /// The words Vision reads in `image`, a line each in Vision's order; nil when Vision fails on
    /// both processors, so a failure isn't taken for a blank page. For a caller that draws the page
    /// itself, as Ask Claude does on the PDFKit lane.
    ///
    /// The language is detected, where Save as PDF reads English only: without it a Chinese,
    /// Japanese or Hindi scan reads as nothing, and English reads the same either way. Vision's
    /// languages are its own list (33 on macOS 27, including CJK, Russian, Arabic, Thai and Hindi,
    /// but not Greek, Hebrew, Bengali or Tamil).
    public static func text(in image: CGImage, reader: String) -> String? {
        let found = try? lines(in: image, reader: reader) { try PDFToolkit.recognizeTextLines(in: $0, on: $1) }
        return found.map { $0.map(\.text).joined(separator: "\n") }
    }

    /// The page on white, its longer side ``readSize`` pixels — never below its own size in points,
    /// never above four times it.
    public static func bitmap(of page: CGPDFPage) -> CGImage? {
        bitmap(of: page, box: .mediaBox, longestSide: nil)
    }

    /// The page's `box` on white, as ``bitmap(of:)`` draws the media box, or with its longer side
    /// `longestSide` pixels, never above four times its size in points.
    ///
    /// `box` and `longestSide` are for a PDF this app didn't make (Ask Claude). Drawn by the media
    /// box, words a crop hid would be read, so the bitmap covers `box` alone. And a picture laid
    /// one pixel to a point can make a page of 14,400 points, which the floor would turn into a
    /// ~600 MB bitmap, so `longestSide` drops the floor and caps the longer side. Save as PDF reads
    /// only decks it drew, so it keeps the media box and the floor.
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

    /// Each line over its box, turned from a fraction of the page to points, by pdf-toolkit's
    /// `drawInvisibleTextLine`: invisible Helvetica, its height the box's, stretched to its width.
    /// Helvetica, not the toolkit's default system font, because PDFKit highlights a line at its
    /// font's natural width, and Helvetica's is close to the Arial and Helvetica slides print in.
    static func draw(_ lines: [RecognizedTextLine], in context: CGContext, paper: CGSize) {
        for line in lines {
            let box = CGRect(x: line.box.minX * paper.width, y: line.box.minY * paper.height,
                             width: line.box.width * paper.width, height: line.box.height * paper.height)
            PDFToolkit.drawInvisibleTextLine(line.text, in: box, fontName: "Helvetica", context: context)
        }
    }
}
