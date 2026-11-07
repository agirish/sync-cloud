import CoreGraphics
import Foundation

/// Where the difference view draws its callouts, and how many are worth drawing. `BitmapDiff`
/// computes the regions; this is only the geometry that puts them on screen. Pure, because the
/// mapping is the part that can be quietly wrong: an off-by-one in the aspect-fit arithmetic draws
/// boxes plausibly near the change rather than on it, which looks like a working feature.
enum ChangedRegionCallouts {

    /// The most regions worth outlining at once. Past this the outlines become a mesh: a page
    /// rewritten end to end isn't 47 things to step through but a different page, which the glow
    /// says better. Over the cap the count is still reported and nothing is drawn.
    ///
    /// A large count doesn't imply a heavily changed page once a de-skew is in play.
    /// ``BitmapDiff/warped(_:by:)`` resamples one side only, so a corrected pair carries faint,
    /// scattered residue along every anti-aliased edge that clears ``BitmapDiff/tolerance`` and
    /// fragments a few solid regions into speckle: two ruled pages a degree apart with one line
    /// rewritten give 214 regions aligned (22 unaligned), so nothing is outlined over a picture
    /// with one bright line. Left as it is on purpose: merging speckle would change what a region
    /// is, and with it the caption's count, ``PageDiffState``'s verdict and the page strip's dots.
    static let maxDrawn = 12

    /// The rect an image occupies inside `available` under `.aspectRatio(contentMode: .fit)`,
    /// centred: the frame SwiftUI gives the difference image, recomputed so the overlay lands on
    /// the same pixels. `.null` for a degenerate image or frame rather than dividing by zero: a
    /// raster can be nil-sized while a render is in flight, and the view mounts before layout.
    static func fittedRect(imageSize: CGSize, in available: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              available.width > 0, available.height > 0 else { return .null }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (available.width - size.width) / 2,
                      y: (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The regions to draw, mapped into `available`, or empty when there is nothing to draw.
    ///
    /// Both coordinate spaces are top-left origin, so there is no flip: a `CGBitmapContext`'s
    /// buffer starts at the image's top row, so the cells `BitmapDiff` walks are already y-down,
    /// like SwiftUI's. A flip would be a bug that looks correct on a symmetric page.
    static func drawable(regions: [CGRect], imageSize: CGSize, in available: CGSize) -> [CGRect] {
        guard !regions.isEmpty, regions.count <= maxDrawn else { return [] }
        let fitted = fittedRect(imageSize: imageSize, in: available)
        guard !fitted.isNull, imageSize.width > 0, imageSize.height > 0 else { return [] }
        let scale = fitted.width / imageSize.width
        return regions.map { region in
            CGRect(x: fitted.minX + region.minX * scale,
                   y: fitted.minY + region.minY * scale,
                   width: region.width * scale,
                   height: region.height * scale)
        }
    }

    /// What the mode bar says about the regions, or nil while there is nothing to say.
    ///
    /// Silent until the comparison has run, like the page strip's dots: a count over a pending
    /// render would describe the previous page. nil for a page with no changes too: "0 regions
    /// differ" beside a black canvas only restates the picture.
    static func caption(regionCount: Int) -> String? {
        switch regionCount {
        case 0: return nil
        case 1: return "1 region differs"
        case 2...maxDrawn: return "\(regionCount) regions differ"
        // Over the cap: the count is still the honest finding, and the missing outlines are
        // disclosed so the reader isn't left wondering where the boxes went.
        default: return "\(regionCount) regions differ — too many to outline"
        }
    }
}
