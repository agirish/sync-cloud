import CoreGraphics
import Foundation

/// A `CGImage` ferried across an actor hop. `@unchecked` because `CGImage` has no `Sendable`
/// conformance, not because anything is unsound: a `CGImage` is immutable, and each one wrapped
/// here is created by the render that produces it and never touched again. Not a PNG `Data` round
/// trip, which would move decompression to whoever unwraps it: the main thread at draw time. The
/// same box `DuplicateThumbnail.RenderedThumbnail` uses for the same hop.
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
    /// One bounding rect per changed region, in the compared raster's pixel coordinates: what the
    /// difference view's callouts are drawn from, and what "3 regions differ" counts.
    ///
    /// Regions, not cells. The comparison marks 16-pixel cells (``BitmapDiff/cellSide``), but one
    /// edited sentence lights eight adjacent cells, and "8 regions differ" about one edit is wrong.
    /// Touching cells, diagonals included, merge into connected components, and each component's
    /// bounding box is one region.
    let changedRects: [CGRect]
    /// True when the two images had different pixel dimensions and one was rescaled to compare.
    /// Disclosed, because a rescale resamples, so "0.4% differ" from a mismatched pair isn't the
    /// same claim as from a matched pair.
    let sizesDiffer: Bool
    /// The alignment applied before comparing, or nil where none was (``PageRegistration``).
    /// Disclosed for `sizesDiffer`'s reason, and more so: a reader told two scans line up when the
    /// app quietly rotated one has been told something false about their documents. Nil covers
    /// both "not attempted" and "attempted and refused", which read the same on screen: the pages
    /// were compared as they are.
    var registration: PageRegistration? = nil

    var isIdentical: Bool { changedFraction == 0 }
}

/// Comparing two rendered pages, pixel by pixel: a plain buffer loop, written around two traps.
///
/// `bytesPerRow` is read back, never assumed. `CGContext(… bytesPerRow: 0 …)` lets CoreGraphics
/// choose the stride, and it pads: a 1601-pixel-wide RGBA context is unlikely to have a 6404-byte
/// row, and a loop indexing `y * width * 4` walks diagonally off the image and reports a page as
/// almost entirely changed. Each image's stride is read separately; they need not agree.
///
/// The comparison is on a redrawn RGBA raster, not the source images' own buffers. Two pages can
/// be the same picture in two colour spaces, alpha layouts and bit depths; redrawing both into one
/// known format costs two blits and removes those variables.
enum BitmapDiff {

    /// How far apart two channel values may be before the pixel counts as changed.
    ///
    /// Not zero, because of anti-aliasing: the same glyph rendered twice can land a fraction of a
    /// pixel differently (a re-saved PDF re-embeds its fonts), so text edges differ by a few levels
    /// everywhere on a page a reader sees as identical. At 0 such a pair reports "everything
    /// changed". 12/255 clears typical edge jitter and is far below real content change (black
    /// text on white moves a channel by ~255).
    static let tolerance = 12

    /// The grid the changed rects are aggregated on, in pixels. Coarse on purpose: these drive a
    /// strip dot and a highlight, and a rect list at pixel resolution is neither pointable nor
    /// affordable.
    static let cellSide = 16

    /// Compares two rasters. Returns nil only when a raster could not be built at all (a zero-sized
    /// image, or a context CoreGraphics refused), never as a stand-in for "no difference".
    static func compare(_ left: CGImage, _ right: CGImage) -> BitmapDiffResult? {
        analyse(left, right, wantsDifferenceImage: false).result
    }

    /// What comparing two pages found, and, only when asked, the picture of it. One pass, because
    /// the two answers are one arithmetic: separate walks would normalise each page twice over for
    /// one set of numbers. The image is optional because it is a third full-page raster (~13 MB at
    /// 1600×2070) that the swipe and onion modes never draw.
    static func analyse(_ left: CGImage, _ right: CGImage,
                        wantsDifferenceImage: Bool) -> (result: BitmapDiffResult?,
                                                        difference: CGImage?) {
        let width = min(left.width, right.width)
        let height = min(left.height, right.height)
        guard width > 0, height > 0 else { return (nil, nil) }
        let sizesDiffer = left.width != right.width || left.height != right.height
        guard let a = normalized(left, width: width, height: height),
              let b = normalized(right, width: width, height: height) else { return (nil, nil) }

        let cells = max(1, (width + cellSide - 1) / cellSide)
        let rows = max(1, (height + cellSide - 1) / cellSide)
        var touched = [Bool](repeating: false, count: cells * rows)
        var changed = 0

        // Nil unless a caller asked for the picture: the context is the third full-page allocation.
        let out = wantsDifferenceImage ? context(width: width, height: height) : nil
        let outBytes = out?.data?.bindMemory(to: UInt8.self,
                                             capacity: (out?.bytesPerRow ?? 0) * height)
        let outStride = out?.bytesPerRow ?? 0

        let pa = a.pixels, pb = b.pixels
        for y in 0..<height {
            // The stride, per image, read back from the context that produced it.
            let rowA = y * a.bytesPerRow
            let rowB = y * b.bytesPerRow
            let rowO = y * outStride
            for x in 0..<width {
                let ia = rowA + x * 4
                let ib = rowB + x * 4
                // Three channels: the contexts are `noneSkipLast`, so byte 4 is padding and holds
                // whatever CoreGraphics left there.
                let d0 = abs(Int(pa[ia]) - Int(pb[ib]))
                let d1 = abs(Int(pa[ia + 1]) - Int(pb[ib + 1]))
                let d2 = abs(Int(pa[ia + 2]) - Int(pb[ib + 2]))
                if let outBytes {
                    // The distance drawn as light on black, so a page that matches is black and a
                    // change glows.
                    let io = rowO + x * 4
                    outBytes[io] = UInt8(d0)
                    outBytes[io + 1] = UInt8(d1)
                    outBytes[io + 2] = UInt8(d2)
                    outBytes[io + 3] = 255
                }
                guard d0 > tolerance || d1 > tolerance || d2 > tolerance else { continue }
                changed += 1
                touched[(y / cellSide) * cells + (x / cellSide)] = true
            }
        }

        let rects = regions(touched: touched, cells: cells, rows: rows,
                            width: width, height: height)
        let result = BitmapDiffResult(changedFraction: Double(changed) / Double(width * height),
                                      changedRects: rects, sizesDiffer: sizesDiffer)
        return (result, outBytes == nil ? nil : out?.makeImage())
    }

    /// Merges the touched cell grid into one bounding box per connected component.
    ///
    /// Eight-connectivity, not four: a line of text lights a ragged edge of cells, and a diagonal
    /// step between two is the same edit, so four would split one changed paragraph into several
    /// regions. An explicit stack, not recursion: a page changed everywhere is one component
    /// covering every cell, 12,500 deep on a 1600×2000 raster. Sorted top to bottom, then left to
    /// right, so the callouts a reader steps through are in reading order.
    static func regions(touched: [Bool], cells: Int, rows: Int,
                        width: Int, height: Int) -> [CGRect] {
        guard cells > 0, rows > 0 else { return [] }
        var seen = [Bool](repeating: false, count: touched.count)
        var rects: [CGRect] = []
        var stack: [Int] = []
        for start in touched.indices where touched[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            while let index = stack.popLast() {
                let cx = index % cells, cy = index / cells
                minX = min(minX, cx); maxX = max(maxX, cx)
                minY = min(minY, cy); maxY = max(maxY, cy)
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < cells, ny >= 0, ny < rows else { continue }
                        let neighbour = ny * cells + nx
                        guard touched[neighbour], !seen[neighbour] else { continue }
                        seen[neighbour] = true
                        stack.append(neighbour)
                    }
                }
            }
            // Clamped to the compared area: the trailing cell of a row or column is partial
            // wherever the raster isn't a multiple of `cellSide`, and a rect past the page would
            // draw a callout over nothing.
            let x = minX * cellSide, y = minY * cellSide
            rects.append(CGRect(x: x, y: y,
                                width: min((maxX + 1) * cellSide, width) - x,
                                height: min((maxY + 1) * cellSide, height) - y))
        }
        return rects.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// The visual difference itself: the two rasters' per-channel distance, drawn as light on
    /// black, so a page that matches is black and a change glows.
    ///
    /// The picture half of ``analyse(_:_:wantsDifferenceImage:)``, so the mode that shows it and
    /// the mode that counts it read one computation.
    static func differenceImage(_ left: CGImage, _ right: CGImage) -> CGImage? {
        analyse(left, right, wantsDifferenceImage: true).difference
    }

    // MARK: Normalisation

    /// A page redrawn into a known RGBA raster. The context is held and the pixels read through it
    /// rather than copied out (a copy is ~13 MB a side at 1600×2070); the context owns that memory
    /// for as long as this value is alive, which covers every walk here.
    private struct Raster {
        /// Held so `pixels` stays valid: the buffer belongs to the context.
        let context: CGContext
        let pixels: UnsafeMutablePointer<UInt8>
        let bytesPerRow: Int
    }

    /// Redraws an image into a known RGBA raster of the given size, and reports the stride the
    /// context actually chose.
    private static func normalized(_ image: CGImage, width: Int, height: Int) -> Raster? {
        guard let ctx = context(width: width, height: height), let data = ctx.data else { return nil }
        // White ground, so a page with alpha (a transparent PNG, a PDF drawn without a fill)
        // compares as it looks on paper, not against whatever the buffer was born holding.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        // Drawn into the full rect, which rescales a mismatched side; reported through
        // `sizesDiffer`, not hidden.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let stride = ctx.bytesPerRow
        return Raster(context: ctx,
                      pixels: data.bindMemory(to: UInt8.self, capacity: stride * height),
                      bytesPerRow: stride)
    }

    /// One image as the coarse luminance grid ``PageRegistrationEstimator`` searches over.
    ///
    /// Drawn through the comparison's white-ground normalisation, so a page with alpha registers as
    /// it looks on paper, and the estimator and the diff can't disagree about what the page is.
    static func grid(_ image: CGImage, width: Int) -> PageRegistrationEstimator.Grid? {
        guard image.width > 0, image.height > 0, width > 0 else { return nil }
        let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        guard let raster = normalized(image, width: width, height: height) else { return nil }
        var samples = [Double](repeating: 1, count: width * height)
        for y in 0..<height {
            let row = y * raster.bytesPerRow
            for x in 0..<width {
                let i = row + x * 4
                // Rec. 601 luma. The estimator correlates structure, not colour, and one channel is
                // a quarter of the work; the sweep is the expensive stage.
                let l = 0.299 * Double(raster.pixels[i]) + 0.587 * Double(raster.pixels[i + 1])
                      + 0.114 * Double(raster.pixels[i + 2])
                samples[y * width + x] = l / 255
            }
        }
        return PageRegistrationEstimator.Grid(width: width, height: height, samples: samples)
    }

    /// `image` rotated and shifted by `registration`, in its own pixel coordinates.
    ///
    /// The rotation is about the image centre, matching the estimator's convention. The ground is
    /// white for `normalized`'s reason: the corners a rotation exposes are paper, and black corners
    /// would be reported as a difference the size of the skew.
    static func warped(_ image: CGImage, by registration: PageRegistration) -> CGImage? {
        let width = image.width, height = image.height
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.translateBy(x: CGFloat(registration.dx), y: CGFloat(-registration.dy))
        ctx.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        ctx.rotate(by: CGFloat(-registration.degrees * .pi / 180))
        ctx.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// ``compare(_:_:)`` with a best-effort de-skew first, and the difference raster where a mode
    /// will draw it.
    ///
    /// The alignment is attempted, judged, then applied or dropped. A transform the estimator isn't
    /// confident about is discarded and the pages are compared as they are, which is most pairs.
    /// The result says which happened; nothing downstream may assume alignment because it was
    /// tried.
    ///
    /// The picture is of the same pair the comparison read (the aligned one, where an alignment was
    /// applied), so the callouts and the glow come from one image pair, the de-skew is visible in
    /// difference mode, and one walk serves both: ~25 MB less transient allocation at 1600×2070
    /// and about 40% off the diff work.
    ///
    /// It doesn't buy a clean page. ``warped`` resamples only the right page, so every
    /// anti-aliased edge moves past ``tolerance`` however good the geometry: on one measured pair
    /// whose true answer is 0.78% and one region, a perfect alignment still reports 3.42% and
    /// eight. The callouts still box every paragraph on a skewed pair, and no sharpening of the
    /// estimator will change that; ``PageRegistration/caption`` says "best effort" partly for this.
    /// Sparse horizontal rules fragment into far more regions once aligned, past
    /// ``ChangedRegionCallouts/maxDrawn``, so nothing is outlined there (see that note).
    static func compareAligning(_ left: CGImage, _ right: CGImage,
                                wantsDifferenceImage: Bool) -> (result: BitmapDiffResult?,
                                                                difference: CGImage?) {
        guard let a = grid(left, width: PageRegistrationEstimator.gridWidth),
              let b = grid(right, width: PageRegistrationEstimator.gridWidth),
              a.width == b.width, a.height == b.height else {
            return analyse(left, right, wantsDifferenceImage: wantsDifferenceImage)
        }
        let scale = Double(right.width) / Double(a.width)
        let registration = PageRegistrationEstimator.estimate(a, b, scale: scale)
        guard registration.isUsable, let aligned = warped(right, by: registration) else {
            return analyse(left, right, wantsDifferenceImage: wantsDifferenceImage)
        }
        // One walk over the aligned pair, and the picture comes out of it.
        let outcome = analyse(left, aligned, wantsDifferenceImage: wantsDifferenceImage)
        guard var result = outcome.result else {
            return analyse(left, right, wantsDifferenceImage: wantsDifferenceImage)
        }
        result.registration = registration
        return (result, outcome.difference)
    }

    /// `bytesPerRow: 0`: CoreGraphics picks the stride, and every reader of the buffer reads it
    /// back rather than computing `width * 4`.
    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }
}
