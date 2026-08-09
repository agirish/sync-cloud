import Foundation
import AppKit
import CoreGraphics

/// Whether Organize's rail can afford to spell its items out.
public enum OrganizeRailStyle: Equatable, Sendable {
    /// Glyph, label, and the badge when there is one.
    case full
    /// Glyph and badge only; the label moves into the tooltip and the accessibility label.
    case iconOnly
}

/// The rail's width arithmetic, kept pure so the shedding rule can be asserted without mounting a
/// header.
///
/// **Why this exists at all: the rail took row 1, and row 1 already had tenants.** Six spelled-out
/// items are about 580pt at the default text size, and the trailing controls on the same row are
/// Rescan, Refine and *File all N* plus the search toggle. At the 900pt canvas the two together
/// overran the row and SwiftUI resolved it the way it always does — by truncating the flexible
/// side, which is the action labels. Nothing disappeared and nothing logged; "Refine with Opus"
/// and "Refine with Haiku" simply rendered as the same clipped stub, and four tests that compared
/// those two renders started seeing identical pixels. That is the failure this arithmetic prevents,
/// and it is worth noting that a probe measuring whether the action band was *inked* saw nothing
/// wrong: ink presence is not label fidelity.
///
/// **Computed, not laddered**, for the same two reasons ``WorkspaceBarMetrics`` gives: a
/// `ViewThatFits` builds every rung on every layout pass, and the answer here has to respond to a
/// width this view is *given* rather than one it asks for.
///
/// The two are deliberately separate types. They shed at different thresholds against different
/// reserved space — the bar reserves traffic lights and a utility pill, this reserves a lens's own
/// controls — and folding them together would make one of the two wrong at every text size.
public enum OrganizeRailMetrics {

    /// What a full item adds around its label: the 10.5pt glyph, the 5pt gap after it, and 2×9pt
    /// of horizontal padding.
    public static let itemChrome: CGFloat = 10.5 + 5 + 18
    /// An item with no label — glyph plus 2×9pt of padding.
    public static let iconOnlyItemWidth: CGFloat = 10.5 + 18
    /// Between items.
    public static let itemGap: CGFloat = 6
    /// A badge and the gap before it. Two digits at 10pt bold plus 2×5pt of capsule padding; three
    /// digits is the realistic ceiling (`126 folders to rename`) and rounds into the same figure.
    public static let badgeWidth: CGFloat = 22 + 5

    /// Row 1 width the rail can never have: the lens's own controls and the search toggle.
    ///
    /// Sized against the widest state Organize has — the filing queue with results, which draws
    /// `Rescan ⌄` (~105), `Refine with Opus` (~150) and `File all N` (~105), plus the search
    /// toggle (~30) and the gaps between them. **Measured off the render, not estimated**: the
    /// first cut of this constant was 300, which left `available` just wide enough for the full
    /// rail at 900pt — so the rail never shed, and the controls truncated to `Refin…` and
    /// `File a…` exactly as before. A reserve that is too small does not fail loudly; it silently
    /// declines to do the one thing this type exists for.
    ///
    /// Deliberately generous in the other direction: being one item too cautious costs six labels
    /// that would have fitted, while being one too optimistic costs the *actions* their words.
    public static let reservedTrailing: CGFloat = 420

    /// Width of the rail with every label spelled out.
    ///
    /// - Parameters:
    ///   - labelWidths: each item's rendered label width, in order. Measured rather than
    ///     tabulated because the app scales its own type, so a constant here would be right at
    ///     exactly one setting.
    ///   - badges: how many items are currently carrying a badge. Counted rather than assumed:
    ///     the rail is at its widest on the day every finding has something to report, which is
    ///     precisely the day it must still fit.
    public static func fullWidth(labelWidths: [CGFloat], badges: Int) -> CGFloat {
        guard !labelWidths.isEmpty else { return 0 }
        let items = labelWidths.reduce(0) { $0 + $1 + itemChrome }
        return items + CGFloat(max(0, labelWidths.count - 1)) * itemGap
            + CGFloat(badges) * badgeWidth
    }

    /// Width of the rail with every label shed. Badges stay — they are the reason to look.
    public static func iconOnlyWidth(itemCount: Int, badges: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount) * iconOnlyItemWidth
            + CGFloat(max(0, itemCount - 1)) * itemGap
            + CGFloat(badges) * badgeWidth
    }

    /// The style a header of this width can seat.
    ///
    /// All-or-nothing, like the bar: shedding one item's label would leave a rail where some
    /// places are words and others are glyphs, which reads as two controls rather than one row of
    /// peers.
    public static func style(contentWidth: CGFloat, labelWidths: [CGFloat],
                             badges: Int) -> OrganizeRailStyle {
        let available = contentWidth - reservedTrailing
        return fullWidth(labelWidths: labelWidths, badges: badges) <= available ? .full : .iconOnly
    }

    /// The rail's labels at the real weight and the ambient text size.
    ///
    /// `.semibold` because that is the selected item's weight and the widest — sizing on `.medium`
    /// would under-measure the one item that is always bold, which is the direction that truncates.
    public static func labelWidths(scale: CGFloat) -> [CGFloat] {
        let font = NSFont.systemFont(ofSize: 11.5 * scale, weight: .semibold)
        return OrganizeLens.allCases.map {
            ($0.title as NSString).size(withAttributes: [.font: font]).width
        }
    }
}
