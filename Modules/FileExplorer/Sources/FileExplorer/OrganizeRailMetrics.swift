import Foundation
import AppKit
import CoreGraphics
// For the text-size ramp's own curve, so this model asks the type that owns it rather than
// keeping a second copy of the arithmetic.
import Design

/// Whether Organize's rail can afford to spell its items out.
enum OrganizeRailStyle: Equatable, Sendable {
    /// Glyph, label, and the badge when there is one.
    case full
    /// Glyph and badge only; the label moves into the tooltip and the accessibility label.
    case iconOnly
}

/// The rail's width arithmetic, kept pure so the shedding rule can be asserted without mounting a
/// header. Without it, a rail too wide for row 1 is resolved by SwiftUI truncating the flexible
/// side, silently clipping the controls beside it.
///
/// Computed, not a `ViewThatFits` ladder, for ``WorkspaceBarMetrics``'s reasons: a ladder builds
/// every rung on every layout pass, and this must answer for a width the view is given. Kept
/// separate from that type because the two reserve different space and shed at different widths.
///
/// Every item is measured on its own: its real glyph width (``glyphWidth(_:scale:)``), its badge's
/// actual digits (``badgeWidth(_:scale:)``), and anything else on the row's leading side, which
/// belongs in ``leadingWidth(scale:state:)``. An estimate that is wrong per item or per digit
/// drifts with the badge counts, and then no fixed trailing reserve can be right.
enum OrganizeRailMetrics {

    /// Between an item's glyph and its label.
    static let glyphGap: CGFloat = 5
    /// An item's own horizontal padding, 2×9pt.
    static let itemPadding: CGFloat = 18
    /// Between items.
    static let itemGap: CGFloat = 6
    /// Between a label and the badge after it.
    static let badgeGap: CGFloat = 5
    /// The overview item's label and glyph. It is not an ``OrganizeLens``, so the rail's own
    /// `allCases` walk can't find it; without these the model would leave it uncounted.
    static let overviewTitle = "All"
    static let overviewSymbol = "square.grid.2x2"
    /// `square.grid.2x2` at 10.5pt semibold, measured as ``glyphWidth(_:scale:)``'s table was: a
    /// glyph is not its point size.
    static let overviewGlyphWidth: CGFloat = 13
    /// Margin on the overview item, whose label changes weight with selection (`RailItemLabel`
    /// draws the current item `.semibold`, the rest `.medium`). Over, never under: a model short of
    /// the row lets it overrun before it sheds. 6 keeps the model over the render at all four text
    /// sizes and inside the 12pt slack `theLeadingModelMatchesWhatTheRowDraws` allows.
    static let overviewMargin: CGFloat = 6
    /// A group separator: the 1pt rule plus one `itemGap`. Only one, because in an
    /// `HStack(spacing: itemGap)` each added element contributes exactly one gap; charging both
    /// sides counts every interior gap twice.
    static var separatorWidth: CGFloat { 1 + itemGap }
    /// The dot an unscanned item draws where a badge would go — 4pt and the gap before it.
    static let notScannedDotWidth: CGFloat = 4 + badgeGap

    /// Row 1 width the rail can never have: the search toggle, and nothing else. Each lens's own
    /// controls live on row 2 (`LensWorkspaceView.lensTrailing`) so the rail can spell out in an
    /// ordinary window; reserving their width here would make the glyph-only rail the normal state.
    ///
    /// The toggle `LensHeaderCard` appends is a 22pt square plus an 8pt gap, with 6pt of margin.
    /// Flat across text sizes: it is an AppKit control at `.controlSize(.small)`, which follows the
    /// system font, while the rail's labels scale. `theRowOneReserveSeatsWhatRowOneDraws` holds
    /// this to the render at every text size, so a control added to this side can't go uncounted.
    static let searchToggleWidth: CGFloat = 36

    /// A rail glyph's rendered width at the ambient text size.
    ///
    /// Tabulated for speed: `NSImage(systemSymbolName:)` costs ~135µs a symbol, too much for every
    /// `body`. These are its answers at 10.5pt, and `theGlyphTableMatchesTheRenderer` fails if the
    /// renderer disagrees. A `switch`, so a new lens is a compile error, not a silent zero.
    ///
    /// Scaled linearly, which slightly over-estimates at large text: the safe direction, shedding
    /// a shade early. No default for `scale`, so no call site silently takes the 1× answer.
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
    /// `.semibold`, the selected item's weight and the widest; sizing on `.medium` would
    /// under-measure the bold item, the direction that truncates.
    ///
    /// The font goes through the text-size ramp's own curve, not `11.5 * scale`: above the 11pt
    /// knee each extra point scales by less, so a linear model over-measures at large text. Asking
    /// the type that owns the curve means a retune can't leave a second copy behind.
    ///
    /// Through ``LabelMetrics``, which caches by string and resolved font, because `body` runs on
    /// every manager publish and the words rarely change. It also applies SwiftUI's half-point
    /// rounding of a text run, which moves the answer toward what the row draws.
    @MainActor
    static func labelWidth(_ item: OrganizeLens, scale: CGFloat) -> CGFloat {
        LabelMetrics.width(of: item.title, font: .system(size: 11.5, weight: .semibold),
                           scale: scale)
    }

    /// A badge capsule carrying `count`: the digits at 10pt bold, plus 2×5pt of capsule padding.
    ///
    /// The digits are measured, not assumed, since a badge is as wide as its count.
    /// `.monospacedDigit()`, matching `RailItemLabel`. Through the ramp's curve like the label,
    /// though 10pt is below the knee today, so lowering the knee can't make the badge lie.
    ///
    /// Measures the string the badge draws, which past three digits is abbreviated (see
    /// ``RailItemLabel/badgeText(_:)``): sizing for `1,192` while the row paints `1.1k` would
    /// measure a different string from the one on screen.
    @MainActor
    static func badgeWidth(_ count: Int, scale: CGFloat) -> CGFloat {
        // `.monospacedDigit()` on a `ScaledFont` resolves to
        // `NSFont.monospacedDigitSystemFont(ofSize:weight:)`, the font the badge draws.
        LabelMetrics.width(of: RailItemLabel.badgeText(count),
                           font: ScaledFont.system(size: 10, weight: .bold).monospacedDigit(),
                           scale: scale) + 10
    }

    /// What an item's state costs it on the right of its label: a badge, a dot, or nothing.
    ///
    /// Takes the state, not the badge, because `clean` and `notScanned` both have no badge but draw
    /// differently: the unscanned one carries a 4pt dot. Working from the badge alone would charge
    /// the dot wrongly somewhere.
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
    ///   - scale: the app's type scale, so the width is right at every text size.
    ///   - state: each lens's rail state. A closure over the enum, so a new lens is counted the day
    ///     it is added. The rail is widest when every lens is reporting, and must still fit then.
    @MainActor
    static func fullWidth(scale: CGFloat, state: (OrganizeLens) -> RailItemState) -> CGFloat {
        let items = OrganizeLens.railItems.reduce(CGFloat.zero) {
            $0 + itemWidth($1, state: state($1), scale: scale)
        }
        return items + CGFloat(max(0, OrganizeLens.railItems.count - 1)) * itemGap
            + overviewItemWidth(scale: scale) + 2 * separatorWidth
    }

    /// The overview item, spelled out. Never a badge: its count would sum six kinds of thing.
    /// - Parameter margin: slack added on top, measured for the row it describes;
    @MainActor
    static func overviewItemWidth(scale: CGFloat, margin: CGFloat = overviewMargin) -> CGFloat {
        // Through the ramp's curve, like ``labelWidth(_:scale:)``; a raw `11.5 * scale`
        // over-measures at large text and sheds early there.
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
    /// Today that is the spelled-out rail alone. It stays a named seam because this is what
    /// ``style(contentWidth:leadingWidth:)`` takes: anything added to this half of the row is
    /// counted here.
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
    /// All-or-nothing, like the bar: a rail of some words and some glyphs reads as two controls
    /// rather than one row of peers.
    ///
    /// Takes the leading width already resolved, because this runs in the geometry transform on
    /// every width the view is handed, while ``leadingWidth(scale:state:)`` measures type and
    /// belongs once per `body`. No lens parameter: row 1 reserves the same toggle for every lens.
    static func style(contentWidth: CGFloat, leadingWidth: CGFloat) -> OrganizeRailStyle {
        contentWidth - searchToggleWidth >= leadingWidth ? .full : .iconOnly
    }

    /// What the card's own frame costs the row: the inset it floats on plus its internal padding,
    /// both sides of each.
    ///
    /// Only a caller measuring the column needs this. Leaving it out would give the rail more room
    /// than it draws in, and truncate a rail that just fits.
    static var cardChrome: CGFloat { 2 * LiquidGlass.cardInset + 2 * LensHeaderMetrics.padding }

    /// The style a column of this width can seat: the entry point the view uses.
    ///
    /// ``style(contentWidth:leadingWidth:)`` is the arithmetic; this converts the one width a
    /// caller can honestly measure, the column it was proposed, into it. The card's drawn width is
    /// partly decided by the rail itself, so feeding it back would ask "is the rail as wide as the
    /// rail", which is true at every window size.
    static func style(columnWidth: CGFloat, leadingWidth: CGFloat) -> OrganizeRailStyle {
        style(contentWidth: columnWidth - cardChrome, leadingWidth: leadingWidth)
    }
}
