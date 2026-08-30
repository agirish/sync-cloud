import Design
import SwiftUI

/// How a pane's tab strip sheds as its pane narrows, and how wide each chip is at every step.
///
/// Three rungs, from the v4.x roadmap companion §1:
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
/// than `PaneBarLadder`. That is roadmap companion §1's third existing-test constraint and it is not a style
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

    // MARK: - The strip's own corner geometry
    //
    // These three are one relationship, not three numbers, and they are here rather than at the
    // three sites that used to spell them out so that the relationship can be stated once and
    // tested. See `theChipNestsConcentricallyInsideTheCard`.

    /// The track the strip keeps clear at its leading and trailing edges, INSIDE the card.
    ///
    /// **4, not `LiquidGlass.cardGutter`'s 5, and the difference is the whole point.** The strip
    /// card is drawn at `Radius.card` (14) and the chip is centred in a 34pt row at 26pt tall, so
    /// the vertical inset is already 4. At a horizontal gutter of 5 the chip could not be
    /// concentric on all four corners at once — it needed radius 9 across and 10 down, and had 6.
    /// Matching the horizontal gutter to the vertical one makes the inset uniform, and
    /// `14 - 4 = 10` then holds everywhere.
    ///
    /// **Read by two sites that must agree**: the row's leading/trailing padding, and the width
    /// `PaneTabStrip` offers `layout(available:)`. They were `LiquidGlass.cardGutter` in both, and
    /// two copies of a number only ever agree by luck — a change to one alone silently overstates
    /// the room the ladder has to spend and squeezes the parked-tab count at the rail's 220pt.
    public static let stripGutter: CGFloat = 4

    /// The chip's corner, and it is `Radius.well` for a reason rather than by coincidence.
    ///
    /// Concentricity wants `Radius.card - stripGutter` = `14 - 4` = 10, and 10 is already a stop on
    /// the scale. So the strip introduces no new number: the first chip's corner traces the card's
    /// corner exactly, and so does the last chip's against the trailing edge.
    ///
    /// **Not `Radius.chip`, which stays at 6.** That token is shared with pills, inline badges and
    /// `DestinationPicker`'s rows, none of which sit inside a 14pt card at a 4pt inset. This is the
    /// strip's own radius; moving the token to suit the strip would have been the wrong fix.
    public static let chipRadius: CGFloat = Radius.well

    /// How far the active tab's rule is inset from the chip's frame, each side.
    ///
    /// **It is a measurement, not `chipRadius` re-typed.** A `.continuous` corner pulls its paint
    /// in past the nominal radius as the radius grows: rendering the chip's shape and reading the
    /// bottom-most scanline back gives 6.00pt in from each edge at r=6, but **10.75pt at r=10**
    /// (at 8×; the strip's own render reads 11.0pt over its bottom half-point at 2×). So an inset
    /// of exactly the radius leaves the ends hanging over the card, and `radius + 1` clears the
    /// paint by nothing at all — measured equal to its edge, which is a test passing on its
    /// tolerance rather than on a margin.
    ///
    /// **`+ 2` is that margin**: a full point of chip either side of the rule's ends, bought for one
    /// point of rule on a chip that is never narrower than `minTabWidth`.
    ///
    /// This was the shipped defect: the rule sat at 3 against a 6pt corner, so its last 3pt at each
    /// end lay over the card, not over the chip — nothing clips it, `chipGround` being a plain
    /// `ZStack` behind the chip. `theRuleEndsInsideTheChipItMarks` asserts CONTAINMENT rather than
    /// this number, so it stays honest if the corner style ever changes under it.
    public static let ruleInset: CGFloat = chipRadius + 2
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
        /// Width of each visible chip. On `.full` and `.compact` it is what each chip is drawn at;
        /// on `.chip` it is a **cap** — the chip takes what its name needs up to this, and the
        /// strip's spacer absorbs the rest (see `PaneTabStrip.activeChipMenu`).
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

    /// **Every width here is an element's own, with no gap folded into it**, and the gaps are
    /// counted once, from the number of children the `HStack` actually has.
    ///
    /// The first cut of this file embedded "and the gap before me" in each width, which double-
    /// counted in one place and under-counted in another — and the under-count landed on the chip
    /// rung, where the leading element consumes everything left, so the strip's count of parked
    /// tabs rendered clipped. Counting children is the form that cannot drift: the strip's row is
    /// `[tabs…] [overflow?] [spacer] [＋]`, and the spacer is a real child (it is what a double-
    /// click opens a tab on) so it takes a gap on both sides even at zero width.
    static func gaps(children: Int) -> CGFloat { CGFloat(max(0, children - 1)) * tabGap }

    /// The trailing ＋, on its own.
    public static func plusWidth(scale: CGFloat) -> CGFloat { plusSide }

    /// The chevron menu that folds the surplus away — "3 ⌄", so its width moves with the digits and
    /// the font. The `.full` and `.compact` rungs' overflow, where it is the only way to reach a
    /// folded-away tab.
    public static func overflowWidth(hidden: Int, scale: CGFloat) -> CGFloat {
        countWidth(hidden: hidden, scale: scale)
            + 3
            + LabelMetrics.symbolWidth("chevron.down", font: controlFont, scale: scale)
    }

    /// The chip rung's plain count — a number rather than a second switcher, so no chevron.
    public static func countWidth(hidden: Int, scale: CGFloat) -> CGFloat {
        LabelMetrics.width(of: "\(hidden)", font: controlFont, scale: scale) + 2 * 6
    }

    /// The widest strip that still has to fall back to `.chip`: below two tabs at the floor plus a
    /// count and a ＋, "one tab and a chevron" is strictly worse than naming the active tab and
    /// menuing the rest, which is what `.chip` does.
    ///
    /// Priced at a two-digit count — the widest a real strip reaches — so the threshold does not
    /// move as tabs are opened.
    ///
    /// **Five children, not four**, and the difference is the whole point of the number: this is the
    /// price of the narrowest `.compact` row worth drawing, which is `[tab] [tab] [overflow]
    /// [spacer] [＋]`. Counting four left the ceiling one gap — 4pt — under what that row costs, so
    /// between the two prices `layout` fell through to the compact walk-down, could not fit the
    /// second chip, and returned `.compact` with a **single** chip beside a chevron: exactly the
    /// "one tab and a chevron" this threshold exists to refuse. Measured before the fix at scale
    /// 1.0: 12 or more tabs at a pane width of 269–270pt, seventeen (count, width) pairs in all.
    public static func chipCeiling(scale: CGFloat) -> CGFloat {
        2 * floorWidth(scale: scale)
            + overflowWidth(hidden: 99, scale: scale)
            + plusWidth(scale: scale)
            + gaps(children: 5)
    }

    /// The rung for an offered width.
    ///
    /// Walked as a sequence of concessions, in order — every tab at its natural width, then every
    /// tab squeezed toward the floor, then tabs folded behind a count, then the chip — which is
    /// `ViewThatFits`'s own rule reproduced arithmetically, for `HeaderLadder`'s reason: a
    /// `ViewThatFits` here would BUILD every rung to measure it, on every render of a pane.
    public static func layout(available: CGFloat, titles: [String], scale: CGFloat) -> Layout {
        let count = titles.count
        guard count > 0 else {
            return Layout(rung: .full, tabWidth: 0, visibleCount: 0, overflowCount: 0)
        }
        // **One tab is laid out like any other.** It is usually not drawn at all — the pane checks
        // `PaneTabList.showsStrip` first, Finder's rule — but View ▸ Tab Bar keeps a one-tab strip
        // on screen deliberately, and a rung that answered "zero wide" for that case rendered a
        // strip holding nothing but its ＋. Whether to draw a strip is the caller's question; how
        // wide its chips are is this one's, and the two were tangled here.

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

        // Squeezed to the floor, with the surplus folded behind a count.
        //
        // The count is priced for the number it will actually show, and that is not pedantry: the
        // hidden count depends on how many fit, which depends on the width of the count — so it is
        // solved by walking down rather than by dividing, and a strip of 12 tabs whose "11" is
        // wider than its "9" cannot round its way into an overflowing row.
        // Clamped to the tabs that exist: the estimate ignores the overflow (which only reduces
        // capacity, so walking down from it is right), but with a wide pane and few tabs it can
        // come out above `count` — and a rung claiming to show more chips than there are is
        // incoherent even where nothing currently reads it that way.
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
        // A one-tab strip has no count to draw — and reserving room for the one it will not draw
        // is track taken from the only thing on this rung that has to survive, the name.
        let hidden = count - 1
        let children = hidden > 0 ? 4 : 3      // chip, count?, spacer, ＋
        let chipWidth = available
            - plusWidth(scale: scale)
            - (hidden > 0 ? countWidth(hidden: hidden, scale: scale) : 0)
            - gaps(children: children)
        return Layout(rung: .chip, tabWidth: max(0, min(maxTabWidth, chipWidth)),
                      visibleCount: 1, overflowCount: hidden)
    }

    /// Everything the strip will draw, in points — what a "does it overflow" test measures, and the
    /// definition of the ladder never widening as it sheds.
    public static func drawnWidth(_ layout: Layout, scale: CGFloat) -> CGFloat {
        switch layout.rung {
        case .full, .compact:
            return CGFloat(layout.visibleCount) * layout.tabWidth
                + (layout.showsOverflow ? overflowWidth(hidden: layout.overflowCount, scale: scale) : 0)
                + plusWidth(scale: scale)
                + gaps(children: layout.visibleCount + (layout.showsOverflow ? 1 : 0) + 2)
        case .chip:
            // The chip rung draws a plain COUNT, not the chevron menu — priced as what it draws,
            // and it draws none at one tab, which is one fewer child as well as one fewer element.
            return layout.tabWidth
                + (layout.showsOverflow ? countWidth(hidden: layout.overflowCount, scale: scale) : 0)
                + plusWidth(scale: scale)
                + gaps(children: layout.showsOverflow ? 4 : 3)
        }
    }
}
