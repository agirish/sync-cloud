import Foundation
import CoreGraphics

/// Whether the workspace bar can afford to spell its segments out.
///
/// Six labelled segments are about 500pt, and the toolbar also has to seat the traffic lights and
/// the trailing utility pill. Against the window's 600pt `minWidth` that does not fit, and a
/// toolbar that does not fit does not wrap or truncate — macOS silently folds the overflow behind
/// a chevron, which is how the *only* control for switching workspace disappears. The two-level
/// picker avoided this by keeping the lens tabs out of the toolbar entirely; a flat bar cannot.
enum WorkspaceBarStyle: Equatable {
    /// Glyph and label.
    case full
    /// Glyph alone; the label moves into the tooltip and the accessibility label.
    case iconOnly
}

/// The bar's width arithmetic, kept pure so the shedding rule can be asserted without laying out
/// a toolbar.
///
/// **Computed, not laddered.** The obvious SwiftUI answer is `ViewThatFits` over a full rung and
/// an icon-only rung, and that is wrong twice over here. It builds every rung on every layout
/// pass — the pane bar's ten-rung ladder cost 831ms a click for exactly that reason (`772b6ca`
/// replaced it with arithmetic) — and, worse, a toolbar item is proposed its own ideal width
/// rather than the window's, so `ViewThatFits` would never see the constraint and would pick the
/// full rung at every size. Measuring the content width and doing the sum is both cheaper and the
/// only version that actually responds.
enum WorkspaceBarMetrics {

    /// What a segment adds around its label: the 14pt glyph, the 6pt gap after it, and 2×12pt of
    /// horizontal padding.
    static let segmentChrome: CGFloat = 14 + 6 + 24
    /// A segment with no label — glyph plus 2×10pt padding, which is tighter than the labelled
    /// form because there is nothing for the padding to separate the glyph from.
    static let iconOnlySegmentWidth: CGFloat = 14 + 20
    /// Between segments, inside the container capsule.
    static let segmentGap: CGFloat = 4
    /// The container capsule's own inset, both edges.
    static let containerPadding: CGFloat = 6
    /// The rule that separates Compare from the lens workspaces: a 1pt `Divider` inside 2×4pt of
    /// horizontal padding. Its `segmentGap` on either side is NOT in here — it is a child of the
    /// same `HStack`, so it is counted by the gap term below like any other child.
    static let separatorWidth: CGFloat = 1 + 8

    /// Toolbar width the bar can never have: the traffic lights and their margin, the minimum gap
    /// before the trailing group, and the utility pill (Info, Logs, Settings). Deliberately
    /// generous — being one segment too cautious costs a label, being one too optimistic costs the
    /// entire control behind an overflow chevron.
    static let reservedChrome: CGFloat = 78 + 24 + 132

    /// Width of the bar with every label spelled out.
    ///
    /// - Parameters:
    ///   - labelWidths: each segment's rendered label width, in order. Measured rather than
    ///     estimated because the app scales its own type (Settings ▸ Text size), so a constant
    ///     here would be right at exactly one setting.
    ///   - separators: how many group separators the bar draws.
    static func fullWidth(labelWidths: [CGFloat], separators: Int = 1) -> CGFloat {
        guard !labelWidths.isEmpty else { return 0 }
        let segments = labelWidths.reduce(0) { $0 + $1 + segmentChrome }
        return segments + gapWidth(children: labelWidths.count + separators)
            + CGFloat(separators) * separatorWidth + containerPadding
    }

    /// The `HStack`'s spacing total. Counted over CHILDREN, not segments: each separator is a
    /// child too, so a bar of five segments and one rule has six children and five gaps — not
    /// four. Getting this wrong under-measures the bar, which is the dangerous direction: it
    /// claims the labels fit when they are a couple of points too wide to.
    static func gapWidth(children: Int) -> CGFloat {
        CGFloat(max(0, children - 1)) * segmentGap
    }

    /// Width of the bar with every label shed.
    static func iconOnlyWidth(segmentCount: Int, separators: Int = 1) -> CGFloat {
        guard segmentCount > 0 else { return 0 }
        let segments = CGFloat(segmentCount) * iconOnlySegmentWidth
        return segments + gapWidth(children: segmentCount + separators)
            + CGFloat(separators) * separatorWidth + containerPadding
    }

    /// The style a window of this content width can seat.
    ///
    /// All-or-nothing on purpose: shedding labels one segment at a time would leave a bar where
    /// some workspaces are words and others are glyphs, which reads as two different controls
    /// rather than one row of peers.
    static func style(contentWidth: CGFloat, labelWidths: [CGFloat], separators: Int = 1) -> WorkspaceBarStyle {
        let available = contentWidth - reservedChrome
        return fullWidth(labelWidths: labelWidths, separators: separators) <= available ? .full : .iconOnly
    }
}
