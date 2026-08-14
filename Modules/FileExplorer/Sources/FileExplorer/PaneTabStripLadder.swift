import Design
import SwiftUI

/// How a pane's tab strip sheds as its pane narrows, and how wide each chip is at every step.
///
/// Three rungs, from the v4.x roadmap §1:
///
/// | Rung | Roughly | Shows |
/// |---|---|---|
/// | `full` | 520pt+ | every tab, at up to 186pt, ＋ at the trailing end |
/// | `compact` | ~340pt | tabs at the 96pt floor, the surplus behind a count chevron |
/// | `chip` | 220pt (the Organize/Storage rail) | the active tab as a chevron-menu, a count for the rest, ＋ |
///
/// **The widths in that table are the pane widths those rungs appear at for a typical four- or
/// five-tab strip, not thresholds this type compares against.** The rung is a function of the
/// offered width, the tab COUNT and the font scale — three tabs still fit at 340pt and get `full`,
/// which is the right answer and is what `theTableInTheRoadmapIsReproduced` pins with the count
/// stated.
///
/// **Priced from `Design.LabelMetrics`, at the app's font scale**, following `HeaderLadder` rather
/// than `PaneBarLadder`. That is roadmap §1's third existing-test constraint and it is not a style
/// preference: every item on the pane bar is a fixed-size glyph pill, so that ladder is a sum of
/// constants and the string `scale` does not appear in it at all. A tab is *text*, and the app
/// scales its own type — so at Large the same five tabs that fit at the default do not, and a
/// ladder of constants would keep drawing five chips with their names clipped out of them.
///
/// The floor is where the scale bites hardest: 96pt is a floor on the *number*, but what a chip
/// actually needs is its chrome plus enough room for a truncated name, and both of those grow with
/// the font. `floorWidth(scale:)` is therefore a measurement, and it is what makes the strip shed a
/// rung earlier at Large instead of drawing chips with no legible name in them.
///
/// Tabs never shrink to mark-only. Five identical cloud marks name nothing, which is the one
/// concession Finder's own strip makes and this one refuses.
@MainActor
public enum PaneTabStripLadder {

    // MARK: - The drawn metrics
    //
    // Each number below is what `PaneTabStrip` actually draws, in that view's own constant where
    // one exists — never a second opinion about it.

    /// The strip card's height. 34pt, which is the provider capsule's height on the header below
    /// it, so the two chrome rows above the file list read as one rhythm.
    public static let stripHeight: CGFloat = 34
    /// The chip's own height inside that card.
    public static let tabHeight: CGFloat = 26
    /// A tab never grows past this, however few there are: a strip of two 400pt tabs reads as a
    /// segmented control, not as tabs.
    public static let maxTabWidth: CGFloat = 186
    /// The floor on the *number* — see `floorWidth(scale:)` for the floor that is measured.
    public static let minTabWidth: CGFloat = 96
    public static let tabGap: CGFloat = 4
    /// Side of the provider mark on a chip.
    public static let markSide: CGFloat = 13
    /// The ✕'s hit target, and the gaps either side of the title.
    public static let closeSide: CGFloat = 16
    public static let contentGap: CGFloat = 5
    public static let tabPadding: CGFloat = 7
    /// The chip's title font, and the one every measurement here is taken in.
    public static let titleFont: ScaledFont = .system(size: 11, weight: .medium)
    /// The ＋ and the overflow chevron's glyph font.
    public static let controlFont: ScaledFont = .system(size: 11, weight: .semibold)
    /// The ＋'s square hit target.
    public static let plusSide: CGFloat = 22

    /// The stub a chip must be able to show of its name before the strip is better off shedding a
    /// rung. Four characters and an ellipsis: shorter than this and a chip is a mark with a smear
    /// beside it, which is the mark-only rung under another name.
    static let titleStub = "Abcd…"

    // MARK: - The answer

    public enum Rung: String, Equatable, Sendable {
        case full, compact, chip
    }

    /// What to draw: which rung, how wide each visible chip is, how many are visible, and how many
    /// are folded behind the count.
    public struct Layout: Equatable, Sendable {
        public let rung: Rung
        /// Width of each visible chip. In `.chip` this is the active tab's menu button.
        public let tabWidth: CGFloat
        public let visibleCount: Int
        public let overflowCount: Int

        public var showsOverflow: Bool { overflowCount > 0 }
    }

    /// The chrome a chip carries either side of its name: padding, mark, gaps, ✕.
    ///
    /// **Takes no scale, deliberately.** The mark and the ✕ are `.frame`d at fixed sides, so they
    /// are the two things on a chip that do not move with the font — the same exemption
    /// `HeaderLadder.glyphButtonSide` records for its glyph buttons. Everything scale-dependent
    /// about a chip is its title, which is measured separately.
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

    /// The trailing ＋.
    public static func plusWidth(scale: CGFloat) -> CGFloat { plusSide + tabGap }

    /// The count chevron that folds the surplus — "3 ⌄", so its width moves with both the digits
    /// and the font.
    public static func overflowWidth(hidden: Int, scale: CGFloat) -> CGFloat {
        LabelMetrics.width(of: "\(hidden)", font: controlFont, scale: scale)
            + 3
            + LabelMetrics.symbolWidth("chevron.down", font: controlFont, scale: scale)
            + 2 * 6
            + tabGap
    }

    /// The widest strip that still has to fall back to `.chip`: below two tabs at the floor plus a
    /// count and a ＋, "one tab and a chevron" is strictly worse than naming the active tab and
    /// menuing the rest, which is what `.chip` does.
    public static func chipCeiling(scale: CGFloat) -> CGFloat {
        2 * floorWidth(scale: scale) + 2 * tabGap + overflowWidth(hidden: 9, scale: scale) + plusWidth(scale: scale)
    }

    /// The rung for an offered width.
    ///
    /// Walked as a sequence of concessions, in order — every tab at its natural width, then every
    /// tab squeezed toward the floor, then tabs folded behind a count, then the chip — which is
    /// `ViewThatFits`'s own rule reproduced arithmetically, for `HeaderLadder`'s reason: a
    /// `ViewThatFits` here would BUILD every rung to measure it, on every render of a pane.
    public static func layout(available: CGFloat, titles: [String], scale: CGFloat) -> Layout {
        let count = titles.count
        guard count > 1 else {
            // One tab draws no strip at all (Finder's rule), so there is nothing to lay out. The
            // caller checks `showsStrip`; this is the answer that cannot mislead if it does not.
            return Layout(rung: .full, tabWidth: 0, visibleCount: count, overflowCount: 0)
        }

        let floor = floorWidth(scale: scale)
        let plus = plusWidth(scale: scale)

        if available < chipCeiling(scale: scale) {
            let chipWidth = max(0, available - plus - overflowWidth(hidden: count - 1, scale: scale))
            return Layout(rung: .chip, tabWidth: min(maxTabWidth, chipWidth),
                          visibleCount: 1, overflowCount: count - 1)
        }

        // Every tab visible, sharing the track evenly and capped by what the longest name needs.
        let share = (available - plus - CGFloat(count) * tabGap) / CGFloat(count)
        if share >= floor {
            let needed = titles.map { naturalWidth(title: $0, scale: scale) }.max() ?? floor
            return Layout(rung: .full, tabWidth: min(share, needed),
                          visibleCount: count, overflowCount: 0)
        }

        // Squeezed to the floor, with the surplus folded behind a count.
        //
        // The count is priced for the number it will actually show, and that is not pedantry: the
        // hidden count depends on how many fit, which depends on the width of the count — so it is
        // solved by walking down rather than by dividing, and a strip of 12 tabs whose "11" is
        // wider than its "9" cannot round its way into an overflowing row.
        var visible = max(1, Int((available - plus) / (floor + tabGap)))
        while visible >= 1 {
            let hidden = count - visible
            let used = CGFloat(visible) * (floor + tabGap)
                + (hidden > 0 ? overflowWidth(hidden: hidden, scale: scale) : 0)
                + plus
            if used <= available { break }
            visible -= 1
        }
        guard visible >= 1 else {
            let chipWidth = max(0, available - plus - overflowWidth(hidden: count - 1, scale: scale))
            return Layout(rung: .chip, tabWidth: min(maxTabWidth, chipWidth),
                          visibleCount: 1, overflowCount: count - 1)
        }
        return Layout(rung: .compact, tabWidth: floor,
                      visibleCount: visible, overflowCount: count - visible)
    }

    /// Everything the strip will draw, in points — what a "does it overflow" test measures, and the
    /// definition of the ladder never widening as it sheds.
    public static func drawnWidth(_ layout: Layout, scale: CGFloat) -> CGFloat {
        switch layout.rung {
        case .full, .compact:
            return CGFloat(layout.visibleCount) * (layout.tabWidth + tabGap)
                + (layout.showsOverflow ? overflowWidth(hidden: layout.overflowCount, scale: scale) : 0)
                + plusWidth(scale: scale)
        case .chip:
            return layout.tabWidth
                + (layout.showsOverflow ? overflowWidth(hidden: layout.overflowCount, scale: scale) : 0)
                + plusWidth(scale: scale)
        }
    }
}
