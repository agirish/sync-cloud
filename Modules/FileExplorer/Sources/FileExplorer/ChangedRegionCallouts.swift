import CoreGraphics
import Foundation

/// Where the difference view draws its callouts, and how many are worth drawing.
///
/// **`BitmapDiff` already computes the regions; this is only the geometry that puts them on
/// screen.** They were computed, tested and drawn nowhere — the field's own doc promised "the
/// difference view's callouts" while nothing consumed it.
///
/// Pure, because the mapping is the part that can be quietly wrong: an off-by-one in the aspect-fit
/// arithmetic draws boxes that are plausibly near the change rather than on it, which looks like a
/// working feature.
enum ChangedRegionCallouts {

    /// The most regions worth outlining at once.
    ///
    /// **Past this the outlines stop being callouts and become a mesh.** A page rewritten end to
    /// end is not "47 things changed" that a reader steps through; it is a different page, which
    /// the glow already says better than 47 rectangles would. Over the cap the count is still
    /// reported — the reader is told what was found — and nothing is drawn.
    static let maxDrawn = 12

    /// The rect an image occupies inside `available` under `.aspectRatio(contentMode: .fit)`,
    /// centred — the frame SwiftUI gives the difference image, recomputed so the overlay lands on
    /// the same pixels.
    ///
    /// Returns `.null` for a degenerate image or frame rather than dividing by zero: a raster can
    /// be nil-sized while a render is in flight, and the view mounts before it is laid out.
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
    /// **Both coordinate spaces are top-left origin, which is why there is no flip here.** A
    /// `CGBitmapContext`'s buffer starts at the image's TOP row, so the cell indices `BitmapDiff`
    /// walks are already y-down — the same direction as SwiftUI's. A flip would be a bug that
    /// looks correct on a symmetric page.
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
    /// **Silent until the comparison has actually run**, the rule the page strip's dots already
    /// follow: a count printed over a pending render would be describing the previous page.
    /// `nil` for a resolved page with no changes too — "0 regions differ" beside a black canvas is
    /// a sentence restating an empty picture.
    static func caption(regionCount: Int) -> String? {
        switch regionCount {
        case 0: return nil
        case 1: return "1 region differs"
        case 2...maxDrawn: return "\(regionCount) regions differ"
        // Over the cap: the count is still the honest finding, and the missing outlines are
        // disclosed rather than left as a reader wondering where the boxes went.
        default: return "\(regionCount) regions differ — too many to outline"
        }
    }
}
