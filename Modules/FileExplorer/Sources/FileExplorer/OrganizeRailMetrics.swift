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
/// items are about 670pt at the default text size, and the trailing controls on the same row are
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
///   ``leadingWidth(scale:badge:)``, not merely in `TidyView.lensTitle`.
///
/// Together those came to ~63pt at four badges, which is why the row truncated while the
/// arithmetic reported room. The failure mode worth remembering is not the size of the error but
/// its *shape*: because the estimate was wrong per item and per digit, the width the row really
/// needed drifted with the badge counts, so **no fixed ``reservedTrailing`` could have been
/// correct**. Measured against the render, the required reserve came out at 449.6 with three
/// badges and 458.6 with four; with the leading side measured properly it is 394.8 and 395.3 —
/// the same number twice, which is what makes a constant legitimate here at all.
public enum OrganizeRailMetrics {

    /// Between an item's glyph and its label.
    public static let glyphGap: CGFloat = 5
    /// An item's own horizontal padding, 2×9pt.
    public static let itemPadding: CGFloat = 18
    /// Between items.
    public static let itemGap: CGFloat = 6
    /// Between a label and the badge after it.
    public static let badgeGap: CGFloat = 5

    /// Row 1 width the rail can never have: the lens's own controls and the search toggle.
    ///
    /// **Per lens, because one number for six of them was wrong for one of them.** It was a single
    /// 420 — sized on Duplicates, the widest lens whose trailing set is fixed controls (353.5pt of
    /// ink for `All ⌄`, `Rescan`, `Apply 410 recommended` and the search toggle) against a measured
    /// requirement of 395. That held for five lenses and not for **To File**, whose trailing set
    /// measures **436.5–468** once the refine offer is showing: `Rescan`, `Refine N with <model>`,
    /// `File all N confident`, search. So the row truncated its own buttons *at the very width the
    /// model started spelling the rail out* — the defect
    /// `theShedThresholdIsNotOneCharacterTooLate` was written for, on the one lens it did not
    /// sweep. Nothing about the caption below was needed to produce it: an empty
    /// `filingSurveyReport` truncates just the same.
    ///
    /// Splitting the number costs nothing the shared one was buying. Sizing the shared constant at
    /// To File's 468 instead would have shed the labels ~70pt early on the five lenses that never
    /// needed it, which is the trade the old doc's "single number shared by all six lenses" was
    /// silently making in the other direction.
    ///
    /// Deliberately generous within each lens: being one item too cautious costs six labels that
    /// would have fitted, while being one too optimistic costs the *actions* their words.
    ///
    /// **The margin absorbs the counts, and that is the part worth checking when this moves.** The
    /// two To File labels carry numbers, so its requirement drifts with the queue — 437.5 at 24
    /// files, 468 at 1,204, 460.5 at 99,999 (a digit is worth ~9pt and the peak is inside that
    /// range, since a longer count buys a shorter model name no room). 490 clears the peak by 22.
    /// A reserve whose *requirement* drifted further than its margin would be a broken model rather
    /// than a mis-tuned number, and would want the trailing side measured per control the way
    /// ``itemWidth(_:badge:scale:)`` measures the leading one.
    ///
    /// - Parameter lens: the rail's selection; nil is the overview, which draws Rescan and the
    ///   search toggle alone (129pt measured) and so is covered by the shared figure.
    public static func reservedTrailing(for lens: OrganizeLens?) -> CGFloat {
        switch lens {
        // Rescan · Refine N with <model> · File all N confident · search.
        case .toFile: return 490
        // Duplicates (354) is the widest of these; Names 240, Renames and Restructure 129,
        // Rules and the overview less again.
        case .duplicates, .names, .renames, .restructure, .rules, .none: return 420
        }
    }

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
    public static func glyphWidth(_ item: OrganizeLens, scale: CGFloat = 1) -> CGFloat {
        let base: CGFloat
        switch item {
        case .toFile:      base = 12
        case .duplicates:  base = 14
        case .names:       base = 14
        case .renames:     base = 17
        case .restructure: base = 14
        case .rules:       base = 14
        }
        return base * scale
    }

    /// An item's label at the real weight and the ambient text size.
    ///
    /// `.semibold` because that is the selected item's weight and the widest — sizing on `.medium`
    /// would under-measure the one item that is always bold, which is the direction that truncates.
    public static func labelWidth(_ item: OrganizeLens, scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5 * scale, weight: .semibold)
        return (item.title as NSString).size(withAttributes: [.font: font]).width
    }

    /// A badge capsule carrying `count`: the digits at 10pt bold, plus 2×5pt of capsule padding.
    ///
    /// **The digits are measured, not assumed.** A flat two-digit figure is what let `410` and
    /// `126` cost 8pt more apiece than the model believed, and a tree with a thousand duplicate
    /// groups would have widened the gap again. `.monospacedDigit()`, matching `RailItemLabel`.
    public static func badgeWidth(_ count: Int, scale: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10 * scale, weight: .bold)
        return (count.formatted() as NSString).size(withAttributes: [.font: font]).width + 10
    }

    /// One item, spelled out, with the badge it is carrying.
    public static func itemWidth(_ item: OrganizeLens, badge: Int?, scale: CGFloat) -> CGFloat {
        labelWidth(item, scale: scale) + glyphWidth(item, scale: scale) + glyphGap + itemPadding
            + (badge.map { badgeGap + badgeWidth($0, scale: scale) } ?? 0)
    }

    /// Width of the rail with every label spelled out.
    ///
    /// - Parameters:
    ///   - scale: the app's own type scale, so the answer is right at every text size rather than
    ///     at exactly one.
    ///   - badge: the badge each item is carrying, or nil. **A closure over the enum rather than an
    ///     array**, so the caller cannot hand this a list that has drifted out of step with
    ///     `OrganizeLens.allCases` — and so a new lens is counted the day it is added. Counted
    ///     rather than assumed: the rail is at its widest on the day every finding has something to
    ///     report, which is precisely the day it must still fit.
    public static func fullWidth(scale: CGFloat, badge: (OrganizeLens) -> Int?) -> CGFloat {
        let items = OrganizeLens.allCases.reduce(CGFloat.zero) {
            $0 + itemWidth($1, badge: badge($1), scale: scale)
        }
        return items + CGFloat(max(0, OrganizeLens.allCases.count - 1)) * itemGap
    }

    /// Width of the rail with every label shed. Badges stay — they are the reason to look.
    public static func iconOnlyWidth(scale: CGFloat, badge: (OrganizeLens) -> Int?) -> CGFloat {
        let items = OrganizeLens.allCases.reduce(CGFloat.zero) {
            $0 + glyphWidth($1, scale: scale) + itemPadding
                + (badge($1).map { badgeGap + badgeWidth($0, scale: scale) } ?? 0)
        }
        return items + CGFloat(max(0, OrganizeLens.allCases.count - 1)) * itemGap
    }

    /// Everything row 1's leading half must seat.
    ///
    /// That is the spelled-out rail and nothing else today — the intro button that used to ride
    /// beside it is gone. The seam stays named because the *requirement* is what ``style(contentWidth:leadingWidth:lens:)``
    /// takes, and anything ever added to this half of the row is added here, where it is counted,
    /// rather than beside the rail where the first cut of this type left it uncounted.
    public static func leadingWidth(scale: CGFloat, badge: (OrganizeLens) -> Int?) -> CGFloat {
        fullWidth(scale: scale, badge: badge)
    }

    /// The same, with the rail shed — what the row falls back to.
    public static func shedLeadingWidth(scale: CGFloat, badge: (OrganizeLens) -> Int?) -> CGFloat {
        iconOnlyWidth(scale: scale, badge: badge)
    }

    /// The style a header of this width can seat.
    ///
    /// All-or-nothing, like the bar: shedding one item's label would leave a rail where some
    /// places are words and others are glyphs, which reads as two controls rather than one row of
    /// peers.
    ///
    /// Takes the leading width already resolved rather than the ingredients, because this runs
    /// inside the geometry transform — on every width the view is handed — while
    /// ``leadingWidth(scale:badge:)`` measures type and belongs once per `body`.
    ///
    /// `lens` is taken here rather than folded into `leadingWidth` because it selects the
    /// *trailing* reserve — see ``reservedTrailing(for:)``, which is the half that differs by lens.
    public static func style(contentWidth: CGFloat, leadingWidth: CGFloat,
                             lens: OrganizeLens?) -> OrganizeRailStyle {
        contentWidth - reservedTrailing(for: lens) >= leadingWidth ? .full : .iconOnly
    }
}
