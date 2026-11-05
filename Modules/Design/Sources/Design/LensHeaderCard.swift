import SwiftUI

/// The row geometry of ``LensHeaderCard``, spelled out so the resting height is derived from the
/// rows rather than asserted as a magic number.
///
/// At rest the card is two rows: tabs and controls, then the summary. The search field and its
/// token chips are extra rows that appear only while searching, and the card grows to fit them.
/// Swapping the search in where the pills are would hide the counts you watch change as you type,
/// which is most of the value of filtering here.
public enum LensHeaderMetrics {
    /// Row 1: the lens's name, its actions and the search toggle. 27pt is a 12pt label (15pt line)
    /// plus its 6pt vertical padding. The lens tabs live in the window's workspace bar, so this row
    /// names the lens, and it keeps `restingHeight` at 81, which the pane's header↔list boundary is
    /// pinned to.
    public static let tabRow: CGFloat = 27
    /// Row 2: the scanned-folder chip, the stat pills, and the trailing detail or "N of M". 22pt is
    /// a `.standard` `Pill` (12pt semibold number plus 2×4pt padding).
    public static let summaryRow: CGFloat = 22
    /// The revealed search field (`ExpandingSearchField`): 16pt of text over 2×6pt padding.
    public static let searchRow: CGFloat = 28
    /// The parsed token chips, when a query contains any.
    public static let chipRow: CGFloat = 22
    /// The gap between any two rows of the card.
    public static let rowGap: CGFloat = 8
    /// The card's internal padding on all four sides.
    public static let padding: CGFloat = 12

    /// 12 + 27 + 8 + 22 + 12 = 81, the card's visible height with the search collapsed. It must
    /// equal `LiquidGlass.headerHeight` so the card's bottom edge lands on the file pane's
    /// header↔list boundary. Derived, not typed: change a row and this follows.
    public static var restingHeight: CGFloat {
        padding + tabRow + rowGap + summaryRow + padding
    }

    /// What the card occupies in its parent at rest in Cards, including the half-gutter it insets
    /// itself by on each side (`columnSectionCard`): 2.5 + 81 + 2.5 = 86. In Unified the card draws
    /// no frame and occupies `restingHeight`; the window's one region (`windowRegionFrame`)
    /// supplies the same 2.5 above it, so its bottom edge lands on 83.5 in both styles.
    public static var restingTotalHeight: CGFloat {
        restingHeight + 2 * LiquidGlass.cardInset
    }
}

/// The one header card of a lensed workspace: the lens's name and controls on row 1, a summary of
/// what the lens found on row 2, and an expanding search below. 81pt tall at rest, in every lens
/// and every state.
///
/// Drawn in the empty and scanning states too, which is what makes the height a promise rather
/// than depend on whether a lens has results. The host supplies the slots; the card owns the
/// geometry, the search toggle's place (last on row 1, like Compare's `standardHeaderControls`),
/// and the field and chip rows.
public struct LensHeaderCard<Title: View, Actions: View, Summary: View, Trailing: View>: View {
    @Binding private var searchText: String
    @Binding private var isSearchExpanded: Bool
    private let searchPlaceholder: String
    private let searchHelp: String
    /// Whether this lens offers search at all; see the initializer.
    private let showsSearch: Bool
    private let chips: [TokenChipsRow.Item]
    private let onRemoveChip: (String) -> Void

    private let accent: Color
    private let surfaceStyle: SurfaceStyle
    private let level: GlassLevel
    private let hue: LiquidGlassHue
    private let tint: Double

    private let title: () -> Title
    private let actions: () -> Actions
    private let summary: () -> Summary
    private let trailing: () -> Trailing

    /// - Parameters:
    ///   - searchPlaceholder: this lens's vocabulary — see ``ExpandingSearchField``. It must
    ///     advertise exactly the tokens this lens binds and no others.
    ///   - searchHelp: names what this lens searches, for the toggle's tooltip and a11y label.
    ///   - showsSearch: whether this lens answers a query at all. Defaults to true, the right
    /// answer for every lens with a list. False is for the pages with none: Organize's overview,
    /// which filters nothing, and Storage before its analysis has run. No toggle beats one that
    /// does nothing. False also suppresses the field and chip rows, so a query parked by another
    /// lens can't surface here through `isSearching`.
    ///
    ///     The card's height doesn't change with it: the toggle sits in a fixed-height row
    ///     (``LensHeaderMetrics/tabRow``), so the header is 81pt either way.
    ///   - chips: the parsed tokens of the live query. Empty ⇒ no chip row, so the card only
    ///     grows the extra 30pt once a token actually parses.
    ///   - title: row 1 leading — the lens's name, which tells you where you are.
    ///   - actions: row 1 trailing, before the search toggle — this lens's controls.
    ///   - summary: row 2 leading — the scanned-folder chip and stat pills.
    ///   - trailing: row 2 trailing — the detail line or "N of M" filtered count.
    public init(
        searchText: Binding<String>,
        isSearchExpanded: Binding<Bool>,
        searchPlaceholder: String,
        searchHelp: String,
        showsSearch: Bool = true,
        chips: [TokenChipsRow.Item] = [],
        onRemoveChip: @escaping (String) -> Void = { _ in },
        accent: Color,
        surfaceStyle: SurfaceStyle,
        level: GlassLevel,
        hue: LiquidGlassHue = .blue,
        tint: Double = 0,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() },
        @ViewBuilder summary: @escaping () -> Summary = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self._searchText = searchText
        self._isSearchExpanded = isSearchExpanded
        self.searchPlaceholder = searchPlaceholder
        self.searchHelp = searchHelp
        self.showsSearch = showsSearch
        self.chips = chips
        self.onRemoveChip = onRemoveChip
        self.accent = accent
        self.surfaceStyle = surfaceStyle
        self.level = level
        self.hue = hue
        self.tint = tint
        self.title = title
        self.actions = actions
        self.summary = summary
        self.trailing = trailing
    }

    /// Whether the field is showing: expanded, or collapsed but still filtering (unreachable
    /// through the toggle, which clears on collapse, but a host that seeds a query can produce it).
    private var isSearching: Bool { showsSearch && (isSearchExpanded || !searchText.isEmpty) }

    public var body: some View {
        VStack(alignment: .leading, spacing: LensHeaderMetrics.rowGap) {
            HStack(spacing: 8) {
                title()
                Spacer(minLength: 8)
                actions()
                if showsSearch {
                    ExpandingSearchToggle(
                        text: $searchText,
                        isExpanded: $isSearchExpanded,
                        accent: accent,
                        help: searchHelp
                    )
                }
            }
            .frame(height: LensHeaderMetrics.tabRow)

            HStack(spacing: 8) {
                // The prose yields first. A layout priority only decides who is asked to shrink,
                // and the `.fixedSize()` pills every lens puts here refuse: the row would insist on
                // its natural width, the card's `maxWidth: .infinity` frame would report it (see
                // the note below), and the parent would centre the oversized card, spilling it past
                // both edges of the column (`LensHeaderCardOverflowTests`).
                //
                // Not a `ScrollView`: it is greedy, so in an `HStack` it soaks up the slack like a
                // `Spacer` and starves a flexible sibling such as To File's folder-survey sentence.
                // `ShrinkableRun` reports the content's width as ideal and maximum, so it takes
                // what it needs and no more.
                //
                // A squeeze cuts the run's tail silently, since the 22pt row has no height for an
                // indicator. That is the lesser cost: a readout you widen the window to finish
                // beats a readout and a destructive button both cut in half.
                ShrinkableRun { summary() }
                    .clipped()
                Spacer(minLength: 8)
                trailing()
            }
            .frame(height: LensHeaderMetrics.summaryRow)

            if isSearching {
                ExpandingSearchField(
                    text: $searchText,
                    isExpanded: $isSearchExpanded,
                    placeholder: searchPlaceholder
                )
                .frame(height: LensHeaderMetrics.searchRow)

                // Chips are their own row below the field's surface here (Compare nests them inside
                // it): this card's rows are a fixed ladder, so the chips need a height the card can
                // account for.
                if !chips.isEmpty {
                    TokenChipsRow(items: chips, tint: accent, onRemove: onRemoveChip)
                        .frame(height: LensHeaderMetrics.chipRow, alignment: .leading)
                }
            }
        }
        .padding(LensHeaderMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // This frame doesn't hold the card to the width it was offered: with `maxWidth: .infinity`
        // it reports the larger of the proposal and what its child insists on, and a row of
        // `.fixedSize()` children insists. A card offered 340pt can resolve to ~600pt, centred, so
        // a `.clipped()` here is a no-op that clips to 600.
        //
        // The clip that works belongs to whoever owns a definite width: the split, where
        // `ContentView+SplitLayout` gives the workspace `.frame(width: totalWidth - railWidth)` and
        // clips. Said here because this is where the next person will reach for it, and where it
        // would look like it worked (`LensHeaderCardOverrunTests`).
        //
        // The workspace column's header: its own card in Cards; in Unified, a hairline over the
        // content under it, both inside the window's one region.
        .columnHeaderRule(surfaceStyle)
        .columnSectionCard(surfaceStyle, level: level, hue: hue, tint: tint)
    }
}
