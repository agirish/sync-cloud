import Foundation
import AppKit
import CoreGraphics
// For `FontSize.scaledPointSize` — the text-size ramp's own curve, so this model asks the type
// that owns it rather than keeping a second copy of the arithmetic.
import Design

/// Whether Organize's rail can afford to spell its items out.
enum OrganizeRailStyle: Equatable, Sendable {
    /// Glyph, label, and the badge when there is one.
    case full
    /// Glyph and badge only; the label moves into the tooltip and the accessibility label.
    case iconOnly
}

/// The rail's width arithmetic, kept pure so the shedding rule can be asserted without mounting a
/// header.
///
/// **Why this exists at all: the rail took row 1, and row 1 already had tenants.** Seven
/// spelled-out elements — the overview plus six lenses — are about 765pt at the default text size
/// with three-digit badges up (623pt with every item quiet), and the trailing controls on the same row are
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
///
/// ## The leading side is measured per item, not per item *count*
///
/// The first version of this modelled a rail item as `label + 33.5` and a badge as a flat 27, and
/// shipped a truncation on Duplicates — `Apply 410 recommended` rendering as `Apply 410 recommen…`
/// at a card width where the model said there was 50pt spare. Measured off the render, three
/// separate under-counts were stacked in that estimate:
///
/// - **A glyph is not its point size.** The estimate charged every item 10.5pt, the symbol's
///   *point size*. `doc` actually renders 12pt wide and `folder.badge.gearshape` 17pt — see
///   ``glyphWidth(_:scale:)``, whose numbers are pinned against the live renderer by
///   `theGlyphTableMatchesTheRenderer`.
/// - **A badge is as wide as its digits.** 27pt was measured on two digits. The Duplicates badge
///   reads `410` and the Renames badge `126`; each costs ~35.5. ``badgeWidth(_:scale:)`` measures
///   the digits it is actually given.
/// - **A companion control was not counted at all.** An intro button (i) sat beside the rail on
///   row 1's leading side and the model only ever measured the rail, so it was short by 21pt on
///   every Organize lens. That button has since been removed and the leading half is the rail
///   alone — but the lesson outlives it: anything put back on this side of the row belongs in
///   ``leadingWidth(scale:state:)``, not merely in `LensWorkspaceView.lensTitle`.
///
/// Together those came to ~63pt at four badges, which is why the row truncated while the
/// arithmetic reported room. The failure mode worth remembering is not the size of the error but
/// its *shape*: because the estimate was wrong per item and per digit, the width the row really
/// needed drifted with the badge counts, so **no fixed trailing reserve could have been
/// correct**. Measured against the render, the required reserve came out at 449.6 with three
/// badges and 458.6 with four; with the leading side measured properly it is 394.8 and 395.3 —
/// the same number twice, which is what makes a constant legitimate here at all.
enum OrganizeRailMetrics {

    /// Between an item's glyph and its label.
    static let glyphGap: CGFloat = 5
    /// An item's own horizontal padding, 2×9pt.
    static let itemPadding: CGFloat = 18
    /// Between items.
    static let itemGap: CGFloat = 6
    /// Between a label and the badge after it.
    static let badgeGap: CGFloat = 5
    /// The overview item's label and glyph — it is not an ``OrganizeLens``, so the rail's own
    /// `allCases` walk cannot find it and this model would otherwise draw a control it never
    /// charged for. That is precisely how a 21pt intro button once rode this row uncounted.
    static let overviewTitle = "All"
    static let overviewSymbol = "square.grid.2x2"
    /// `square.grid.2x2` at 10.5pt semibold, measured off `NSImage(systemSymbolName:)` exactly as
    /// ``glyphWidth(_:scale:)``'s table was — a glyph is not its point size, and this one is 13.
    static let overviewGlyphWidth: CGFloat = 13
    /// Margin on the overview item, because its label is the one that changes weight with
    /// selection: `RailItemLabel` draws the current item `.semibold` and the rest `.medium`, and
    /// "All" is unselected in every state except the overview itself. Over, never under, for the
    /// reason `theLeadingModelMatchesWhatTheRowDraws` states: a model short of the row it
    /// describes lets the row overrun before it sheds.
    ///
    /// **6, re-measured when the labels moved onto ``LabelMetrics``.** It was 8, chosen against a
    /// `labelWidth` that took `NSAttributedString.size()` raw; `LabelMetrics` applies SwiftUI's
    /// own half-point ceiling to a text run, so every label got up to half a point wider and the
    /// total slack rose past the 12pt ceiling that test holds. This is the term that exists AS
    /// slack, so this is where the more faithful measurement is paid for. Measured after the
    /// change, model over render: **6.8 / 5.0 / 10.25 / 8.95pt** across the four text sizes —
    /// still over at every one, and the widest is inside the 12pt bar with room.
    static let overviewMargin: CGFloat = 6
    /// A group separator: the 1pt rule, plus the ONE `itemGap` adding an element to the row costs.
    ///
    /// Not two. The rail is an `HStack(spacing: itemGap)`, so N elements carry N−1 gaps and each
    /// element added contributes exactly one more — charging a separator for the gap on both sides
    /// counts every interior gap twice. Measured: it put the model 12pt over the render across all
    /// four text sizes, which is the same 12pt for two separators.
    static var separatorWidth: CGFloat { 1 + itemGap }
    /// The dot an unscanned item draws where a badge would go — 4pt and the gap before it.
    static let notScannedDotWidth: CGFloat = 4 + badgeGap

    /// Row 1 width the rail can never have: **the search toggle, and nothing else.**
    ///
    /// This was a per-lens number — 490 for To File, 420 for the other five — because the lens's
    /// own controls sat opposite the rail. They are on row 2 now (see `LensWorkspaceView.lensTrailing`),
    /// and this constant is the reason they moved: the rail spells out at 693pt, so a 490pt
    /// reserve meant row 1 wanted **1,183pt of card** before it would show six names. Most windows
    /// are narrower than that, so most windows got the glyph-only rail — the shed was the normal
    /// state rather than the exception it was designed to be.
    ///
    /// **Storage's fold added one badgeless item and moved that threshold to ~801pt** (default text
    /// size, three-digit badges on the four counters; ~659 with the rail quiet) — measured, not
    /// estimated, and `theLeadingModelMatchesWhatTheRowDraws` holds it against the render at every
    /// text size. Badgeless is the cheapest kind of item there is: 86.7pt at default, no badge to
    /// reserve digits for. What the same commit *removed* is larger — the whole separate
    /// `storageRail` and its `storageLeadingWidth` special case, so row 1 went from two rails that
    /// shed by different rules to one.
    ///
    /// The measured trailing sets are kept here because they are what justified the move and would
    /// have to be re-measured to undo it: To File **436.5–468** with the refine offer showing,
    /// Duplicates **354**, Names 240, Renames and Restructure 129, Rules and the overview less
    /// again. Nothing reads them now.
    ///
    /// What remains is the toggle `LensHeaderCard` appends itself: a 22pt square plus the 8pt gap
    /// before it, with 6pt of margin on top — 30 measured, 36 budgeted. Flat across text sizes for
    /// the same reason the per-lens number was: it is an AppKit control at
    /// `.controlSize(.small)`, which follows the system control font rather than the app's
    /// `appFontScale`, while the rail's labels take `scaledFont` and do scale. So the row gets
    /// tighter at large text on the leading side only, which the scaled ``leadingWidth(scale:state:)``
    /// already expresses.
    ///
    /// `theRowOneReserveSeatsWhatRowOneDraws` measures the trailing cluster off the render and
    /// holds this number to it, at every text size — the assertion that would catch a control put
    /// back on this side of the row and left out of the budget, which is exactly how a 21pt intro
    /// button once rode here uncharged.
    static let searchToggleWidth: CGFloat = 36

    /// A rail glyph's rendered width at the ambient text size.
    ///
    /// **Tabulated, not measured live, and that is a performance call rather than a preference.**
    /// `NSImage(systemSymbolName:)` costs ~135µs per symbol on the recording Mac — 812µs for the
    /// six, which is far too much for a path that runs on every `body`. These are that call's
    /// answers at 10.5pt, and `theGlyphTableMatchesTheRenderer` fails if the renderer ever
    /// disagrees, so the table cannot rot silently.
    ///
    /// A `switch` rather than a dictionary so a seventh lens is a compile error here rather than a
    /// silent zero that under-counts the rail — the exact class of mistake this type exists to
    /// stop.
    ///
    /// Scaled linearly, which **over**-estimates slightly at large text (24.0 against a measured
    /// 23.0 for `doc` at 2×) — the safe direction, since it sheds a shade early rather than a
    /// shade late.
    /// No default for `scale`: every other width here is scale-correct, and a defaulted one lets a
    /// call site silently take the 1× answer at 1.3 — an under-count, the direction that truncates.
    static func glyphWidth(_ item: OrganizeLens, scale: CGFloat) -> CGFloat {
        let base: CGFloat
        switch item {
        case .toFile:      base = 12
        case .duplicates:  base = 14
        case .renames:     base = 17
        case .restructure: base = 14
        case .rules:       base = 14
        case .storage:     base = 13
        }
        return base * scale
    }

    /// An item's label at the real weight and the ambient text size.
    ///
    /// `.semibold` because that is the selected item's weight and the widest — sizing on `.medium`
    /// would under-measure the one item that is always bold, which is the direction that truncates.
    ///
    /// **`scaledPointSize`, not `11.5 * scale`, and the difference only exists above 11pt.** The
    /// text-size setting stopped being a flat multiplier when it gained its knee curve: at or below
    /// the 11pt knee the full multiplier still applies, and above it each extra base point
    /// contributes only `surplusSlope`. 11.5 is above the knee, so the renderer draws 12.9pt at
    /// 1.15× where a linear model says 13.2 — small per item, 16.9pt across six of them, which is
    /// what `theLeadingModelMatchesWhatTheRowDraws` measured and failed on at `.large` and
    /// `.extraLarge` while passing at 0.9 and 1.0. **Ask the type that owns the curve rather than
    /// re-deriving it**: a second copy of this arithmetic is a second thing to update the next time
    /// the ramp is retuned, which is exactly how this broke.
    /// **Through ``LabelMetrics``, which is the module that already caches this.** The rail is
    /// measured once per `body` and `body` runs on every publish the manager makes; seven labels
    /// plus a badge each, measured from scratch, is type metrics recomputed dozens of times a
    /// second for a row whose words do not change. `LabelMetrics` keeps a bounded cache keyed on
    /// the string and the resolved `NSFont`, which is exactly this question.
    ///
    /// The font is the same one: `ScaledFont.system(size:weight:).nsFont(scale:)` resolves to
    /// `NSFont.systemFont(ofSize: FontSize.scaledPointSize(11.5, scale:), weight: .semibold)`,
    /// which is what this built by hand. What it adds is `ceilToHalf` — SwiftUI's own rounding of
    /// a text run, measured — so the answer moves by at most half a point per label, and moves
    /// TOWARD what the row draws. `theLeadingModelMatchesWhatTheRowDraws` holds the total against
    /// the render at every text size and is what would catch it going the other way.
    @MainActor
    static func labelWidth(_ item: OrganizeLens, scale: CGFloat) -> CGFloat {
        LabelMetrics.width(of: item.title, font: .system(size: 11.5, weight: .semibold),
                           scale: scale)
    }

    /// A badge capsule carrying `count`: the digits at 10pt bold, plus 2×5pt of capsule padding.
    ///
    /// **The digits are measured, not assumed.** A flat two-digit figure is what let `410` and
    /// `126` cost 8pt more apiece than the model believed, and a tree with a thousand duplicate
    /// groups would have widened the gap again. `.monospacedDigit()`, matching `RailItemLabel`.
    ///
    /// Through the curve like the label above, though at 10pt it is currently the identity: 10 sits
    /// **below** the 11pt knee, where the full multiplier still applies. Routed through it anyway
    /// so the badge does not silently start lying if the knee is ever lowered.
    ///
    /// **It measures the string the badge draws, which past three digits is abbreviated** — see
    /// ``RailItemLabel/badgeText(_:)``. Formatting the raw count here would size the rail for
    /// `1,192` while the row painted `1.1k`, and a model measuring a different string from the one
    /// on screen is this type's whole failure mode.
    @MainActor
    static func badgeWidth(_ count: Int, scale: CGFloat) -> CGFloat {
        // Cached in `LabelMetrics`, same font: `.monospacedDigit()` on a `ScaledFont` resolves to
        // `NSFont.monospacedDigitSystemFont(ofSize:weight:)`, which is what this built by hand.
        LabelMetrics.width(of: RailItemLabel.badgeText(count),
                           font: ScaledFont.system(size: 10, weight: .bold).monospacedDigit(),
                           scale: scale) + 10
    }

    /// What an item's state costs it on the right of its label: a badge, a dot, or nothing.
    ///
    /// **The three states are three different widths, which is why this model takes the state and
    /// not the badge.** `clean` and `notScanned` both answer "no badge", and they draw differently
    /// — the unscanned one carries a 4pt dot. A model working from a badge alone can only guess,
    /// and either guess is wrong somewhere: charging every quiet item for the dot over-counted a
    /// clean rail by 30pt, which `theLeadingModelMatchesWhatTheRowDraws` caught at once.
    @MainActor
    static func stateWidth(_ state: RailItemState, scale: CGFloat) -> CGFloat {
        switch state {
        case .reporting(let count): return badgeGap + badgeWidth(count, scale: scale)
        case .notScanned: return notScannedDotWidth
        case .clean, .configuration: return 0
        }
    }

    /// One item, spelled out, in the state it is in.
    @MainActor
    static func itemWidth(_ item: OrganizeLens, state: RailItemState, scale: CGFloat) -> CGFloat {
        labelWidth(item, scale: scale) + glyphWidth(item, scale: scale) + glyphGap + itemPadding
            + stateWidth(state, scale: scale)
    }

    /// Width of the rail with every label spelled out.
    ///
    /// - Parameters:
    ///   - scale: the app's own type scale, so the answer is right at every text size rather than
    ///     at exactly one.
    ///   - badge: the badge each item is carrying, or nil. **A closure over the enum rather than an
    ///     array**, so the caller cannot hand this a list that has drifted out of step with
    ///     `OrganizeLens.railItems` — and so a new lens is counted the day it is added. Counted
    ///     rather than assumed: the rail is at its widest on the day every finding has something to
    ///     report, which is precisely the day it must still fit.
    @MainActor
    static func fullWidth(scale: CGFloat, state: (OrganizeLens) -> RailItemState) -> CGFloat {
        let items = OrganizeLens.railItems.reduce(CGFloat.zero) {
            $0 + itemWidth($1, state: state($1), scale: scale)
        }
        return items + CGFloat(max(0, OrganizeLens.railItems.count - 1)) * itemGap
            + overviewItemWidth(scale: scale) + 2 * separatorWidth
    }

    /// The overview item, spelled out. No badge ever — a count here would have to be the sum of six
    /// different kinds of thing.
    /// - Parameter margin: slack added on top, which **differs by rail and is measured per rail**.
    ///   Organize's six-item assembly needs ``overviewMargin``; Storage's five-element row does not,
    ///   and charging it there put the model 13–22pt over its own render at three of the four text
    ///   sizes. A margin is meant to keep a model on the safe side of what it describes, not to be
    ///   a constant copied between two rails that measure differently.
    @MainActor
    static func overviewItemWidth(scale: CGFloat, margin: CGFloat = overviewMargin) -> CGFloat {
        // Through the ramp's curve, like ``labelWidth(_:scale:)``. `11.5 * scale` is the linear
        // reading the curve deliberately does not take — above the 11pt knee only half the surplus
        // applies — so a raw multiply over-measures at large text and the model sheds early there
        // and nowhere else.
        return LabelMetrics.width(of: overviewTitle, font: .system(size: 11.5, weight: .semibold),
                                  scale: scale)
            + overviewGlyphWidth * scale + glyphGap + itemPadding + itemGap + margin
    }

    /// Width of the rail with every label shed. Badges stay — they are the reason to look.
    @MainActor
    static func iconOnlyWidth(scale: CGFloat, state: (OrganizeLens) -> RailItemState) -> CGFloat {
        let items = OrganizeLens.railItems.reduce(CGFloat.zero) {
            $0 + glyphWidth($1, scale: scale) + itemPadding + stateWidth(state($1), scale: scale)
        }
        return items + CGFloat(max(0, OrganizeLens.railItems.count - 1)) * itemGap
            + overviewGlyphWidth * scale + itemPadding + itemGap + 2 * separatorWidth
    }

    /// Everything row 1's leading half must seat.
    ///
    /// That is the spelled-out rail and nothing else today — the intro button that used to ride
    /// beside it is gone. The seam stays named because the *requirement* is what ``style(contentWidth:leadingWidth:)``
    /// takes, and anything ever added to this half of the row is added here, where it is counted,
    /// rather than beside the rail where the first cut of this type left it uncounted.
    @MainActor
    static func leadingWidth(scale: CGFloat, state: (OrganizeLens) -> RailItemState) -> CGFloat {
        fullWidth(scale: scale, state: state)
    }

    /// The same, with the rail shed — what the row falls back to.
    @MainActor
    static func shedLeadingWidth(scale: CGFloat, state: (OrganizeLens) -> RailItemState) -> CGFloat {
        iconOnlyWidth(scale: scale, state: state)
    }

    /// The style a header of this width can seat.
    ///
    /// All-or-nothing, like the bar: shedding one item's label would leave a rail where some
    /// places are words and others are glyphs, which reads as two controls rather than one row of
    /// peers.
    ///
    /// Takes the leading width already resolved rather than the ingredients, because this runs
    /// inside the geometry transform — on every width the view is handed — while
    /// ``leadingWidth(scale:state:)`` measures type and belongs once per `body`.
    ///
    /// **No `lens` parameter any more.** It used to select the trailing reserve, which differed by
    /// lens because each lens's own controls sat on this row. They are on row 2 now, so what row 1
    /// reserves is the search toggle — the same for all six — and a parameter that no longer
    /// changes the answer would only invite the belief that it does.
    static func style(contentWidth: CGFloat, leadingWidth: CGFloat) -> OrganizeRailStyle {
        contentWidth - searchToggleWidth >= leadingWidth ? .full : .iconOnly
    }

    /// What the card's own frame costs the row: the inset it floats on plus its internal padding,
    /// both sides of each.
    ///
    /// Only the caller measuring the COLUMN needs this. It was missing entirely while the decision
    /// was made from the card's own geometry — that measurement started inside the inset and
    /// outside the padding, so the model believed the rail had 24pt more room than it draws in,
    /// which is a truncation waiting for a rail 24pt short of the edge.
    static var cardChrome: CGFloat { 2 * LiquidGlass.cardInset + 2 * LensHeaderMetrics.padding }

    /// The style a **column** of this width can seat — the entry point the view uses.
    ///
    /// Separate from ``style(contentWidth:leadingWidth:)`` rather than replacing it: that one
    /// answers "what fits inside this row", which is the arithmetic and is worth testing on its
    /// own, and this one converts the only width a caller can honestly measure into it. The
    /// distinction is not pedantry — it is the whole defect. A view can measure what it was
    /// PROPOSED (this) or what it DREW (the card), and the second is a number the rail itself
    /// helped decide, so feeding it back in makes the test "is the rail as wide as the rail",
    /// which is true at every window size.
    static func style(columnWidth: CGFloat, leadingWidth: CGFloat) -> OrganizeRailStyle {
        style(contentWidth: columnWidth - cardChrome, leadingWidth: leadingWidth)
    }
}
