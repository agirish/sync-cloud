import Design
import SwiftUI

/// How a pane's tab strip sheds as its pane narrows, and how wide each chip is at every step.
///
/// | Rung | Roughly | Shows |
/// |---|---|---|
/// | `full` | 520pt+ | every tab, at up to 186pt, ＋ at the trailing end |
/// | `compact` | ~340pt | tabs at the 96pt floor, the surplus behind a count chevron |
/// | `chip` | 220pt (the Organize/Storage rail) | the active tab as a chevron-menu, a count for the rest, ＋ |
///
/// The widths are where the rungs appear for a typical four- or five-tab strip, not thresholds:
/// the rung depends on the offered width, the tab count and the font scale, so three tabs still
/// get `full` at 340pt (`theTableInTheRoadmapIsReproduced` pins this with the count stated).
///
/// Priced from `Design.LabelMetrics` at the app's font scale, like `HeaderLadder` and unlike the
/// glyph-only `PaneBarLadder`: a tab is text, so five tabs that fit at the default don't at Large.
/// `floorWidth(scale:)` is measured for the same reason, so the strip sheds a rung earlier at Large
/// instead of drawing chips with no legible name. Tabs never shrink to mark-only: five identical
/// cloud marks name nothing.
@MainActor
public enum PaneTabStripLadder {

    // MARK: - The drawn metrics
    //
    // Each number below is what `PaneTabStrip` draws, never a second opinion about it.

    /// The strip card's height: the provider capsule's height on the header below, so the two
    /// chrome rows above the file list share one rhythm.
    public static let stripHeight: CGFloat = 34

    /// How far the strip pushes the pane's toolbar card down: what a column beside the pane must
    /// leave empty to keep its header level (see `EditorWorkspaceView.paneShowsTabStrip` and
    /// `LensWorkspaceView.paneShowsTabStrip`).
    ///
    /// In `.cards`, `paneCardIfNeeded` insets the strip's card on every side, so it costs its
    /// height and one gutter; in `.unified` the strip is flush and costs its height alone.
    public static func slotHeight(_ style: SurfaceStyle) -> CGFloat {
        stripHeight + (style == .cards ? LiquidGlass.cardGutter : 0)
    }
    /// The chip's own height inside that card.
    public static let tabHeight: CGFloat = 26
    /// A tab never grows past this, however few there are: two 400pt tabs read as a segmented
    /// control.
    public static let maxTabWidth: CGFloat = 186
    /// The fixed floor; `floorWidth(scale:)` is the measured one.
    public static let minTabWidth: CGFloat = 96
    public static let tabGap: CGFloat = 4
    /// Side of the provider mark on a chip.
    public static let markSide: CGFloat = 13
    /// The ✕'s hit target, and the gaps either side of the title.
    public static let closeSide: CGFloat = 16
    public static let contentGap: CGFloat = 5
    public static let tabPadding: CGFloat = 7

    // MARK: - The strip's own corner geometry
    //
    // One relationship, not three numbers, stated once so it can be tested
    // (`theChipNestsConcentricallyInsideTheCard`).

    /// The track the strip keeps clear at its leading and trailing edges, inside the card.
    ///
    /// 4, not `LiquidGlass.cardGutter`'s 5: the chip, 26pt tall in a 34pt row, is already inset 4
    /// vertically, so a uniform inset of 4 lets `14 - 4 = 10` hold on all four corners. Read by two
    /// sites that must agree: the row's padding and the width `PaneTabStrip` offers
    /// `layout(available:)`. If they differ, the ladder overstates its room and squeezes the
    /// parked-tab count at the rail's 220pt.
    public static let stripGutter: CGFloat = 4

    /// The chip's corner: `Radius.card - stripGutter`, `14 - 4` = 10, which is `Radius.well`, so
    /// the first and last chips trace the card's corners and the strip adds no new number.
    ///
    /// Not `Radius.chip` (6): that token is shared with pills, badges and `DestinationPicker`'s
    /// rows, none of which sit inside a 14pt card at a 4pt inset.
    public static let chipRadius: CGFloat = Radius.well

    /// How far the active tab's rule is inset from the chip's frame, each side.
    ///
    /// A measurement, not `chipRadius` re-typed: a `.continuous` corner pulls its paint in past the
    /// nominal radius as it grows, about 10.75pt at r=10. An inset of the radius leaves the rule's
    /// ends hanging over the card, and `+ 1` clears the paint by nothing. `+ 2` leaves a point of
    /// chip beyond each end; nothing clips the rule, since `chipGround` is a plain `ZStack`.
    /// `theRuleEndsInsideTheChipItMarks` asserts containment, not this number.
    public static let ruleInset: CGFloat = chipRadius + 2
    /// The chip's title font, and the one every measurement here is taken in.
    public static let titleFont: ScaledFont = .system(size: 11, weight: .medium)
    /// The ＋ and the overflow chevron's glyph font.
    public static let controlFont: ScaledFont = .system(size: 11, weight: .semibold)
    /// The ＋'s square hit target.
    public static let plusSide: CGFloat = 22

    /// The stub of its name a chip must be able to show before the strip is better off shedding a
    /// rung. Four characters and an ellipsis: any shorter and the chip is mark-only in all but name.
    static let titleStub = "Abcd…"

    // MARK: - The answer

    public enum Rung: String, Equatable, Sendable {
        case full, compact, chip
    }

    /// What to draw: which rung, how wide each visible chip is, how many are visible, and how many
    /// are folded behind the count.
    public struct Layout: Equatable, Sendable {
        public let rung: Rung
        /// Width of each visible chip. On `.full` and `.compact` it is what each chip is drawn at;
        /// on `.chip` it is a cap: the chip takes what its name needs up to this, and the strip's
        /// spacer absorbs the rest (see `PaneTabStrip.activeChipMenu`).
        public let tabWidth: CGFloat
        public let visibleCount: Int
        public let overflowCount: Int

        public var showsOverflow: Bool { overflowCount > 0 }
    }

    /// The chrome a chip carries either side of its name: padding, mark, gaps, ✕.
    ///
    /// Takes no scale: the mark and the ✕ are framed at fixed sides, the exemption
    /// `HeaderLadder.glyphButtonSide` records for glyph buttons. The title is measured separately.
    public static let chromeWidth: CGFloat =
        tabPadding + markSide + contentGap + contentGap + closeSide + tabPadding

    /// The narrowest a chip may be drawn at this font scale: its chrome plus a legible stub of a
    /// name, never less than the 96pt floor.
    public static func floorWidth(scale: CGFloat) -> CGFloat {
        max(minTabWidth,
            chromeWidth + LabelMetrics.width(of: titleStub, font: titleFont, scale: scale))
    }

    /// What a chip would like to be: its chrome plus its whole name, capped at `maxTabWidth`.
    public static func naturalWidth(title: String, scale: CGFloat) -> CGFloat {
        min(maxTabWidth,
            max(floorWidth(scale: scale),
                chromeWidth + LabelMetrics.width(of: title, font: titleFont, scale: scale)))
    }

    /// The gaps in a row of `children`. Every width here is an element's own, with no gap folded
    /// in, and gaps are counted once from the `HStack`'s real children: `[tabs…] [overflow?]
    /// [spacer] [＋]`. The spacer is a real child (a double-click there opens a tab), so it takes a
    /// gap on both sides even at zero width.
    static func gaps(children: Int) -> CGFloat { CGFloat(max(0, children - 1)) * tabGap }

    /// The trailing ＋, on its own.
    public static func plusWidth(scale: CGFloat) -> CGFloat { plusSide }

    /// The chevron menu that folds the surplus away on `.full` and `.compact`: "3 ⌄", so its width
    /// moves with the digits and the font.
    public static func overflowWidth(hidden: Int, scale: CGFloat) -> CGFloat {
        countWidth(hidden: hidden, scale: scale)
            + 3
            + LabelMetrics.symbolWidth("chevron.down", font: controlFont, scale: scale)
    }

    /// The chip rung's plain count: a number, not a second switcher, so no chevron.
    public static func countWidth(hidden: Int, scale: CGFloat) -> CGFloat {
        LabelMetrics.width(of: "\(hidden)", font: controlFont, scale: scale) + 2 * 6
    }

    /// The widest strip that still falls back to `.chip`: below two tabs at the floor plus a count
    /// and a ＋, "one tab and a chevron" is worse than naming the active tab and menuing the rest.
    /// Priced at a two-digit count, the widest a real strip reaches, so it doesn't move as tabs open.
    ///
    /// Five children, the narrowest `.compact` row worth drawing: `[tab] [tab] [overflow] [spacer]
    /// [＋]`. Counting four would leave the ceiling a gap short, and `layout` would return
    /// `.compact` with a single chip beside a chevron, the row this threshold exists to refuse.
    public static func chipCeiling(scale: CGFloat) -> CGFloat {
        2 * floorWidth(scale: scale)
            + overflowWidth(hidden: 99, scale: scale)
            + plusWidth(scale: scale)
            + gaps(children: 5)
    }

    /// The rung for an offered width.
    ///
    /// Walked as concessions in order: every tab at its natural width, then squeezed toward the
    /// floor, then folded behind a count, then the chip. `ViewThatFits`'s rule done in arithmetic,
    /// for `HeaderLadder`'s reason: a `ViewThatFits` would build every rung on every pane render.
    public static func layout(available: CGFloat, titles: [String], scale: CGFloat) -> Layout {
        let count = titles.count
        guard count > 0 else {
            return Layout(rung: .full, tabWidth: 0, visibleCount: 0, overflowCount: 0)
        }
        // One tab is laid out like any other: View ▸ Tab Bar can keep a one-tab strip on screen,
        // and whether to draw a strip at all is the caller's question (`PaneTabList.showsStrip`).

        let floor = floorWidth(scale: scale)
        let plus = plusWidth(scale: scale)

        if available < chipCeiling(scale: scale) {
            return chipRung(available: available, count: count, scale: scale)
        }

        // Every tab visible, sharing the track evenly and capped by what the longest name needs.
        // Children: the tabs, the spacer, the ＋.
        let share = (available - plus - gaps(children: count + 2)) / CGFloat(count)
        if share >= floor {
            let needed = titles.map { naturalWidth(title: $0, scale: scale) }.max() ?? floor
            return Layout(rung: .full, tabWidth: min(share, needed),
                          visibleCount: count, overflowCount: 0)
        }

        // Squeezed to the floor, with the surplus folded behind a count. The count is priced for
        // the number it will show, which depends on how many fit, so it is solved by walking down,
        // not dividing: an "11" wider than a "9" can't round its way into an overflowing row.
        // The estimate ignores the overflow (which only reduces capacity, so walking down from it
        // is right), and is clamped to `count`, which a wide pane with few tabs would exceed.
        var visible = min(count, max(1, Int((available - plus) / (floor + tabGap))))
        while visible >= 1 {
            let hidden = count - visible
            // Children: the visible tabs, the overflow (when there is one), the spacer, the ＋.
            let used = CGFloat(visible) * floor
                + (hidden > 0 ? overflowWidth(hidden: hidden, scale: scale) : 0)
                + plus
                + gaps(children: visible + (hidden > 0 ? 1 : 0) + 2)
            if used <= available { break }
            visible -= 1
        }
        guard visible >= 1 else { return chipRung(available: available, count: count, scale: scale) }
        return Layout(rung: .compact, tabWidth: floor,
                      visibleCount: visible, overflowCount: count - visible)
    }

    /// The rail's rung: the active tab named, a count for the rest, and the ＋.
    private static func chipRung(available: CGFloat, count: Int, scale: CGFloat) -> Layout {
        // A one-tab strip draws no count, so reserves no room for one: that room would come from
        // the name, the one thing this rung must keep.
        let hidden = count - 1
        let children = hidden > 0 ? 4 : 3      // chip, count?, spacer, ＋
        let chipWidth = available
            - plusWidth(scale: scale)
            - (hidden > 0 ? countWidth(hidden: hidden, scale: scale) : 0)
            - gaps(children: children)
        return Layout(rung: .chip, tabWidth: max(0, min(maxTabWidth, chipWidth)),
                      visibleCount: 1, overflowCount: hidden)
    }

    /// Everything the strip will draw, in points: what an overflow test measures, and what must
    /// never grow as the ladder sheds.
    public static func drawnWidth(_ layout: Layout, scale: CGFloat) -> CGFloat {
        switch layout.rung {
        case .full, .compact:
            return CGFloat(layout.visibleCount) * layout.tabWidth
                + (layout.showsOverflow ? overflowWidth(hidden: layout.overflowCount, scale: scale) : 0)
                + plusWidth(scale: scale)
                + gaps(children: layout.visibleCount + (layout.showsOverflow ? 1 : 0) + 2)
        case .chip:
            // The chip rung draws a plain count, not the chevron menu, and none at one tab, which is
            // one fewer child as well as one fewer element.
            return layout.tabWidth
                + (layout.showsOverflow ? countWidth(hidden: layout.overflowCount, scale: scale) : 0)
                + plusWidth(scale: scale)
                + gaps(children: layout.showsOverflow ? 4 : 3)
        }
    }
}
