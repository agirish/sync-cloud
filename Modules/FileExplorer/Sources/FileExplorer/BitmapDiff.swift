import CoreGraphics
import Foundation

/// A `CGImage` ferried across an actor hop.
///
/// `@unchecked` because `CGImage` carries no `Sendable` conformance, not because anything here is
/// unsound: a `CGImage` is immutable once created, and every one wrapped here is created inside the
/// render that produces it and handed on without being touched again.
///
/// **A `Data` round trip was the alternative and it was tried and removed** — encoding to PNG and
/// decoding on the far side moves the decompression to whoever unwraps it, which for a preview is
/// the main thread at draw time. The box is the shape `DuplicateThumbnail.RenderedThumbnail`
/// already uses for the same hop.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage

    init(_ cgImage: CGImage) { self.cgImage = cgImage }

    var width: Int { cgImage.width }
    var height: Int { cgImage.height }
}

/// What comparing two rasters found.
struct BitmapDiffResult: Equatable {
    /// Pixels that differ by more than the tolerance, as a fraction of the compared raster.
    let changedFraction: Double
    /// The bounding rects of the changed regions, in the compared raster's pixel coordinates —
    /// what the page strip's dots and the difference view's callouts are drawn from. Coarse by
    /// construction (see ``BitmapDiff/cellSide``): a per-pixel region list on a 1600px page is
    /// hundreds of thousands of rects, none of which is a thing anyone points at.
    let changedRects: [CGRect]
    /// True when the two images did not have the same pixel dimensions and one was rescaled to
    /// compare. **Disclosed rather than hidden**: a rescale resamples, so a "0.4% differ" from a
    /// mismatched pair is not the same claim as one from a matched pair, and a viewer that says
    /// nothing invites it to be read as one.
    let sizesDiffer: Bool

    var isIdentical: Bool { changedFraction == 0 }
}

/// Comparing two rendered pages, pixel by pixel.
///
/// **The repo's first bitmap comparison** — there is no Core Image anywhere in the tree, no
/// downsampler and no diff helper — so it is a plain buffer loop, and it is written around the two
/// traps the one existing raster pipeline (the OCR extractor) documents.
///
/// **`bytesPerRow` is read back, never assumed.** `CGContext(… bytesPerRow: 0 …)` asks CoreGraphics
/// to choose the stride, and it pads: a 1601-pixel-wide RGBA context is very unlikely to have a
/// 6404-byte row. A loop indexing `y * width * 4` walks diagonally off the image after the first
/// row and reports a page as almost entirely changed. Both images' own strides are read from the
/// data provider here, and they need not agree with each other.
///
/// **The comparison is on a redrawn RGBA raster, not on the source images' own buffers.** Two
/// pages can be the same picture in two colour spaces, two alpha layouts and two bit depths, and
/// nothing about "are these the same page" is answered by their storage. Redrawing both into one
/// known format costs two blits and removes every one of those variables.
enum BitmapDiff {

    /// How far apart two channel values may be before the pixel counts as changed.
    ///
    /// **Not zero, and the reason is anti-aliasing.** The same glyph rendered twice by the same
    /// rasteriser at the same scale can land a fraction of a pixel differently — a re-saved PDF
    /// re-embeds its fonts, and text edges then differ by a handful of levels everywhere while the
    /// page is, to a reader, identical. At 0 tolerance such a pair reports "everything changed",
    /// which is the same as reporting nothing. 12/255 clears typical edge jitter and is far below
    /// any real content change (black text arriving on white moves a channel by ~255).
    static let tolerance = 12

    /// The grid the changed rects are aggregated on, in pixels. Coarse deliberately: these drive a
    /// strip dot and a highlight, and a rect list at pixel resolution is neither pointable nor
    /// affordable.
    static let cellSide = 16

    /// Compares two rasters. Returns nil only when a raster could not be built at all (a zero-sized
    /// image, or a context CoreGraphics refused) — never as a stand-in for "no difference".
    static func compare(_ left: CGImage, _ right: CGImage) -> BitmapDiffResult? {
        let width = min(left.width, right.width)
        let height = min(left.height, right.height)
        guard width > 0, height > 0 else { return nil }
        let sizesDiffer = left.width != right.width || left.height != right.height
        guard let a = normalized(left, width: width, height: height),
              let b = normalized(right, width: width, height: height) else { return nil }

        let cells = max(1, (width + cellSide - 1) / cellSide)
        let rows = max(1, (height + cellSide - 1) / cellSide)
        var touched = [Bool](repeating: false, count: cells * rows)
        var changed = 0

        a.bytes.withUnsafeBufferPointer { pa in
            b.bytes.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    // The stride, per image, read back from the context that produced it.
                    let rowA = y * a.bytesPerRow
                    let rowB = y * b.bytesPerRow
                    for x in 0..<width {
                        let ia = rowA + x * 4
                        let ib = rowB + x * 4
                        // Three channels: the contexts are `noneSkipLast`, so byte 4 is padding
                        // and carries no colour. Comparing it would be comparing whatever
                        // CoreGraphics happened to leave there.
                        let d0 = abs(Int(pa[ia]) - Int(pb[ib]))
                        let d1 = abs(Int(pa[ia + 1]) - Int(pb[ib + 1]))
                        let d2 = abs(Int(pa[ia + 2]) - Int(pb[ib + 2]))
                        guard d0 > tolerance || d1 > tolerance || d2 > tolerance else { continue }
                        changed += 1
                        touched[(y / cellSide) * cells + (x / cellSide)] = true
                    }
                }
            }
        }

        var rects: [CGRect] = []
        for index in touched.indices where touched[index] {
            let cx = index % cells, cy = index / cells
            rects.append(CGRect(x: cx * cellSide, y: cy * cellSide,
                                width: min(cellSide, width - cx * cellSide),
                                height: min(cellSide, height - cy * cellSide)))
        }
        return BitmapDiffResult(changedFraction: Double(changed) / Double(width * height),
                                changedRects: rects, sizesDiffer: sizesDiffer)
    }

    /// The visual difference itself: the two rasters' per-channel distance, drawn as light on
    /// black, so a page that matches is black and a change glows.
    ///
    /// Same normalisation and the same stride discipline as `compare`. Returned as an image rather
    /// than painted into a view, so the mode that shows it and the mode that counts it are reading
    /// one computation.
    static func differenceImage(_ left: CGImage, _ right: CGImage) -> CGImage? {
        let width = min(left.width, right.width)
        let height = min(left.height, right.height)
        guard width > 0, height > 0,
              let a = normalized(left, width: width, height: height),
              let b = normalized(right, width: width, height: height),
              let out = context(width: width, height: height),
              let outData = out.data else { return nil }
        let outStride = out.bytesPerRow
        let outBytes = outData.bindMemory(to: UInt8.self, capacity: outStride * height)
        a.bytes.withUnsafeBufferPointer { pa in
            b.bytes.withUnsafeBufferPointer { pb in
                for y in 0..<height {
                    let rowA = y * a.bytesPerRow, rowB = y * b.bytesPerRow, rowO = y * outStride
                    for x in 0..<width {
                        let ia = rowA + x * 4, ib = rowB + x * 4, io = rowO + x * 4
                        for channel in 0..<3 {
                            outBytes[io + channel] =
                                UInt8(abs(Int(pa[ia + channel]) - Int(pb[ib + channel])))
                        }
                        outBytes[io + 3] = 255
                    }
                }
            }
        }
        return out.makeImage()
    }

    // MARK: Normalisation

    private struct Raster {
        let bytes: [UInt8]
        let bytesPerRow: Int
    }

    /// Redraws an image into a known RGBA raster of the given size, and reports the stride the
    /// context actually chose.
    private static func normalized(_ image: CGImage, width: Int, height: Int) -> Raster? {
        guard let ctx = context(width: width, height: height), let data = ctx.data else { return nil }
        // White ground, so a page with alpha (a transparent PNG, a PDF drawn without a fill)
        // compares as it looks on paper rather than against whatever the buffer was born holding.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        // Drawn into the full rect, which is what rescales a mismatched side — reported through
        // `sizesDiffer` rather than hidden.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let stride = ctx.bytesPerRow
        let buffer = data.bindMemory(to: UInt8.self, capacity: stride * height)
        return Raster(bytes: Array(UnsafeBufferPointer(start: buffer, count: stride * height)),
                      bytesPerRow: stride)
    }

    /// `bytesPerRow: 0` — CoreGraphics picks the stride, and every reader of the buffer reads it
    /// back rather than computing `width * 4`.
    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }
}
