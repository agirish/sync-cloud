import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Sync

/// Rendering one page of one document to a bitmap, for the visual compare modes.
///
/// **The PDFKit half takes the process-wide serial lane, and holds it for open + draw only.** That
/// is the shape the OCR extractor already uses and the reason it uses it: PDFKit's parsing is not
/// thread-safe (measured — a second serial queue reading PDFs alongside the first made 4.5–6.3% of
/// 176 real documents extract differently), and everything that opens a `PDFDocument` takes its
/// turn. What must NOT happen inside the lane is the pixel work: the diff is arithmetic over two
/// buffers, it is not PDFKit, and holding the lane across it would stall a running scan's
/// extractions behind a compare the user is looking at.
///
/// `perform`, never `run`, from async code: `run` is `queue.sync` and parks the calling thread —
/// from the main actor that is the whole window waiting behind a scan's parses.
enum PagePairRaster {

    /// The long edge a compare raster is rendered to. Big enough that a page's text is legible
    /// under the difference mode, small enough that two of them plus two normalised copies is a
    /// few tens of megabytes rather than hundreds. A 300-page document costs one page at a time —
    /// nothing here ever rasterises a whole document.
    static let compareLongEdge: CGFloat = 1600

    // There was a second, much smaller long edge here — 72px, "for a page-strip dot's diff, which
    // only has to answer did anything change" — for a cheap sweep of a whole document that was
    // never built. It is deliberately gone rather than left waiting for a caller.
    //
    // **A downsampled comparison can prove that two pages DIFFER; it cannot prove they are the
    // same.** Averaging takes a one-pixel mark below the tolerance, so a 72px pass reporting
    // nothing is inconclusive, not a verdict. The strip's whole rule is that a dot is a claim
    // somebody checked — which is why a pending page gets no dot at all — so filling it from a
    // resolution that can miss is the one thing it must not do. `PageDifferenceStepper` searches
    // at `compareLongEdge` instead, and bounds the cost by how many pages one press will render.

    /// How many pages a document has, or nil when it cannot be opened.
    ///
    /// Async and off the main actor, because it opens the document: the lane may be busy behind a
    /// scan, and the facts strip renders "…" until this answers rather than blocking on it.
    static func pageCount(path: String) async -> Int? {
        await PDFKitSerialAccess.perform {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked else {
                return nil
            }
            return doc.pageCount
        }
    }

    /// Renders one page (0-based) at the given long edge.
    ///
    /// The `CGImage` crosses back in the `SendableImage` box rather than as `Data` — a PNG round
    /// trip moves the decompression to whoever unwraps it, which for a preview is the main thread
    /// at draw time.
    static func render(path: String, page index: Int, longEdge: CGFloat) async -> SendableImage? {
        await PDFKitSerialAccess.perform {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked,
                  index >= 0, index < doc.pageCount, let page = doc.page(at: index) else {
                return nil
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            let scale = longEdge / max(bounds.width, bounds.height)
            let size = CGSize(width: (bounds.width * scale).rounded(),
                              height: (bounds.height * scale).rounded())
            guard size.width >= 1, size.height >= 1,
                  let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            // White ground: a PDF page has no background of its own, and comparing two pages
            // against whatever the buffer was born holding is comparing noise.
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            // Translated by the mediaBox origin, which is not always zero — a cropped or imposed
            // page has a non-zero origin, and drawing it without this renders it offset by however
            // far its box is from the origin, on one side only if the two documents differ.
            ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: ctx)
            return ctx.makeImage().map(SendableImage.init)
        }
    }

    /// Reads a raster image file (the `.image` pair kind) at a bounded size.
    ///
    /// **Bounded through `CGImageSourceCreateThumbnailAtIndex`, not by decoding and scaling.** A
    /// 100-megapixel raw file decodes to ~400 MB before any scaling happens, and two of them plus
    /// two normalised copies is a gigabyte for a diff nobody asked to be exact. ImageIO's
    /// thumbnail path decodes at the size asked for.
    ///
    /// `nonisolated`, off the main actor: this is file I/O and a decode.
    static func renderImage(path: String, longEdge: CGFloat) async -> SendableImage? {
        await Task.detached(priority: .userInitiated) { () -> SendableImage? in
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(longEdge),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                .map(SendableImage.init)
        }.value
    }

    /// One side's raster for a pair, whichever kind it is. nil for a kind with no raster.
    static func render(path: String, kind: PairContentKind, page: Int,
                       longEdge: CGFloat) async -> SendableImage? {
        switch kind {
        case .pdf: return await render(path: path, page: page, longEdge: longEdge)
        case .image: return await renderImage(path: path, longEdge: longEdge)
        case .text, .other: return nil
        }
    }
}
