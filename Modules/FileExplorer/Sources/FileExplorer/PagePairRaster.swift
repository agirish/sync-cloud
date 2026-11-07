import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Sync

/// Rendering one page of one document to a bitmap, for the visual compare modes.
///
/// The PDFKit half takes the process-wide serial lane, for open and draw only. PDFKit parsing
/// isn't thread-safe (a second queue reading alongside made 4.5–6.3% of real documents extract
/// differently), so everything that opens a `PDFDocument` takes its turn. **Never do the pixel
/// work inside the lane**: the diff is plain arithmetic, and holding the lane across it would
/// stall a running scan's extractions behind the compare.
///
/// `perform`, never `run`, from async code: `run` is `queue.sync` and parks the calling thread,
/// which on the main actor is the whole window waiting behind a scan's parses.
enum PagePairRaster {

    /// The long edge a compare raster is rendered to: big enough for legible text in the difference
    /// mode, small enough that two rasters plus two normalised copies are tens of megabytes, not
    /// hundreds. Nothing here rasterises a whole document; it is one page at a time.
    static let compareLongEdge: CGFloat = 1600

    // **Don't add a smaller long edge for a cheap whole-document sweep.** A downsampled comparison
    // can prove two pages differ but not that they match: averaging takes a one-pixel mark below
    // the tolerance. A strip dot is a claim somebody checked, so `PageDifferenceStepper` searches
    // at `compareLongEdge` and bounds the cost by pages per press instead.

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
    /// The `CGImage` crosses back in the `SendableImage` box, not as `Data`: a PNG round trip moves
    /// the decompression to whoever unwraps it, for a preview the main thread at draw time.
    ///
    /// `nil` without opening the document when its task is cancelled before the lane comes free,
    /// so pages a reader paged past stay unrendered
    /// (``PDFKitSerialAccess/performUnlessCancelled(_:)``).
    static func render(path: String, page index: Int, longEdge: CGFloat) async -> SendableImage? {
        await PDFKitSerialAccess.performUnlessCancelled { () -> SendableImage? in
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
            // White ground: a PDF page has no background of its own, and the buffer's initial
            // contents would be compared as noise.
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.scaleBy(x: scale, y: scale)
            // Translated by the mediaBox origin, which a cropped or imposed page has away from
            // zero; without this the page draws offset, on one side only if the documents differ.
            ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            page.draw(with: .mediaBox, to: ctx)
            return ctx.makeImage().map(SendableImage.init)
        } ?? nil
    }

    /// Reads a raster image file (the `.image` pair kind) at a bounded size.
    ///
    /// Bounded through `CGImageSourceCreateThumbnailAtIndex`, which decodes at the size asked for.
    /// Decoding then scaling would cost ~400 MB for a 100-megapixel raw file before any scaling.
    ///
    /// Detached, off the main actor: this is file I/O and a decode.
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
