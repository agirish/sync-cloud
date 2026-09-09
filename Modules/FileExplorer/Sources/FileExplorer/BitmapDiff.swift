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
    /// One bounding rect per changed REGION, in the compared raster's pixel coordinates — what the
    /// difference view's callouts are drawn from, and what "3 regions differ" counts.
    ///
    /// **Regions, not cells, and the difference is the whole point of the field.** The comparison
    /// marks 16-pixel cells (see ``BitmapDiff/cellSide``) because a per-pixel list on a 1600px page
    /// is hundreds of thousands of rects, none of which is a thing anyone points at. But a cell is
    /// not pointable either: one edited sentence lights eight adjacent cells, and "8 regions
    /// differ" about one edit is a worse answer than "something differs". Touching cells are merged
    /// into connected components — diagonally too, since a line of text lights a ragged edge — and
    /// each component's bounding box is one region.
    let changedRects: [CGRect]
    /// True when the two images did not have the same pixel dimensions and one was rescaled to
    /// compare. **Disclosed rather than hidden**: a rescale resamples, so a "0.4% differ" from a
    /// mismatched pair is not the same claim as one from a matched pair, and a viewer that says
    /// nothing invites it to be read as one.
    let sizesDiffer: Bool
    /// The alignment applied before comparing, or nil where none was — see ``PageRegistration``.
    ///
    /// **Disclosed for `sizesDiffer`'s reason, and more urgently.** A rescale changes what "0.4%
    /// differ" means; a de-skew changes it further, and a reader told two scans line up when the
    /// app quietly rotated one of them has been told something false about their documents. Nil
    /// covers both "not attempted" and "attempted and refused", which read the same on screen: the
    /// pages were compared as they are.
    var registration: PageRegistration? = nil

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
        analyse(left, right, wantsDifferenceImage: false).result
    }

    /// What comparing two pages found, and — only when asked — the picture of it.
    ///
    /// **One pass, because the two answers are one arithmetic.** `compare` and `differenceImage`
    /// were separate entry points, and the difference view calls both: each redrew BOTH pages into
    /// its own normalised raster and walked them, so a page shown in the difference mode was
    /// normalised four times and walked twice for one set of numbers. Measured at 1600×2070: 9.1 ms
    /// for the comparison and 11.7 ms for the image separately, against 9.9 ms for both together —
    /// and ~53 MB less transient allocation, with the raster copies gone (see ``Raster``).
    ///
    /// The image is optional rather than always produced for the same reason it is worth fusing:
    /// it is a third full-page raster (~13 MB at this size) that the swipe and onion modes never
    /// draw.
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
                // Three channels: the contexts are `noneSkipLast`, so byte 4 is padding
                // and carries no colour. Comparing it would be comparing whatever
                // CoreGraphics happened to leave there.
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
    /// **Eight-connectivity, not four.** A line of text lights a ragged edge of cells, and a
    /// diagonal step between two of them is the same edit — four-connectivity would split one
    /// changed paragraph into a handful of "regions" and report the count as the finding.
    ///
    /// An explicit stack rather than recursion: a page that changed everywhere is one component
    /// covering every cell, which on a 1600×2000 raster is 12,500 deep.
    ///
    /// Sorted top-to-bottom then left-to-right, so the callouts a reader steps through are in
    /// reading order rather than in whatever order the scan happened to reach them.
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
            // Clamped to the compared area: the trailing cell of a row or column is a partial one
            // wherever the raster is not a multiple of `cellSide`, and a rect running past the
            // page would draw a callout over nothing.
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
    /// The picture half of ``analyse(_:_:wantsDifferenceImage:)`` — one entry point, so the mode
    /// that shows it and the mode that counts it are reading one computation.
    static func differenceImage(_ left: CGImage, _ right: CGImage) -> CGImage? {
        analyse(left, right, wantsDifferenceImage: true).difference
    }

    // MARK: Normalisation

    /// A page redrawn into a known RGBA raster.
    ///
    /// **The context is held, and the pixels are read through it rather than copied out.** Both
    /// readers used to take `Array(UnsafeBufferPointer(...))` of the whole buffer — ~13 MB a side
    /// at 1600×2070, four of them for one page in the difference mode — purely to get a `[UInt8]`
    /// to index. The context owns that memory for as long as this value is alive, which is the
    /// whole of every walk here.
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
        // compares as it looks on paper rather than against whatever the buffer was born holding.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        // Drawn into the full rect, which is what rescales a mismatched side — reported through
        // `sizesDiffer` rather than hidden.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let stride = ctx.bytesPerRow
        return Raster(context: ctx,
                      pixels: data.bindMemory(to: UInt8.self, capacity: stride * height),
                      bytesPerRow: stride)
    }

    /// One image as the coarse luminance grid ``PageRegistrationEstimator`` searches over.
    ///
    /// Drawn through the same white-ground normalisation the comparison uses, so a page with alpha
    /// is registered as it looks on paper — and so the estimator and the diff cannot disagree about
    /// what the page IS.
    static func grid(_ image: CGImage, width: Int) -> PageRegistrationEstimator.Grid? {
        guard image.width > 0, image.height > 0, width > 0 else { return nil }
        let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        guard let raster = normalized(image, width: width, height: height) else { return nil }
        var samples = [Double](repeating: 1, count: width * height)
        for y in 0..<height {
            let row = y * raster.bytesPerRow
            for x in 0..<width {
                let i = row + x * 4
                // Rec. 601 luma. The estimator correlates structure, not colour, and a single
                // channel is a quarter of the work — the sweep is the expensive stage.
                let l = 0.299 * Double(raster.pixels[i]) + 0.587 * Double(raster.pixels[i + 1])
                      + 0.114 * Double(raster.pixels[i + 2])
                samples[y * width + x] = l / 255
            }
        }
        return PageRegistrationEstimator.Grid(width: width, height: height, samples: samples)
    }

    /// `image` rotated and shifted by `registration`, in its own pixel coordinates.
    ///
    /// The rotation is about the image centre, matching the estimator's own convention, and the
    /// ground is white for `normalized`'s reason: the corners a rotation exposes are paper, not
    /// whatever the buffer was born holding, and black corners would be reported as a difference
    /// the size of the skew.
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

    /// ``compare(_:_:)`` with a best-effort de-skew first — CC14.4.
    ///
    /// **The alignment is attempted, then judged, then either applied or dropped.** A transform the
    /// estimator is not confident about is discarded and the pages are compared as they are, which
    /// is exactly what this did before the feature existed. The result says which happened; nothing
    /// downstream may assume alignment from the fact that it was tried.
    static func compareAligning(_ left: CGImage, _ right: CGImage) -> BitmapDiffResult? {
        compareAligning(left, right, wantsDifferenceImage: false).result
    }

    /// The same, plus the difference raster where a mode is going to draw it.
    ///
    /// **The picture is of the same pair the comparison read — the aligned one, where an alignment
    /// was applied.** It used to be drawn from the pages as they are, which left the callouts and
    /// the glow computed from two different image pairs. This is the settling the old comment here
    /// asked for, and it went this way for two reasons, neither of them the one it expected.
    ///
    /// **It is cheaper, not dearer.** The old shape walked `analyse` twice — once over the aligned
    /// pair for the numbers, once over the unaligned pair for the picture. `aligned` is already in
    /// hand, so asking the first walk for the picture removes a second walk and the two normalised
    /// full-page rasters it needed: **~25 MB** less transient allocation at 1600x2070, and a little
    /// over **40% off the diff work**.
    ///
    /// **The proportion is the claim; the milliseconds are one machine's reading.** Measured at
    /// 1600x2070 on an Apple M4 in Release, best of 20, machine quiet: 10.4 ms against 18.7 ms. The
    /// same comparison on the same build with the machine busy reads 14.3 against 26.3 — the
    /// absolutes move by 40% with whatever else is running, while the saving holds at 42-46% across
    /// every reading. That is why the ratio is what is written down and the timings are labelled.
    ///
    /// **The disagreement it was meant to settle was never the visible half — on the pairs where
    /// outlines are drawn at all.** Measured over 0.25-2 degrees of skew on two page fixtures, a
    /// dense text page and a sparse one, counting only the pairs whose region count stays under
    /// ``ChangedRegionCallouts/maxDrawn``: **95.7-99.5%** of the old picture's glow already fell
    /// inside the outlines drawn over it (95.7% at 2 degrees, 99.5% at 0.25), and at half a degree
    /// on the dense page the aligned and unaligned region lists were the same eight boxes to within
    /// one cell.
    ///
    /// **The qualifier is load-bearing, so do not quote the range without it.** A page of sparse
    /// horizontal rules behaves nothing like that: aligning it fragments a solid glow into
    /// speckle, 22 regions before against 224 after on one measured pair, and coverage falls to
    /// 74.9-81.1%. Both counts are far over ``ChangedRegionCallouts/maxDrawn``, so NOTHING is
    /// outlined and the reader sees no disagreement there either — but for the opposite reason.
    ///
    /// What the change actually buys is that the de-skew becomes VISIBLE — the old shape let an
    /// alignment move the region list and write the caption while leaving the picture, which is the
    /// thing a reader in the difference mode is looking at, exactly as it was.
    ///
    /// **What it does not buy is a clean page, and the reason is worth knowing before anyone
    /// tightens the estimator to chase one.** ``warped`` resamples the right page and leaves the
    /// left alone, so every anti-aliased edge moves past ``tolerance`` however good the geometry is.
    /// On that same pair the true answer is 0.78% changed and ONE region; a *perfect* alignment
    /// still reports 3.42% and eight, of which 2.87 points is that one-sided resample — put both
    /// sides through the same resample and it falls to 0.94% and one region. So the callouts still
    /// box every paragraph on a skewed pair, and no sharpening of the search will change that.
    /// ``PageRegistration/caption`` says "best effort" partly for this.
    ///
    /// Where no alignment is applied — every pair the estimator is not confident about, which is
    /// most of them — the comparison and the picture are of the same two pages, as they always
    /// were, and then it really is one pass.
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
        // One walk over the aligned pair, and the picture comes out of it — see the doc comment.
        let outcome = analyse(left, aligned, wantsDifferenceImage: wantsDifferenceImage)
        guard var result = outcome.result else {
            return analyse(left, right, wantsDifferenceImage: wantsDifferenceImage)
        }
        result.registration = registration
        return (result, outcome.difference)
    }

    /// `bytesPerRow: 0` — CoreGraphics picks the stride, and every reader of the buffer reads it
    /// back rather than computing `width * 4`.
    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }
}
